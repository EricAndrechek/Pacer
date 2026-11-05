import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// #350: one account's lanes must take turns, not fire together.
///
/// An account with several tokens (Claude Code plus each Claude Desktop
/// install) has one lane per token, and each token may be polled at most once
/// per `perTokenMinInterval`. Evenly staggered, n lanes give the account a
/// reading every interval/n. On a real store the busiest account's seven
/// Desktop lanes were all polled inside one minute, every five minutes: seven
/// identical readings, then nothing, which is a single token's freshness.
///
/// These check the timing directly: the gaps between one account's polls, and
/// the gaps between polls of one token.

// MARK: - End to end: the poller's own loop on a virtual clock

@Suite("Lane stagger through the poller loop (#350)")
struct LaneStaggerPollerTests {

    /// Virtual time for a whole loop run. Each nap moves the clock forward by
    /// exactly what the poller asked for, so hours of scheduling take well
    /// under a second; a wake from sleep is a jump the clock makes when it
    /// passes a set instant. At `end` the clock stops and the nap parks until
    /// the poller is stopped.
    final class VirtualClock: PollerClock, @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        private let end: Date
        private var jumps: [(at: Date, by: TimeInterval)]

        init(start: Date, end: Date, jumps: [(at: Date, by: TimeInterval)] = []) {
            self.current = start
            self.end = end
            self.jumps = jumps.sorted { $0.at < $1.at }
        }

        func now() -> Date {
            lock.lock(); defer { lock.unlock() }
            return current
        }

        var finished: Bool { now() >= end }

