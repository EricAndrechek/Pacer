import Foundation
import SwiftData
import CryptoKit

/// Abstraction over wall-clock time for the poller's loop. Production
/// uses `SystemPollerClock`. Tests inject a controllable clock so they
/// can drive cadence and backoff without real-time `Task.sleep` calls.
///
/// We don't use Swift's built-in `Clock` protocol here because its
/// associated-type design would force the poller to be generic over
/// `Clock`, which complicates storing and stopping the loop task; a
/// Sendable existential is simpler for a single use site.
public protocol PollerClock: Sendable {
    /// Wall-clock time. Used to compute `nextPollAt` and timestamp
    /// log lines; we never compare clock readings across actors.
    func now() -> Date

    /// Suspend for `seconds`. Must respect `Task.isCancelled` —
    /// `stop()` cancels the loop task and the next sleep needs to
    /// throw `CancellationError` so the loop unwinds quickly.
    func sleep(seconds: TimeInterval) async throws
}

/// Production clock — `Date()` and cooperative `Task.sleep`. Marked
/// `@unchecked Sendable` because it has no mutable state; the
/// `Task.sleep` call participates correctly in cooperative cancellation.
public struct SystemPollerClock: PollerClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        // Negative or zero — return immediately. Task.sleep would
        // accept zero but on some platforms negative is undefined.
        if seconds <= 0 {
            try Task.checkCancellation()
            return
        }
        let nanos = UInt64((seconds * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: nanos)
    }
}

