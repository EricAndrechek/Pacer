import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// Arena models running for real: the adapter, the background scorer, the
/// engine's selection over their record, and the live path that never waits
/// on them. The models here are test doubles registered for the suite; the
/// real ports register in `ArenaRegistry` on their own branches.
@Suite("Arena runtime: scorer, selection and live path", .serialized)
struct RuntimeEngineTests {

    // MARK: Fixtures

    /// Whole minutes, near the real clock: the live path cuts the history at
    /// the wall clock, as the app does.
    static let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
    static let account = "acct-runtime"
    static let fiveHours: TimeInterval = 5 * 3600

    /// `cycles` completed five-hour cycles back to back, newest ending an hour
    /// ago, then a live one two hours in. Each climbs slowly then jumps in its
    /// last hour, which no curve fit sees coming.
    static func seeded(cycles: Int = 12) throws -> ModelContainer {
        let container = try PacerStore.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Account(id: account, organizationId: account, displayName: "Test", isActive: true,
                           firstSeenAt: now.addingTimeInterval(-90 * 86400), lastSeenAt: now))
        let liveStart = now.addingTimeInterval(-2 * 3600)
        for c in 0...cycles {
            let start = liveStart.addingTimeInterval(-Double(cycles - c) * (fiveHours + 3600))
            let reset = start.addingTimeInterval(fiveHours)
            let jump = 30.0 + Double(c % 4) * 10
            var t = start.addingTimeInterval(300)
            while t < reset && t <= now {
                let h = t.timeIntervalSince(start) / 3600
                let pct = h < 4 ? h * 5 : 20 + (h - 4) * jump
                ctx.insert(RateLimitSample(sampledAt: t, window: "five_hour", usedPercentage: pct.rounded(),
                                           resetsAt: reset, source: "oauth", accountId: account))
                t = t.addingTimeInterval(600)
            }
        }
        try ctx.save()
        return container
    }

    /// Reads the raw store, future rows included, and forecasts the cycle's
    /// final reading flat: a model built to cheat, so it scores perfectly
    /// wherever the history lets it see the future.
    final class Oracle: ArenaModel {
        var history: ArenaHistory?
        init(context: ArenaContext) {}
        func fit(_ history: ArenaHistory) { self.history = history }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            guard let h = history else { throw ArenaError.invalid("not fitted") }
            var out: [String: ArenaTargetForecast] = [:]
            for tr in request.targets {
                let all = h.store.meters[tr.meter] ?? []
                let reset = tr.resetAt ?? 0
                let final = all.filter { r in r.resetsAt.map { abs($0 - reset) < tr.target.windowMillis / 2 } ?? false }
                    .compactMap(\.utilPct).max() ?? 0
                out[tr.key] = .point(Array(repeating: final, count: tr.grid.count))
            }
            return ArenaForecast(byKey: out)
        }
    }

    /// The honest twin: the largest reading of the cycle the history hands
    /// it, flat.
    final class Peeker: ArenaModel {
        var history: ArenaHistory?
        init(context: ArenaContext) {}
        func fit(_ history: ArenaHistory) { self.history = history }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            guard let h = history else { throw ArenaError.invalid("not fitted") }
            var out: [String: ArenaTargetForecast] = [:]
            for tr in request.targets {
                let reset = tr.resetAt ?? 0
                let seen = h.readings(tr.meter)
                    .filter { r in r.resetsAt.map { abs($0 - reset) < tr.target.windowMillis / 2 } ?? false }
                    .compactMap(\.utilPct).max() ?? 0
                out[tr.key] = .point(Array(repeating: seen, count: tr.grid.count))
            }
            return ArenaForecast(byKey: out)
        }
    }

    /// Counts every time anything runs it.
    final class Bomb: ArenaModel {
        nonisolated(unsafe) static var runs = 0
        static let lock = NSLock()
        init(context: ArenaContext) {}
        func fit(_ history: ArenaHistory) { Self.lock.lock(); Self.runs += 1; Self.lock.unlock() }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast { throw ArenaError.invalid("boom") }
    }

    static let meters: Set<ArenaTarget> = [.meterFiveHour, .meterSevenDay, .meterScoped]
    static let oracle = ArenaModelSpec(name: "test-oracle", targets: meters, complexity: 4) { Oracle(context: $0) }
    static let peeker = ArenaModelSpec(name: "test-peeker", targets: meters, complexity: 2) { Peeker(context: $0) }
    static let bomb = ArenaModelSpec(name: "test-bomb", targets: meters, complexity: 1) { Bomb(context: $0) }
    static let helper = ArenaModelSpec(name: "port-engine-recent-rate", targets: meters) { try PortEngineModel(context: $0) }

    static func noSleep() -> ArenaRecordScorer.Config {
        var c = ArenaRecordScorer.Config()
        c.dutyCycle = 1
        return c
    }

    /// Records every batch the scorer hands over.
    final class Landed: @unchecked Sendable {
        let lock = NSLock()
        var batches: [[EngineSelfEval.NewOutcome]] = []
        var liveAccounts: [Set<String>] = []
        func add(_ b: [EngineSelfEval.NewOutcome]) { lock.lock(); batches.append(b); lock.unlock() }
        func live(_ a: Set<String>) { lock.lock(); liveAccounts.append(a); lock.unlock() }
        var all: [EngineSelfEval.NewOutcome] { lock.lock(); defer { lock.unlock() }; return batches.flatMap { $0 } }
    }

    static func runtime(_ container: ModelContainer, roster: [ArenaModelSpec],
                        config: ArenaRecordScorer.Config = noSleep(), landed: Landed = Landed(),
                        engine: UsageIntelligenceEngine? = nil) -> ArenaRuntime {
        ArenaRuntime(container: container, roster: ArenaRoster(registry: roster), config: config,
                     onRecordLanded: { _, news in
                         landed.add(news)
                         _ = await engine?.ingestArenaOutcomes(news)
                     },
                     onLiveLanded: { accounts in landed.live(accounts) })
    }

    static func arenaRows(_ container: ModelContainer, method: String) throws -> [EngineEvalOutcome] {
        try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>()).filter { $0.method == method }
    }

    // MARK: Adapter

    /// The adapter cuts the history at the partial cycle's `now`: a model
    /// that reads everything the history hands it sees nothing later, while
    /// one that reaches past the cut into the raw store is caught doing so.
    @Test func theAdapterNeverHandsAModelTheFuture() throws {
        let container = try Self.seeded()
        let built = ArenaHistoryBuilder.build(container: container, account: Self.account, now: Self.now,
                                              pricing: .init(pricingByModel: [:], ledger: .empty))
        let samples = built.store.meters[ArenaMeterID(account: Self.account, windowKind: "five_hour")]!
            .map { (at: ArenaTime.date($0.tEvent), usedPercentage: $0.utilPct!, resetsAt: ArenaTime.date($0.resetsAt!)) }
        let (_, history) = BurnTrajectory.segment(samples: samples, duration: Self.fiveHours, now: Self.now)
        let cycle = try #require(history.last)
        let cutNow = cycle.cycleStart.addingTimeInterval(Self.fiveHours * 0.5)
        let seen = cycle.samples.filter { $0.at <= cutNow }
        let partial = BurnTrajectory.PartialCycle(samples: seen, now: cutNow, cycleStart: cycle.cycleStart,
                                                  resetsAt: cycle.resetsAt)
        let binding = ArenaWindowBinding(account: Self.account, windowKey: "five_hour", target: .meterFiveHour, cap: nil)
        let registry = [Self.peeker, Self.oracle]
        let honest = ArenaBurnModel(spec: Self.peeker, binding: binding, store: built.store, registry: registry)
        let cheat = ArenaBurnModel(spec: Self.oracle, binding: binding, store: built.store, registry: registry)
        let truth = cycle.samples.map(\.usedPercentage).max()!
        let seenMax = seen.map(\.usedPercentage).max()!
        #expect(seenMax < truth)
        let h = try #require(honest.fit(partial))
        #expect(h(cycle.resetsAt) == seenMax)
        // The leak detector: the cheat's value is the future's.
        let c = try #require(cheat.fit(partial))
        #expect(c(cycle.resetsAt) == truth)
    }

    @Test func aProjectionIsTheMedianPathHeldAtTheEnds() throws {
        let p = try #require(ArenaProjection(grid: [1_000, 2_000, 4_000], median: [10, 20, 40]))
        #expect(p.value(at: ArenaTime.date(0)) == 10)
        #expect(p.value(at: ArenaTime.date(1_500)) == 15)
        #expect(p.value(at: ArenaTime.date(3_000)) == 30)
        #expect(p.value(at: ArenaTime.date(9_000)) == 40)
        #expect(ArenaProjection(grid: [1, 2], median: [.nan, 1]) == nil)
    }

    // MARK: Scorer

    @Test func theScorerFillsTheRecordOnceAndResumes() async throws {
        let container = try Self.seeded()
        let rt = Self.runtime(container, roster: [Self.peeker, Self.helper])
        let first = await rt.scorer.pass(accounts: [Self.account], now: Self.now)
        // 12 completed cycles × 8 cuts (every cut has ≥ 3 readings), one
        // selectable model; the helper is never scored.
        #expect(first.cycles == 12)
        #expect(first.outcomes == 12 * 8)
        #expect(try Self.arenaRows(container, method: "test-peeker").count == 96)
        #expect(try Self.arenaRows(container, method: "port-engine-recent-rate").isEmpty)
        let surfaces = Set(try Self.arenaRows(container, method: "test-peeker").map(\.surface))
        #expect(surfaces == ["rl-five_hour#\(Self.account)"])

        // Again, same process: nothing left.
        let second = await rt.scorer.pass(accounts: [Self.account], now: Self.now)
        #expect(second.outcomes == 0)

        // A quit part-way: drop a third of the rows; a new process finds and
        // scores exactly those.
        let ctx = ModelContext(container)
        let rows = try Self.arenaRows(container, method: "test-peeker").sorted { $0.key < $1.key }
        let dropped = rows.enumerated().filter { $0.offset % 3 == 0 }.map(\.element.key)
        for row in try ctx.fetch(FetchDescriptor<EngineEvalOutcome>()) where dropped.contains(row.key) { ctx.delete(row) }
        try ctx.save()
        let relaunched = Self.runtime(container, roster: [Self.peeker, Self.helper])
        let third = await relaunched.scorer.pass(accounts: [Self.account], now: Self.now)
        #expect(third.outcomes == dropped.count)
        #expect(try Self.arenaRows(container, method: "test-peeker").count == 96)
    }

    @Test func theScorerTakesTheNewestCyclesFirst() async throws {
        let container = try Self.seeded()
        var config = Self.noSleep()
        config.sessionCycleCap = 3
        let landed = Landed()
        let rt = Self.runtime(container, roster: [Self.peeker], config: config, landed: landed)
        _ = await rt.scorer.pass(accounts: [Self.account], now: Self.now)
        let order = landed.batches.compactMap { $0.first?.periodKey }
        #expect(order.count == 3)
        #expect(order == order.sorted(by: >))
        // Exactly the three newest completed cycles.
        let engineSegments = try Self.completedResets(container)
        #expect(Set(order) == Set(engineSegments.suffix(3)))
    }

    static func completedResets(_ container: ModelContainer) throws -> [String] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<RateLimitSample>())
        let samples = rows.map { (at: $0.sampledAt, usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt!) }
        let (_, history) = BurnTrajectory.segment(samples: samples, duration: fiveHours, now: now)
        return history.filter { $0.resetsAt <= now }.map { EngineSelfEval.periodKeyRL($0.resetsAt) }.sorted()
    }

    @Test func aModelWithoutItsWeightsIsNotScored() async throws {
        let container = try Self.seeded()
        let pinned = ArenaModelSpec(name: "test-pinned", targets: Self.meters, weights: ["acme/net@abc"]) {
            Peeker(context: $0)
        }
        let rt = Self.runtime(container, roster: [pinned])
        let report = await rt.scorer.pass(accounts: [Self.account], now: Self.now)
        #expect(report.forecasts == 0)
    }

    @Test func stoppingEndsTheLoop() async throws {
        let container = try Self.seeded()
        let rt = Self.runtime(container, roster: [Self.peeker])
        rt.start(accounts: { [Self.account] })
        await rt.stop()
        let after = await rt.scorer.pass(accounts: [Self.account], now: Self.now)
        #expect(after.forecasts == 0)
    }

    // MARK: Selection and the live path

    static func engine(_ container: ModelContainer) async -> UsageIntelligenceEngine {
        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.adopt(scope: .account(account))
        return engine
    }

    /// The whole loop: the engine scores its roster, the scorer scores the
    /// arena model into the same record, the engine picks it because it beat
    /// every curve fit, and once its live projection lands the outlook is
    /// its own.
    @Test func theRecordPicksAnArenaModelThatBeatsTheRosterAndTheLiveLineFollows() async throws {
        let container = try Self.seeded()
        let engine = await Self.engine(container)
        let landed = Landed()
        let rt = Self.runtime(container, roster: [Self.oracle], landed: landed, engine: engine)
        await engine.adopt(arena: rt.link)
        await engine.recompute(now: Self.now)
        #expect(await engine.resolvedMethod(windowKey: "five_hour").selected != "test-oracle")

        _ = await rt.scorer.pass(accounts: [Self.account], now: Self.now)
        #expect(landed.all.count == 96)
        await engine.recompute(now: Self.now)
        let picked = await engine.resolvedMethod(windowKey: "five_hour")
        #expect(picked.selected == "test-oracle")
        #expect(await engine.arenaModelIds(windowKey: "five_hour") == ["test-oracle"])

        // The refit asked for the live projection without waiting for it;
        // the request itself hops through a task, so wait for it to land.
        var redrawn = false
        for _ in 0..<500 where !redrawn {
            await rt.live.settle()
            redrawn = await engine.refreshArenaResolution()
            if !redrawn { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(redrawn)
        #expect(await engine.resolvedMethod(windowKey: "five_hour").resolved == "test-oracle")
        let outlook = await engine.ask(.rateLimitOutlook(.fiveHour))
        #expect(outlook.method == "rl-test-oracle")
        let lines = await engine.rateLimitTrajectories(window: .fiveHour)
        #expect(lines.first { $0.modelId == "test-oracle" }?.canProject == true)
        #expect(lines.first { $0.isSelected }?.modelId == "test-oracle")
    }

    /// A refit never runs an arena model: with the projection not made yet
    /// the window draws the best-recorded model that can fit, and the arena
    /// model is listed as still computing.
    @Test func theLivePathNeverWaitsOnAnArenaModel() async throws {
        let container = try Self.seeded()
        // A perfect record for the bomb, written as the scorer would.
        let ctx = ModelContext(container)
        let surface = EngineScope.account(Self.account).qualify(EngineSelfEval.rlSurface("five_hour"))
        for period in try Self.completedResets(container) {
            for cf in EngineSelfEval.rlCutFractions {
                ctx.insert(EngineEvalOutcome(surface: surface, method: "test-bomb", bucket: EngineSelfEval.rlBucket(cf),
                                             periodKey: period, predicted: 50, truth: 50))
            }
        }
        try ctx.save()
        Bomb.runs = 0
        let engine = await Self.engine(container)
        let asked = Landed()
        let link = ArenaEngineLink(roster: ArenaRoster(registry: [Self.bomb]), cache: ArenaLiveCache(),
                                   requestLive: { reqs in asked.live(Set(reqs.flatMap(\.models))) })
        await engine.adopt(arena: link)
        await engine.recompute(now: Self.now)
        let m = await engine.resolvedMethod(windowKey: "five_hour")
        #expect(m.selected == "test-bomb")
        #expect(m.resolved != nil && m.resolved != "test-bomb")
        #expect(Bomb.runs == 0)
        #expect(asked.liveAccounts == [["test-bomb"]])
        let outlook = await engine.ask(.rateLimitOutlook(.fiveHour))
        #expect(!outlook.isInsufficient)
        #expect(outlook.method != "rl-test-bomb")
        let row = await engine.rateLimitTrajectories(window: .fiveHour).first { $0.modelId == "test-bomb" }
        #expect(row?.unavailableReason == "still computing")
        #expect(await engine.refreshArenaResolution() == false)
        #expect(Bomb.runs == 0)
    }

    /// Without the runtime the engine is exactly as before, arena rows in the
    /// record or not.
    @Test func withoutTheRuntimeArenaRowsAreIgnored() async throws {
        let container = try Self.seeded()
        let ctx = ModelContext(container)
        let surface = EngineScope.account(Self.account).qualify(EngineSelfEval.rlSurface("five_hour"))
        for period in try Self.completedResets(container) {
            for cf in EngineSelfEval.rlCutFractions {
                ctx.insert(EngineEvalOutcome(surface: surface, method: "test-bomb", bucket: EngineSelfEval.rlBucket(cf),
                                             periodKey: period, predicted: 50, truth: 50))
            }
        }
        try ctx.save()
        let engine = await Self.engine(container)
        await engine.recompute(now: Self.now)
        #expect(await engine.resolvedMethod(windowKey: "five_hour").selected != "test-bomb")
        #expect(await engine.arenaModelIds(windowKey: "five_hour").isEmpty)
    }

    /// A model well behind the engine's best on the cycles it was scored on
    /// stops being scored deeper, here and in every later pass.
    @Test func aClearLoserStopsBeingScoredDeeper() async throws {
        let container = try Self.seeded(cycles: 40)
        // A perfect engine record to lose to.
        let ctx = ModelContext(container)
        let surface = EngineScope.account(Self.account).qualify(EngineSelfEval.rlSurface("five_hour"))
        let finals = try Self.completedFinals(container)
        for (period, final) in finals {
            for cf in EngineSelfEval.rlCutFractions {
                ctx.insert(EngineEvalOutcome(surface: surface, method: "linear-recent", bucket: EngineSelfEval.rlBucket(cf),
                                             periodKey: period, predicted: final, truth: final))
            }
        }
        try ctx.save()
        let rt = Self.runtime(container, roster: [Self.peeker])
        let first = await rt.scorer.pass(accounts: [Self.account], now: Self.now)
        // Six turns of four cycles, then judged.
        #expect(first.cycles == 24)
        #expect(try Self.arenaRows(container, method: "test-peeker").count == 24 * 8)
        let again = Self.runtime(container, roster: [Self.peeker])
        #expect(await again.scorer.pass(accounts: [Self.account], now: Self.now).forecasts == 0)
    }

    static func completedFinals(_ container: ModelContainer) throws -> [(String, Double)] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<RateLimitSample>())
        let samples = rows.map { (at: $0.sampledAt, usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt!) }
        let (_, history) = BurnTrajectory.segment(samples: samples, duration: fiveHours, now: now)
        return history.filter { $0.resetsAt <= now }.map {
            (EngineSelfEval.periodKeyRL($0.resetsAt), $0.samples.map(\.usedPercentage).max() ?? 0)
        }
    }

    @Test func losersAreJudgedAgainstTheEnginesBestOnTheirOwnCycles() {
        func rows(_ m: String, _ n: Int, err: Double, from: Int = 1) -> [EngineSelfEval.Record] {
            (from..<(from + n)).map {
                .init(method: m, bucket: "cut=0.50|v2", periodKey: String(format: "2026-01-%02dT00:00:00Z", $0),
                      predicted: 50 + err, truth: 50)
            }
        }
        let engine = rows("linear-recent", 30, err: 3)
        let records = engine + rows("far", 24, err: 6) + rows("close", 24, err: 5) + rows("young", 10, err: 40)
        let losers = EngineSelfEval.arenaLosers(records, arenaIds: ["far", "close", "young"], weekly: false)
        #expect(losers == ["far"])          // 6 > 3 × 1.5 + 1; 5 is not; 10 cycles is too few to judge
        // A loser neither counts for selection nor shortens the span.
        let shallowLoser = engine + rows("close", 24, err: 2, from: 7) + rows("far", 24, err: 9, from: 1)
        let out = EngineSelfEval.arenaComparable(shallowLoser, arenaIds: ["far", "close"], weekly: false)
        #expect(!out.contains { $0.method == "far" })
        #expect(Set(out.map(\.periodKey)).count == 24)
    }

    @Test func comparableRecordsShareOneSpan() {
        func r(_ m: String, _ p: String, _ err: Double) -> EngineSelfEval.Record {
            .init(method: m, bucket: "cut=0.50|v2", periodKey: p, predicted: 50 + err, truth: 50)
        }
        let engineRows = (1...20).map { r("linear-recent", String(format: "2026-01-%02dT00:00:00Z", $0), 3) }
        let arenaRows = (13...20).map { r("arena-a", String(format: "2026-01-%02dT00:00:00Z", $0), 1) }
        let thin = (19...20).map { r("arena-b", String(format: "2026-01-%02dT00:00:00Z", $0), 0) }
        let out = EngineSelfEval.arenaComparable(engineRows + arenaRows + thin, arenaIds: ["arena-a", "arena-b"],
                                                 weekly: false)
        // From arena-a's first cycle on; arena-b, two cycles in, is left out.
        #expect(Set(out.map(\.periodKey)).count == 8)
        #expect(out.filter { $0.method == "linear-recent" }.count == 8)
        #expect(!out.contains { $0.method == "arena-b" })
        // No arena rows: unchanged.
        #expect(EngineSelfEval.arenaComparable(engineRows, arenaIds: ["arena-a"], weekly: false) == engineRows)
        // Only thin arena rows: the engine's record alone.
        #expect(EngineSelfEval.arenaComparable(engineRows + thin, arenaIds: ["arena-b"], weekly: false) == engineRows)
    }
}