        func sleep(seconds: TimeInterval) async throws {
            try Task.checkCancellation()
            let parked: Bool = {
                lock.lock(); defer { lock.unlock() }
                var next = current.addingTimeInterval(seconds)
                while let jump = jumps.first, next >= jump.at {
                    next = next.addingTimeInterval(jump.by)
                    jumps.removeFirst()
                }
                current = min(next, end)
                return current >= end
            }()
            if parked {
                // Cancelled by `stop()`; the loop never gets further.
                try await Task.sleep(for: .seconds(3_600))
            }
            await Task.yield()
        }
    }

    /// Every request the fake endpoint saw: which token, at what virtual time.
    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(token: String, at: Date)] = []
        func note(_ token: String, at: Date) {
            lock.lock(); entries.append((token, at)); lock.unlock()
        }
        var all: [(token: String, at: Date)] {
            lock.lock(); defer { lock.unlock() }; return entries
        }
    }

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Heartbeat.self, TokenSample.self, DailyAggregate.self,
            ProjectDailyAggregate.self, RateLimitSample.self, ExtraUsageSample.self,
            UsageLimitSample.self, SessionInfo.self, ClaudeCodeMeta.self,
            TokenLaneMeta.self, Account.self, AccountUsageArchive.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static func keychainBlob(token: String, expires: Date) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": token,
                "expiresAt": Int64(expires.timeIntervalSince1970) * 1000,
            ]
        ])
    }

    /// The state the real store was in: the signed-in account has one token,
    /// another account has seven Desktop tokens, all seven last polled at the
    /// same moment (restored that way at launch). Two hours of loop, with a
    /// forty-minute sleep in the middle, which makes every lane due at once
    /// again on wake.
    @Test("seven lanes of a non-active account settle into even turns and stay there")
    func sevenSecondaryLanesTakeTurns() async throws {
        let floor: TimeInterval = 300
        let n = 7
        let start = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / 60).rounded() * 60)
        let wakeAt = start.addingTimeInterval(60 * 60)
        let sleepFor: TimeInterval = 40 * 60
        let end = start.addingTimeInterval(2 * 3_600 + sleepFor)
        let clock = VirtualClock(start: start, end: end, jumps: [(wakeAt, sleepFor)])

        let container = try Self.makeContainer()
        let desktop = (1...n).map { "desk-\($0)" }
        // Restored lane state: classified, and aligned — every lane last
        // polled at the same instant, over an interval ago.
        try await MainActor.run {
            let context = ModelContext(container)
            for token in desktop {
                context.insert(TokenLaneMeta(
                    id: OAuthPoller.laneId(token), sourceRaw: CredentialCandidate.Source.desktop.rawValue,
                    organizationId: "orgB", accountRaw: "secondary", expiresAt: nil,
                    lastPolledAt: start.addingTimeInterval(-400), cooldownUntil: nil,
                    consecutiveFailures: 0, updatedAt: start))
            }
            try context.save()
        }
        let pool = EphemeralTokenPoolStore(desktop.map {
            StoredToken(credential: OAuthCredential(accessToken: $0, expiresAt: nil, subscriptionType: nil),
                        source: .desktop)
        })

        let log = RequestLog()
        let transport: OAuthClient.Transport = { request in
            let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
                .replacingOccurrences(of: "Bearer ", with: "")
            log.note(token, at: clock.now())
            let org = token.hasPrefix("desk-") ? "orgB" : "orgA"
            return try HTTPOutcome.success(
                jsonBody: #"{"five_hour":{"utilization":10}}"#,
                headers: ["anthropic-organization-id": org]).materialize()
        }
        let blob = Self.keychainBlob(token: "tokA", expires: end.addingTimeInterval(86_400))
        let client = OAuthClient(
            keychain: KeychainOAuth(rawReader: { .success(blob) }),
            parkedCredentials: { [] }, transport: transport,
            tokenOverride: { nil }, desktopEnabled: { false })
        let poller = OAuthPoller(
            client: client, container: container,
            configuration: .init(scheduler: .init(perTokenMinInterval: floor)),
            clock: clock, activityProbe: { nil }, poolStore: pool)

        await poller.start()
        let reachedEnd = await eventually { clock.finished }
        await poller.stop()
        #expect(reachedEnd, "the loop stopped advancing virtual time")

        let requests = log.all
        // The per-token invariant, for every token, across the whole run.
        for token in Set(requests.map(\.token)) {
            let times = requests.filter { $0.token == token }.map(\.at).sorted()
            for (a, b) in zip(times, times.dropFirst()) {
                #expect(b.timeIntervalSince(a) >= floor,
                        "\(token) polled \(Int(b.timeIntervalSince(a))) s after its last poll")
            }
        }

        // The account's polls: one every interval/n, from the first round on,
        // after launch and after the wake alike.
        let account = requests.filter { $0.token.hasPrefix("desk-") }.map(\.at).sorted()
        let gaps = zip(account, account.dropFirst())
            .map { $1.timeIntervalSince($0) }
            .filter { $0 < sleepFor }   // the sleep itself is not a gap the scheduler chose
        let even = floor / Double(n)
        #expect(account.count > 150, "expected ~\(Int(2 * 3_600 / even)) polls, got \(account.count)")
        let tooClose = gaps.filter { $0 < even - 1 }
        #expect(tooClose.isEmpty,
                "\(tooClose.count) of \(gaps.count) gaps under \(Int(even)) s (shortest \(Int(tooClose.min() ?? 0)) s)")
        let median = gaps.sorted()[gaps.count / 2]
        #expect(abs(median - even) < 2, "median gap \(Int(median)) s, want ~\(Int(even)) s")
        // Nothing larger than a turn and a half once settled: a round of
        // bunched polls shows up here as one gap of nearly the whole interval.
        let longest = gaps.max() ?? 0
        #expect(longest < even * 1.5, "longest gap \(Int(longest)) s")
    }
}

// MARK: - The scheduler alone, over simulated hours

/// A stand-in for the poller's loop around the pure scheduler: ask, poll what
/// it says (each poll takes `latency`, and the lane is stamped when the answer
/// lands, as `OAuthPoller.pollLane` does), or wait what it says. Events change
/// the lane set or the other client's schedule at set times.
struct StaggerSim {
    struct SimLane {
        var token: String
        var account: String
        var state: OAuthPollScheduler.LaneState
        /// Polls of this lane still to answer 429.
        var failuresLeft = 0
        var consecutiveFailures = 0
    }
    struct Event {
        let at: Date
        let apply: (inout StaggerSim) -> Void
    }