/// Polls `/api/oauth/usage` with an **adaptive, multi-token cadence**.
///
/// The endpoint computes usage live per request but rate-limits to ~1
/// poll / 5 min / token with no budget headers (over-poll ⇒ ~30-min
/// throttle). An account often has several independent tokens (Claude
/// Code + Claude Desktop), each its own budget. So the poller keeps one
/// **lane** per discovered token and lets `OAuthPollScheduler` spread
/// polls across them: a tighter *effective* cadence when you're actively
/// burning tokens (interleaving two lanes → ~2.5 min), relaxing when
/// idle, while **no single lane is ever polled more than once per 5
/// min** — the invariant that keeps every lane off the throttle. With
/// one token it degrades cleanly to single-lane activity-gating.
///
/// Safety rails:
///   - **Same-account guard.** The first successful poll sets the pool's
///     primary account (from `anthropic-organization-id`); a lane that
///     resolves to a different org is marked foreign — never selected,
///     never persisted — so interleaving can't mix two accounts.
///   - **Per-lane cooldown.** A 429/transport/5xx cools *that lane*
///     (exponential, capped); other lanes keep the timeline fresh.
///   - **Poll-on-wake.** `notifyActivity()` (called by the coordinator
///     when new usage lands) wakes the loop to re-evaluate — the
///     scheduler still enforces the per-token floor, so a nudge can
///     never over-poll.
///
/// `start()`/`stop()` symmetrical; safe to call from any context.
public actor OAuthPoller: TokenPoolTesting {

    public struct Configuration: Sendable {
        /// Cadence policy (per-token floor, active/idle targets, activity
        /// window). See `OAuthPollScheduler.Tuning`.
        public var scheduler: OAuthPollScheduler.Tuning
        /// Optional delay before the first discovery + poll. Lets the
        /// JSONL scanner settle first. Default 0.
        public var startupDelay: TimeInterval
        /// First cooldown applied to a lane after a failed poll; doubles
        /// per consecutive failure on that lane.
        public var laneCooldownBase: TimeInterval
        /// Cap on a lane's cooldown.
        public var laneCooldownMax: TimeInterval
        /// How long a discovered lane set is reused before re-running
        /// candidate discovery (picks up Desktop token rotation / new
        /// logins). Discovery also runs whenever no usable lane remains.
        public var laneRediscoverInterval: TimeInterval

        public init(
            scheduler: OAuthPollScheduler.Tuning = .init(),
            startupDelay: TimeInterval = 0,
            laneCooldownBase: TimeInterval = 300,
            laneCooldownMax: TimeInterval = 3600,
            laneRediscoverInterval: TimeInterval = 1800
        ) {
            self.scheduler = scheduler
            self.startupDelay = startupDelay
            self.laneCooldownBase = laneCooldownBase
            self.laneCooldownMax = laneCooldownMax
            self.laneRediscoverInterval = laneRediscoverInterval
        }
    }

    /// Categorized outcome of one poll, surfaced for tests and debug UI.
    public enum PollOutcome: Sendable, Equatable {
        case success(fiveHourPct: Double?, sevenDayPct: Double?)
        case foreignAccount            // succeeded but a different org — dropped
        case credentialsNotFound       // no usable token / lane at all
        case keychainAccessDenied
        case keychainMalformed
        case keychainStatus(OSStatus)
        case tokenExpired
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case http(status: Int)
        case transport
        case responseSchemaMismatch
    }

    public struct Snapshot: Sendable {
        public let lastOutcome: PollOutcome?
        public let laneCount: Int
        public let primaryLaneCount: Int
        public let nextPollAt: Date?
        public let lastPollAt: Date?
        public let primaryOrg: String?
    }

    public typealias RandomSource = @Sendable () -> Double

    /// One pollable token + its scheduling state.
    private struct Lane {
        let credential: OAuthCredential
        let source: CredentialCandidate.Source
        var state: OAuthPollScheduler.LaneState
        var consecutiveFailures: Int
        /// The account this token resolved to (from a successful poll's
        /// `anthropic-organization-id`); nil until first polled.
        var resolvedOrg: String?
    }

    private let client: OAuthClient
    private let container: ModelContainer
    private let configuration: Configuration
    private let clock: PollerClock
    private let scheduler: OAuthPollScheduler
    private let activityProbe: @Sendable () async -> Date?
    private let random: RandomSource

    private var lanes: [Lane] = []
    private var primaryOrg: String?
    private var lastDiscoveryAt: Date?
    /// Most recent activity time seen by the loop, cached so status
    /// publishes can report active/idle without another probe.
    private var lastActivityAt: Date?
    private var lastOutcome: PollOutcome?
    private var lastPollAt: Date?
    private var nextPollAt: Date?

    private var loopTask: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var stopping = false

    public init(
        client: OAuthClient = OAuthClient(),
        container: ModelContainer,
        configuration: Configuration = Configuration(),
        clock: PollerClock = SystemPollerClock(),
        activityProbe: (@Sendable () async -> Date?)? = nil,
        random: @escaping RandomSource = { Double.random(in: 0..<1) }
    ) {
        self.client = client
        self.container = container
        self.configuration = configuration
        self.clock = clock
        self.scheduler = OAuthPollScheduler(tuning: configuration.scheduler)
        self.activityProbe = activityProbe ?? Self.defaultActivityProbe(container: container)
        self.random = random
    }

    // MARK: - Lifecycle

    /// Spawn the loop task. Idempotent.
    public func start() {
        guard loopTask == nil else { return }
        stopping = false
        // Let the Settings "Tokens" section route Test clicks back here.
        Task { await MainActor.run { TokenPoolStatus.shared.tester = self } }
        loopTask = Task { [weak self] in
            await self?.loop()
        }
    }

    /// Cancel the loop and wait for it to unwind. Idempotent.
    public func stop() async {
        stopping = true
        sleeper?.cancel()
        loopTask?.cancel()
        let task = loopTask
        loopTask = nil
        await task?.value
    }

    /// Wake the loop to re-evaluate cadence — call when fresh Claude
    /// usage lands so an idle→active transition polls promptly. Safe to
    /// call at any rate: the scheduler still enforces the per-token
    /// floor, so a nudge can never cause an over-poll.
    public func notifyActivity() {
        sleeper?.cancel()
    }

    /// Test entry — discover lanes and poll the best eligible one once,
    /// ignoring the cadence gate (but honoring foreign/cooldown). Returns
    /// the categorized outcome. Does NOT loop or sleep.
    @discardableResult
    public func runOnce() async -> PollOutcome {
        ensureLanes()
        let now = clock.now()
        let idx = lanes.indices
            .filter {
                lanes[$0].state.account != .foreign
                    && (lanes[$0].state.cooldownUntil.map { now >= $0 } ?? true)
            }
            .min { (lanes[$0].state.lastPolledAt ?? .distantPast) < (lanes[$1].state.lastPolledAt ?? .distantPast) }
        guard let idx else {
            lastOutcome = .credentialsNotFound
            return .credentialsNotFound
        }
        return await pollLane(idx)
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            lastOutcome: lastOutcome,
            laneCount: lanes.count,
            primaryLaneCount: lanes.filter { $0.state.account == .primary }.count,
            nextPollAt: nextPollAt,
            lastPollAt: lastPollAt,
            primaryOrg: primaryOrg
        )
    }

    // MARK: - Manual test + status publishing (TokenPoolTesting)

    /// Stable, non-reversible id for a token — 12 hex chars of its
    /// SHA-256. The lane's UI identity + test-routing key; never exposes
    /// token bytes.
    private static func laneId(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Test an existing lane by id. Routes through the normal poll path so
    /// the reading is persisted and the lane is stamped — a manual test
    /// spends that token's budget through the same accounting as an auto
    /// poll, never a hidden extra request.
    public func testLane(id: String) async -> TokenTestResult {
        ensureLanes()
        guard let idx = lanes.firstIndex(where: { Self.laneId($0.credential.accessToken) == id }) else {
            return .failure(reason: "That token is no longer available.")
        }
        let outcome = await pollLane(idx)
        await publishStatus()
        return Self.testResult(from: outcome)
    }

    /// Test a raw token the UI holds (an unsaved override draft). If it's
    /// already a lane, route through it (stamped/counted); otherwise poll
    /// once and persist when it's the same account, so the reading isn't
    /// thrown away.
    public func testAdHoc(token: String) async -> TokenTestResult {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(reason: "Empty token.") }
        ensureLanes()
        if let idx = lanes.firstIndex(where: { $0.credential.accessToken == trimmed }) {
            let outcome = await pollLane(idx)
            await publishStatus()
            return Self.testResult(from: outcome)
        }
        let cred = OAuthCredential(accessToken: trimmed, expiresAt: nil, subscriptionType: nil)
        switch await client.fetchUsage(using: cred) {
        case .success(let snap):
            let org = snap.organizationId
            let matches: Bool
            if let primary = primaryOrg { matches = (org == nil || org == primary) }
            else { primaryOrg = org; matches = true }
            if matches {
                await persist(snap, laneSource: .override)
                return .success(fiveHour: snap.fiveHour?.usedPercentage, sevenDay: snap.sevenDay?.usedPercentage)
            }
            return .foreignAccount(org: org)
        case .failure(let error):
            return Self.testFailure(error)
        }
    }

    /// Publish a display-safe snapshot of the lane pool + effective
    /// cadence to `TokenPoolStatus.shared` for the Settings section.
    private func publishStatus() async {
        let tuning = configuration.scheduler
        let usable = lanes.filter { $0.state.account != .foreign }.count
        let active = lastActivityAt.map { clock.now().timeIntervalSince($0) <= tuning.activeWindow } ?? false
        let realizedActive = max(tuning.activeInterval, tuning.perTokenMinInterval / Double(max(usable, 1)))
        let effective: TimeInterval? = usable == 0 ? nil : (active ? realizedActive : tuning.idleInterval)
        let statuses = lanes.enumerated().map { i, lane in
            TokenLaneStatus(
                id: Self.laneId(lane.credential.accessToken),
                source: lane.source,
                organizationId: lane.resolvedOrg,
                account: lane.state.account,
                expiresAt: lane.credential.expiresAt,
                lastPolledAt: lane.state.lastPolledAt,
                cooldownUntil: lane.state.cooldownUntil,
                consecutiveFailures: lane.consecutiveFailures,
                priority: i
            )
        }
        await MainActor.run {
            TokenPoolStatus.shared.publish(lanes: statuses, isActive: active, effectiveIntervalSeconds: effective)
        }
    }

    private static func testResult(from outcome: PollOutcome) -> TokenTestResult {
        switch outcome {
        case .success(let fh, let sd):   return .success(fiveHour: fh, sevenDay: sd)
        case .foreignAccount:            return .foreignAccount(org: nil)
        case .rateLimited:               return .failure(reason: "Rate-limited (429). This token is cooling down.")
        case .unauthorized:              return .failure(reason: "Anthropic rejected this token (401).")
        case .tokenExpired:              return .failure(reason: "This token is expired.")
        case .transport:                 return .failure(reason: "Network error. Check your connection.")
        case .http(let s):               return .failure(reason: "Server returned HTTP \(s).")
        case .responseSchemaMismatch:    return .failure(reason: "Unexpected response shape from Anthropic.")
        case .credentialsNotFound:       return .failure(reason: "That token is no longer available.")
        case .keychainAccessDenied:      return .failure(reason: "Keychain access denied.")
        case .keychainMalformed, .keychainStatus:
            return .failure(reason: "Couldn't read the credential.")
        }
    }

    private static func testFailure(_ error: OAuthClientError) -> TokenTestResult {
        switch error {
        case .rateLimited:            return .failure(reason: "Rate-limited (429). Try again shortly.")
        case .unauthorized:           return .failure(reason: "Anthropic rejected this token (401). A `claude setup-token` value is user:inference-only and won't work here — paste the user:profile access token.")
        case .transport:              return .failure(reason: "Network error.")
        case .http(let s, _):         return .failure(reason: "Server returned HTTP \(s).")
        case .responseSchemaMismatch: return .failure(reason: "Unexpected response shape.")
        case .tokenExpired:           return .failure(reason: "This token is expired.")
        default:                      return .failure(reason: "Couldn't validate this token.")
        }
    }

    // MARK: - Loop

    private func loop() async {
        if configuration.startupDelay > 0 {
            await nap(configuration.startupDelay)
            if stopping || Task.isCancelled { return }
        }

        while !stopping && !Task.isCancelled {
            ensureLanes()
            let activity = await activityProbe()
            lastActivityAt = activity

            if lanes.allSatisfy({ $0.state.account == .foreign }) || lanes.isEmpty {
                // Nothing usable — record it once and idle until rediscovery.
                if lanes.isEmpty { lastOutcome = .credentialsNotFound }
                await publishStatus()
                nextPollAt = clock.now().addingTimeInterval(configuration.scheduler.idleInterval)
                await nap(configuration.scheduler.idleInterval)
                continue
            }

            let decision = scheduler.decide(
                lanes: lanes.map(\.state),
                lastActivityAt: activity,
                now: clock.now()
            )
            switch decision {
            case .poll(let idx):
                _ = await pollLane(idx)
                await publishStatus()
            case .wait(let seconds):
                nextPollAt = clock.now().addingTimeInterval(seconds)
                await publishStatus()
                await nap(seconds)
            }
        }
    }

    /// Cancellable sleep. `notifyActivity()` / `stop()` cancel the inner
    /// task to return early; `try?` swallows the CancellationError so the
    /// loop simply re-evaluates (or exits on `stopping`).
    private func nap(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let clock = self.clock
        let task = Task { _ = try? await clock.sleep(seconds: seconds) }
        sleeper = task
        await task.value
        sleeper = nil
    }

    // MARK: - Lane discovery

    /// Ensure `lanes` reflects the currently available tokens. Rediscovers
    /// on first run, on the rediscover interval, or when no usable lane
    /// remains; always prunes expired lanes; keeps ordering primary-first.
    private func ensureLanes() {
        let now = clock.now()
        let noUsable = !lanes.contains { $0.state.account != .foreign }
        let stale = lastDiscoveryAt.map { now.timeIntervalSince($0) >= configuration.laneRediscoverInterval } ?? true
        if stale || noUsable {
            mergeCandidates(client.candidateCredentials())
            lastDiscoveryAt = now
        }
        // Drop lanes whose token has expired locally (server would 401).
        lanes.removeAll { lane in
            if let exp = lane.credential.expiresAt, exp < now { return true }
            return false
        }
        sortLanes()
    }

    /// Union new candidate tokens into the lane set, preserving the state
    /// of lanes we already hold (Desktop lanes persist between the gated
    /// keychain re-reads, so we don't lose them when discovery skips a
    /// re-read).
    private func mergeCandidates(_ candidates: [CredentialCandidate]) {
        var known = Set(lanes.map { $0.credential.accessToken })
        for candidate in candidates where !known.contains(candidate.credential.accessToken) {
            lanes.append(Lane(
                credential: candidate.credential,
                source: candidate.source,
                state: OAuthPollScheduler.LaneState(),
                consecutiveFailures: 0,
                resolvedOrg: nil
            ))
            known.insert(candidate.credential.accessToken)
        }
    }

    /// Order primary-eligible sources first so the scheduler's index
    /// tie-break polls a Claude Code / override token before a Desktop
    /// one — letting the primary account establish the org guard.
    private func sortLanes() {
        func rank(_ s: CredentialCandidate.Source) -> Int {
            switch s {
            case .override: return 0
            case .keychain: return 1
            case .held:     return 2
            case .desktop:  return 3
            }
        }
        lanes.sort { a, b in
            let ra = rank(a.source), rb = rank(b.source)
            return ra != rb ? ra < rb : a.credential.accessToken < b.credential.accessToken
        }
    }

    // MARK: - One poll

    @discardableResult
    private func pollLane(_ idx: Int) async -> PollOutcome {
        guard idx < lanes.count else { return .credentialsNotFound }
        let credential = lanes[idx].credential
        let result = await client.fetchUsage(using: credential)
        let now = clock.now()
        lastPollAt = now
        // Guard: the lane array can change across the await (rediscovery
        // never runs concurrently on the same actor, but be defensive).
        guard idx < lanes.count, lanes[idx].credential.accessToken == credential.accessToken else {
            return lastOutcome ?? .transport
        }
        lanes[idx].state.lastPolledAt = now

        let previous = lastOutcome
        let outcome = await apply(result: result, laneIndex: idx, now: now)
        lastOutcome = outcome
        if !Self.sameCategory(previous, outcome) {
            Log.write("OAuthPoller", Self.summarize(outcome: outcome, laneCount: lanes.count))
        }
        return outcome
    }

    /// Apply one poll's result to lane state + persistence, return outcome.
    private func apply(
        result: Result<RateLimitSnapshot, OAuthClientError>,
        laneIndex idx: Int,
        now: Date
    ) async -> PollOutcome {
        switch result {
        case .success(let snapshot):
            lanes[idx].consecutiveFailures = 0
            lanes[idx].state.cooldownUntil = nil
            // Same-account guard. First success sets the primary org
            // (even if the header was absent → nil); a lane whose org
            // differs is marked foreign and never persisted. A missing
            // header on a later poll is tolerated as a match rather than
            // dropping a lane over a transient omission.
            let org = snapshot.organizationId
            let matches: Bool
            if let primary = primaryOrg {
                matches = (org == nil || org == primary)
            } else {
                primaryOrg = org
                matches = true
            }
            lanes[idx].resolvedOrg = org ?? primaryOrg
            if matches {
                lanes[idx].state.account = .primary
                await persist(snapshot, laneSource: lanes[idx].source)
                return .success(
                    fiveHourPct: snapshot.fiveHour?.usedPercentage,
                    sevenDayPct: snapshot.sevenDay?.usedPercentage
                )
            } else {
                lanes[idx].state.account = .foreign
                return .foreignAccount
            }

        case .failure(.unauthorized):
            // Token rejected server-side — drop the lane outright.
            if idx < lanes.count { lanes.remove(at: idx) }
            return .unauthorized

        case .failure(.tokenExpired):
            if idx < lanes.count { lanes.remove(at: idx) }
            return .tokenExpired

        case .failure(.rateLimited(let retryAfter)):
            cooldownLane(idx, now: now, retryAfter: retryAfter)
            return .rateLimited(retryAfter: retryAfter)

        case .failure(.transport):
            cooldownLane(idx, now: now, retryAfter: nil)
            return .transport

        case .failure(.http(let status, _)):
            cooldownLane(idx, now: now, retryAfter: nil)
            return .http(status: status)

        case .failure(.responseSchemaMismatch):
            cooldownLane(idx, now: now, retryAfter: nil)
            return .responseSchemaMismatch

        // These come only from the auto-resolve path; a specific-token
        // poll can't produce them, but map them for completeness.
        case .failure(.credentialsNotFound):  return .credentialsNotFound
        case .failure(.keychainAccessDenied): return .keychainAccessDenied
        case .failure(.keychainMalformed):    return .keychainMalformed
        case .failure(.keychainStatus(let s)): return .keychainStatus(s)
        }
    }

    /// Grow a lane's cooldown exponentially per consecutive failure,
    /// honoring a larger `Retry-After` when present, capped.
    private func cooldownLane(_ idx: Int, now: Date, retryAfter: TimeInterval?) {
        guard idx < lanes.count else { return }
        lanes[idx].consecutiveFailures += 1
        let n = lanes[idx].consecutiveFailures
        let exponential = configuration.laneCooldownBase * pow(2.0, Double(n - 1))
        let chosen = min(max(retryAfter ?? 0, exponential), configuration.laneCooldownMax)
        lanes[idx].state.cooldownUntil = now.addingTimeInterval(chosen)
    }

    // MARK: - Logging helpers

    private static func sameCategory(_ a: PollOutcome?, _ b: PollOutcome?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (.some(let x), .some(let y)):
            let nameX = Mirror(reflecting: x).children.first?.label ?? "\(x)"
            let nameY = Mirror(reflecting: y).children.first?.label ?? "\(y)"
            return nameX == nameY
        }
    }

    private static func summarize(outcome: PollOutcome, laneCount: Int) -> String {
        let lanes = "lanes=\(laneCount)"
        switch outcome {
        case .success(let fh, let sd):
            let f = fh.map { String(format: "%.1f%%", $0) } ?? "nil"
            let s = sd.map { String(format: "%.1f%%", $0) } ?? "nil"
            return "ok 5h=\(f) 7d=\(s); \(lanes)"
        case .foreignAccount:
            return "token is a different account — excluded; \(lanes)"
        case .credentialsNotFound:
            return "no usable token — sign into Claude Code; \(lanes)"
        case .keychainAccessDenied:
            return "keychain access denied — approve in foreground app; \(lanes)"
        case .keychainMalformed:
            return "keychain blob malformed; \(lanes)"
        case .keychainStatus(let status):
            return "keychain OSStatus=\(status); \(lanes)"
        case .tokenExpired:
            return "access token expired — dropped lane; \(lanes)"
        case .unauthorized:
            return "unauthorized (401) — dropped lane; \(lanes)"
        case .rateLimited(let retryAfter):
            let ra = retryAfter.map { "\(Int($0))s" } ?? "nil"
            return "rate-limited (429) retryAfter=\(ra) — lane cooling; \(lanes)"
        case .http(let status):
            return "http \(status) — lane cooling; \(lanes)"
        case .transport:
            return "transport error (network) — lane cooling; \(lanes)"
        case .responseSchemaMismatch:
            return "response schema mismatch; \(lanes)"
        }
    }

    // MARK: - Activity probe

    /// Default activity signal: the most recent moment Claude Code
    /// produced usage or a session was seen — the JSONL watcher advances
    /// both as work happens, so "recent" here means "actively burning".
    private static func defaultActivityProbe(container: ModelContainer) -> @Sendable () async -> Date? {
        { @Sendable in
            await MainActor.run {
                let context = ModelContext(container)
                var tokenProbe = FetchDescriptor<TokenSample>(
                    sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
                )
                tokenProbe.fetchLimit = 1
                let lastToken = (try? context.fetch(tokenProbe))?.first?.sampledAt
                var sessionProbe = FetchDescriptor<SessionInfo>(
                    sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
                )
                sessionProbe.fetchLimit = 1
                let lastSession = (try? context.fetch(sessionProbe))?.first?.lastSeenAt
                return [lastToken, lastSession].compactMap { $0 }.max()
            }
        }
    }

    // MARK: - Non-monotonic usage diagnostics

    /// Most recent persisted OAuth sample for a window (or nil).
    @MainActor
    private static func latestSample(_ context: ModelContext, window: String) -> RateLimitSample? {
        var d = FetchDescriptor<RateLimitSample>(
            predicate: #Predicate { $0.window == window && $0.source == "oauth" },
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// Log when a window's utilization *decreases* for a reason that
    /// isn't one of the two resets we already recognize — i.e. a small
    /// within-window wobble, the kind a lagging backend replica (possibly
    /// surfaced by interleaving tokens) could produce. Purely diagnostic:
    /// one grep-able line, no behavior change. We deliberately do NOT log:
    ///   - a normal rollover — `resets_at` advanced past the prior anchor;
    ///   - an off-schedule global reset — a collapse from a meaningful
    ///     level to ~0 (handled by `GlobalRateLimitReset`).
    @MainActor
    private static func logIfUsageWentDown(
        windowName: String,
        prior: RateLimitSample?,
        newUsed: Double,
        newReset: Date?,
        laneSource: CredentialCandidate.Source
    ) {
        guard let prior else { return }
        let priorUsed = prior.usedPercentage
        guard newUsed < priorUsed - 0.01 else { return }   // not a decrease

        // Rollover: the window advanced to a later reset anchor.
        let rolloverTolerance: TimeInterval = 10 * 60
        if let pr = prior.resetsAt, let nr = newReset, nr.timeIntervalSince(pr) > rolloverTolerance {
            return
        }
        // Off-schedule global reset: collapse to ~0 on an unchanged anchor.
        if priorUsed > 5, newUsed < 1 { return }

        let anchor: String
        if let pr = prior.resetsAt, let nr = newReset {
            let drift = Int(nr.timeIntervalSince(pr).rounded())
            anchor = drift == 0 ? "resets_at unchanged" : "resets_at drift \(drift)s"
        } else {
            anchor = "resets_at nil"
        }
        Log.write("OAuthPoller", String(
            format: "usage DECREASED (non-reset): %@ %.1f%%→%.1f%% via %@ token; %@ — likely backend replica lag",
            windowName, priorUsed, newUsed, laneSource.rawValue, anchor
        ))
    }

    // MARK: - Persistence

    /// Write one row per present window. Hops to the main actor for
    /// SwiftData since `ModelContext` is `@MainActor` in our setup.
    private func persist(_ snapshot: RateLimitSnapshot, laneSource: CredentialCandidate.Source) async {
        let container = self.container
        let captured = snapshot
        await MainActor.run {
            let context = ModelContext(container)
            var wroteAnyWindow = false
            if let window = captured.fiveHour {
                Self.logIfUsageWentDown(
                    windowName: RateLimitWindowName.fiveHour,
                    prior: Self.latestSample(context, window: RateLimitWindowName.fiveHour),
                    newUsed: window.usedPercentage,
                    newReset: window.resetsAt,
                    laneSource: laneSource
                )
                context.insert(RateLimitSample(
                    sampledAt: captured.sampledAt,
                    window: RateLimitWindowName.fiveHour,
                    usedPercentage: window.usedPercentage,
                    resetsAt: window.resetsAt,
                    source: RateLimitSource.oauth
                ))
                wroteAnyWindow = true
            }
            if let window = captured.sevenDay {
                Self.logIfUsageWentDown(
                    windowName: RateLimitWindowName.sevenDay,
                    prior: Self.latestSample(context, window: RateLimitWindowName.sevenDay),
                    newUsed: window.usedPercentage,
                    newReset: window.resetsAt,
                    laneSource: laneSource
                )
                context.insert(RateLimitSample(
                    sampledAt: captured.sampledAt,
                    window: RateLimitWindowName.sevenDay,
                    usedPercentage: window.usedPercentage,
                    resetsAt: window.resetsAt,
                    source: RateLimitSource.oauth
                ))
                wroteAnyWindow = true
            }
            // Extra-usage is account-level (not per-window); write at most
            // one row per snapshot when present. nil means the field was
            // omitted — leave the prior row rather than overwrite with a
            // phantom zero.
            if let cents = captured.extraUsageCents {
                context.insert(ExtraUsageSample(
                    sampledAt: captured.sampledAt,
                    amountCents: cents,
                    source: RateLimitSource.oauth
                ))
                wroteAnyWindow = true
            }
            do {
                try context.save()
                if wroteAnyWindow {
                    postScanCycleSummary(ScanCycleSummary(rateLimitsChanged: true))
                }
            } catch {
                Log.write("OAuthPoller", "persist failed: \(error)")
            }
        }
    }
}