    var lanes: [SimLane]
    var now: Date
    let scheduler: OAuthPollScheduler
    let interval: TimeInterval
    let latency: TimeInterval
    /// Which decision to ask: the sweep, or the fast pool when active.
    let fastPool: Bool
    /// Pacer's requests, at send time.
    var polls: [(token: String, account: String, at: Date)] = []
    /// Another client's requests on a shared token.
    var external: [(token: String, at: Date)] = []

    init(lanes: [SimLane], start: Date, interval: TimeInterval = 300,
         latency: TimeInterval = 0.8, fastPool: Bool = false) {
        self.lanes = lanes
        self.now = start
        self.interval = interval
        self.latency = latency
        self.fastPool = fastPool
        self.scheduler = OAuthPollScheduler(tuning: .init(perTokenMinInterval: interval))
    }

    /// `count` lanes of one account, all last polled at the same instant.
    static func aligned(_ count: Int, account: String = "acct", lastPolledAt: Date?,
                        status: OAuthPollScheduler.AccountStatus = .secondary) -> [SimLane] {
        (0..<count).map {
            SimLane(token: "\(account)-\($0)", account: account,
                    state: .init(lastPolledAt: lastPolledAt, account: status))
        }
    }

    mutating func run(until end: Date, events: [Event] = []) {
        var pending = events.sorted { $0.at < $1.at }
        while now < end {
            while let e = pending.first, e.at <= now {
                pending.removeFirst()
                e.apply(&self)
            }
            let nextEvent = min(pending.first?.at ?? end, end)
            let decision = fastPool
                ? scheduler.decide(lanes: lanes.map(\.state), lastActivityAt: now, now: now)
                : scheduler.decideSweep(lanes: lanes.map(\.state), accountKeys: lanes.map(\.account),
                                        interval: interval, now: now)
            switch decision {
            case .poll(let i)?:
                polls.append((lanes[i].token, lanes[i].account, now))
                now = now.addingTimeInterval(latency)
                lanes[i].state.lastPolledAt = now
                if lanes[i].failuresLeft > 0 {
                    // The poller's cooldown: base 300 s, doubling, capped.
                    lanes[i].failuresLeft -= 1
                    lanes[i].consecutiveFailures += 1
                    let backoff = min(300 * pow(2, Double(lanes[i].consecutiveFailures - 1)), 3_600)
                    lanes[i].state.cooldownUntil = now.addingTimeInterval(backoff)
                } else {
                    lanes[i].consecutiveFailures = 0
                    lanes[i].state.cooldownUntil = nil
                }
            case .wait(let seconds)?:
                now = min(now.addingTimeInterval(seconds), nextEvent)
            case nil:
                now = nextEvent
            }
        }
    }

    /// Another client on `token`, polling every `every` seconds from `from`,
    /// announcing each next poll the way cswap's cache does.
    static func externalClient(on token: String, from: Date, every: TimeInterval, until: Date) -> [Event] {
        stride(from: from.timeIntervalSinceReferenceDate, to: until.timeIntervalSinceReferenceDate, by: every)
            .map { t in
                let at = Date(timeIntervalSinceReferenceDate: t)
                return Event(at: at) { sim in
                    sim.external.append((token, at))
                    for i in sim.lanes.indices where sim.lanes[i].token == token {
                        sim.lanes[i].state.externalLastPollAt = at
                        sim.lanes[i].state.externalLastSuccessAt = at
                        sim.lanes[i].state.externalNextPollAt = at.addingTimeInterval(every)
                    }
                }
            }
    }

    // MARK: Measurements

    /// Gaps between one account's consecutive polls, in `from..<to`.
    func gaps(_ account: String, from: Date = .distantPast, to: Date = .distantFuture) -> [TimeInterval] {
        let times = polls.filter { $0.account == account && $0.at >= from && $0.at < to }.map(\.at)
        return zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }
    }

    /// The shortest spacing between two requests on one token where at least
    /// one is Pacer's, over every token. The per-token invariant.
    var shortestTokenSpacing: TimeInterval {
        var shortest = TimeInterval.infinity
        for token in Set(polls.map(\.token)) {
            let mine = polls.filter { $0.token == token }.map { (at: $0.at, pacer: true) }
            let theirs = external.filter { $0.token == token }.map { (at: $0.at, pacer: false) }
            let all = (mine + theirs).sorted { $0.at < $1.at }
            for (a, b) in zip(all, all.dropFirst()) where a.pacer || b.pacer {
                shortest = min(shortest, b.at.timeIntervalSince(a.at))
            }
        }
        return shortest
    }
}

private func median(_ xs: [TimeInterval]) -> TimeInterval {
    let s = xs.sorted()
    return s.isEmpty ? 0 : s[s.count / 2]
}

@Suite("Lane stagger: the scheduler over simulated hours (#350)")
struct LaneStaggerSchedulerTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 3_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let hour: TimeInterval = 3_600

    /// All lanes due together — a launch after more than an interval away, a
    /// wake — and the account's polls come out a turn apart from the first
    /// round, for any n. A turn is interval/n plus the time a poll takes, since
    /// the gap is measured from when the last answer landed.
    @Test("aligned lanes take even turns from the first round", arguments: [1, 2, 7, 8])
    func alignedLanesTakeTurns(n: Int) {
        var sim = StaggerSim(lanes: StaggerSim.aligned(n, lastPolledAt: at(-1_000)), start: t0)
        sim.run(until: at(3 * hour))
        let turn = 300 / Double(n) + sim.latency
        let gaps = sim.gaps("acct")
        #expect(gaps.count >= Int(3 * hour / turn) - 2)
        #expect(gaps.allSatisfy { abs($0 - turn) < 0.01 },
                "gaps from \(Int(gaps.min() ?? 0)) to \(Int(gaps.max() ?? 0)) s, want \(turn)")
        #expect(sim.shortestTokenSpacing >= 300)
    }

    /// Lanes join and leave: a new token, then two expiring. The gap follows
    /// the lane count within a round, and no token is polled under its floor.
    ///
    /// The one gap allowed under a turn is the first after the leave. The
    /// account's anchor is its newest poll among the lanes it still has, so
    /// when the lane that just went is the one most recently polled, the
    /// anchor falls back a turn and the next poll can come early, once. That
    /// is deliberate: the departed lane's request counted for no other token,
    /// and a lane is dropped mostly when its poll got a 401, which brought no
    /// reading. Keeping the anchor would mean state the scheduler otherwise
    /// does not need.
    @Test("a lane joining and two leaving are absorbed within a round")
    func churnIsAbsorbed() {
        var sim = StaggerSim(lanes: StaggerSim.aligned(7, lastPolledAt: at(-1_000)), start: t0)
        let joins = StaggerSim.Event(at: at(hour)) { sim in
            sim.lanes.append(.init(token: "acct-new", account: "acct",
                                   state: .init(account: .secondary)))
        }
        let leaves = StaggerSim.Event(at: at(2 * hour)) { sim in
            sim.lanes.removeAll { $0.token == "acct-0" || $0.token == "acct-3" }
        }
        sim.run(until: at(3 * hour), events: [joins, leaves])

        #expect(sim.gaps("acct", to: at(2 * hour)).allSatisfy { $0 >= 300 / 8 })
        let afterLeave = sim.gaps("acct", from: at(2 * hour) - 300 / 8)
        #expect(afterLeave.dropFirst(2).allSatisfy { $0 >= 300 / 8 },
                "shortest after the leave \(afterLeave.dropFirst(2).min() ?? 0) s")
        #expect(sim.shortestTokenSpacing >= 300)
        // Settled: one interval after each change, evenly spaced again.
        let eight = sim.gaps("acct", from: at(hour + 300), to: at(2 * hour))
        #expect(eight.allSatisfy { abs($0 - (300 / 8 + sim.latency)) < 0.01 },
                "8 lanes: \(Int(eight.min() ?? 0))–\(Int(eight.max() ?? 0)) s")
        let six = sim.gaps("acct", from: at(2 * hour + 300), to: at(3 * hour))
        #expect(six.allSatisfy { abs($0 - (300 / 6 + sim.latency)) < 0.01 },
                "6 lanes: \(Int(six.min() ?? 0))–\(Int(six.max() ?? 0)) s")
    }

    /// One lane 429s three times running (cooldowns 300, 600, 1200 s). While
    /// it is out, the others share the interval between them rather than
    /// running ahead and leaving a hole; when it is back, the turns re-spread.
    @Test("a backing-off lane neither bunches the others nor leaves a hole")
    func backoffIsAbsorbed() {
        var sim = StaggerSim(lanes: StaggerSim.aligned(7, lastPolledAt: at(-1_000)), start: t0)
        let throttled = StaggerSim.Event(at: at(hour)) { sim in sim.lanes[2].failuresLeft = 3 }
        sim.run(until: at(4 * hour), events: [throttled])

        let all = sim.gaps("acct")
        #expect(all.allSatisfy { $0 >= 300 / 7 }, "shortest \(all.min() ?? 0) s")
        // Never a round-sized hole: at worst a turn of the six remaining lanes,
        // plus the round in which the gap changes over.
        #expect(all.allSatisfy { $0 <= 2 * (300 / 6 + sim.latency) }, "longest \(all.max() ?? 0) s")
        #expect(sim.shortestTokenSpacing >= 300)
        // Long after it recovered: seven even turns again.
        let after = sim.gaps("acct", from: at(3 * hour), to: at(4 * hour))
        #expect(after.allSatisfy { abs($0 - (300 / 7 + sim.latency)) < 0.01 },
                "\(Int(after.min() ?? 0))–\(Int(after.max() ?? 0)) s")
    }

    /// One of the account's tokens is shared with another client (cswap's
    /// parked credential), which polls it every ten minutes. Pacer keeps a
    /// full interval from every one of its requests, and the other lanes keep
    /// taking turns around it.
    @Test("an external client on one shared lane keeps its room and the turns hold")
    func externalClientOnSharedLane() {
        var lanes = StaggerSim.aligned(8, lastPolledAt: at(-1_000))
        // What cswap's cache already says at launch: it polled ten minutes
        // before its next announced poll. Pacer can only keep clear of a
        // request it has been told about.
        lanes[0].state.externalLastPollAt = at(130 - 600)
        lanes[0].state.externalLastSuccessAt = at(130 - 600)
        lanes[0].state.externalNextPollAt = at(130)
        var sim = StaggerSim(lanes: lanes, start: t0)
        let cswap = StaggerSim.externalClient(on: "acct-0", from: at(130), every: 600, until: at(3 * hour))
        sim.run(until: at(3 * hour), events: cswap)

        #expect(sim.shortestTokenSpacing >= 300, "a request on the shared token \(sim.shortestTokenSpacing) s from another")
        let gaps = sim.gaps("acct", from: at(300))
        #expect(gaps.allSatisfy { $0 >= 300 / 8 }, "shortest \(gaps.min() ?? 0) s")
        // Seven lanes always in rotation, the shared one sometimes: turns of
        // a seventh to an eighth of the interval, nothing like a round.
        #expect(median(gaps) <= 300 / 7 + sim.latency + 0.01, "median \(median(gaps)) s")
        #expect(gaps.allSatisfy { $0 <= 2 * (300 / 7 + sim.latency) }, "longest \(gaps.max() ?? 0) s")
    }

    /// Two non-active accounts are spaced independently: different tokens,
    /// different budgets, so one never waits on the other.
    @Test("two accounts each take their own turns")
    func twoAccountsIndependently() {
        let lanes = StaggerSim.aligned(7, account: "work", lastPolledAt: at(-1_000))
            + StaggerSim.aligned(2, account: "home", lastPolledAt: at(-1_000))
        var sim = StaggerSim(lanes: lanes, start: t0)
        sim.run(until: at(3 * hour))
        let work = sim.gaps("work"), home = sim.gaps("home")
        // The other account's poll can sit between two of this one's, adding
        // one poll's latency to that gap; never less than a turn.
        #expect(work.allSatisfy { $0 >= 300 / 7 && $0 <= 300 / 7 + 2 * sim.latency + 0.01 },
                "work \(Int(work.min() ?? 0))–\(Int(work.max() ?? 0)) s")
        #expect(home.allSatisfy { $0 >= 150 && $0 <= 150 + 2 * sim.latency + 0.01 },
                "home \(Int(home.min() ?? 0))–\(Int(home.max() ?? 0)) s")
        #expect(sim.shortestTokenSpacing >= 300)
    }

    /// The active account's fast pool had the account gap already; what it
    /// lacked was the count. With one of seven lanes in a long cooldown it
    /// spaced polls for seven, so six ran ahead and the seventh's turn was a
    /// hole every round. Counted over the lanes in rotation, six share the
    /// interval evenly.
    @Test("the fast pool spaces turns over the lanes actually in rotation")
    func fastPoolCountsLanesInRotation() {
        var lanes = StaggerSim.aligned(7, lastPolledAt: at(-1_000), status: .primary)
        lanes[4].state.cooldownUntil = at(3 * hour)
        var sim = StaggerSim(lanes: lanes, start: t0, fastPool: true)
        sim.run(until: at(2 * hour))
        let gaps = sim.gaps("acct", from: at(300))
        #expect(gaps.allSatisfy { abs($0 - (300 / 6 + sim.latency)) < 0.01 },
                "\(Int(gaps.min() ?? 0))–\(Int(gaps.max() ?? 0)) s, want \(Int(300 / 6)) s")
        #expect(sim.shortestTokenSpacing >= 300)
    }

    /// The forward check against another client's announced poll is measured
    /// from when Pacer would actually go. A lane ready long ago but held back
    /// by its account's turn must not then land inside the other client's
    /// interval.
    @Test("a lane held back for its turn still keeps clear of an announced external poll")
    func heldBackLaneRespectsExternalAnnouncement() {
        let scheduler = OAuthPollScheduler()
        let now = at(0)
        // Ready since -100 by its own floor, which left exactly an interval
        // before the announced request; polling now would sit 200 s in front
        // of it. (Measured from -100, as it was, this read as room.)
        let lane = OAuthPollScheduler.LaneState(
            lastPolledAt: at(-400), externalNextPollAt: at(200), account: .secondary)
        #expect(scheduler.readyAt(lane, interval: 300, now: now) == at(500))
        // With a full interval of room from now, it is ready.
        let roomy = OAuthPollScheduler.LaneState(
            lastPolledAt: at(-400), externalNextPollAt: at(400), account: .secondary)
        #expect(scheduler.readyAt(roomy, interval: 300, now: now) <= now)
    }

    @Test("decideSweep has nothing to say without a non-active lane")
    func noSecondaryLanes() {
        let scheduler = OAuthPollScheduler()
        let lanes = StaggerSim.aligned(3, lastPolledAt: nil, status: .primary).map(\.state)
        #expect(scheduler.decideSweep(lanes: lanes, accountKeys: ["a", "a", "a"], interval: 300, now: t0) == nil)
        #expect(scheduler.decideSweep(lanes: [], accountKeys: [], interval: 300, now: t0) == nil)
    }
}

@Suite("Sweep log line (#350)")
struct SweepLogLineTests {
    @Test("the hourly sweep line reports the spread of the account's polls")
    func spreadSummary() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let even = (0...84).map { t0.addingTimeInterval(Double($0) * 300 / 7) }
        #expect(OAuthPoller.sweepSpread(even) == "; 84 polls in 60 min, gap median 43 s, shortest 43 s")
        // Seven together, then a pause: the shape #350 reported.
        let bunched = (0..<3).flatMap { round in
            (0..<7).map { t0.addingTimeInterval(Double(round) * 300 + Double($0) * 6) }
        }
        #expect(OAuthPoller.sweepSpread(bunched) == "; 20 polls in 11 min, gap median 6 s, shortest 6 s")
        #expect(OAuthPoller.sweepSpread([t0, t0.addingTimeInterval(40)]) == "")
    }
}
