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

/// Polls `/api/oauth/usage` with an **adaptive, multi-token, multi-account
/// cadence**.
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
/// ## Multiple accounts
///
/// A person can be signed into more than one Anthropic account. Each
/// distinct org (from the `anthropic-organization-id` response header)
/// becomes an `Account`, and exactly one is **active**:
///   - The active account's lanes are the **fast pool** — the scheduler
///     drives them at the interleaved cadence above, and their samples are
///     persisted into `RateLimitSample` / `ExtraUsageSample` (stamped with
///     the account id), which is what the whole app reads. So the active
///     account is what the menu bar, dashboard, and alerts reflect.
///   - Non-active accounts' lanes are the **slow sweep** — polled no more
///     often than once per idle interval each (still ≤ 1×/5min/token), and
///     their latest readings are cached on the `Account` row for the Tokens
///     switcher rather than written into the shared timeline. This is what
///     keeps two accounts from ever mixing into one history.
///
/// Switching the active account (`setActiveAccount`) swaps which account's
/// timeline the live sample tables hold (archiving the outgoing account's
/// rows and restoring the incoming account's from `AccountUsageArchive`),
/// so no read site needs to know about accounts and no timeline is
/// corrupted.
///
/// Safety rails:
///   - **Per-token invariant.** No lane polled > 1×/5min, active or not —
///     multi-account never raises any token's poll rate.
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

        /// Per-lane floor for the non-active accounts' slow sweep. Each
        /// secondary lane is polled no more often than this (and never
        /// below the per-token invariant). Wide enough to keep the switcher
        /// fresh without background chatter.
        var secondarySweepInterval: TimeInterval {
            max(scheduler.idleInterval, scheduler.perTokenMinInterval)
        }
    }

    /// Categorized outcome of one poll, surfaced for tests and debug UI.
    public enum PollOutcome: Sendable, Equatable {
        case success(fiveHourPct: Double?, sevenDayPct: Double?)
        /// Succeeded, but the token resolved to a *different* account than
        /// the active one — tracked as a secondary account, not persisted
        /// into the active timeline. (Was `.foreignAccount`, which dropped
        /// it entirely.)
        case secondaryAccount(org: String?)
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
        /// The active account's id (org key), if one has been established.
        public let activeAccountKey: String?
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

        /// The account key this lane belongs to once classified, or nil.
        var accountKey: String? {
            state.account == .unknown ? nil : Account.key(forOrg: resolvedOrg)
        }
    }

    /// Sendable carrier for a lane's persisted metadata — read from and
    /// written to SwiftData (`TokenLaneMeta`) across the MainActor hop,
    /// and cached in-memory so lane seeding/rediscovery can restore state
    /// without a fetch. Keyed by the lane fingerprint (`id`).
    private struct LaneMetaSnapshot: Sendable {
        var id: String
        var sourceRaw: String
        var organizationId: String?
        var account: OAuthPollScheduler.AccountStatus
        var expiresAt: Date?
        var lastPolledAt: Date?
        var cooldownUntil: Date?
        var consecutiveFailures: Int
    }

    private let client: OAuthClient
    private let container: ModelContainer
    private let configuration: Configuration
    private let clock: PollerClock
    private let scheduler: OAuthPollScheduler
    private let activityProbe: @Sendable () async -> Date?
    private let random: RandomSource

    private var lanes: [Lane] = []
    /// The active account's org (nil when the header was absent). Kept for
    /// the same-account classification and the snapshot/debug surface.
    private var primaryOrg: String?
    /// The active account's key (`Account.id`). nil until the first
    /// successful poll (or a restore from persisted `Account.isActive`).
    private var activeAccountKey: String?
    private var lastDiscoveryAt: Date?
    /// Most recent activity time seen by the loop, cached so status
    /// publishes can report active/idle without another probe.
    private var lastActivityAt: Date?
    private var lastOutcome: PollOutcome?
    private var lastPollAt: Date?
    private var nextPollAt: Date?

    /// Pacer's persistent token pool (its own keychain). Seeded into lanes
    /// once per launch so tokens survive a restart without reading Claude's
    /// stores; re-saved when the confirmed token set changes.
    private let poolStore: TokenPoolStoring
    private var seeded = false
    private var lastSavedPoolTokens: Set<String> = []

    /// Persisted lane metadata (account / cooldown / last-poll / org),
    /// loaded once per launch so seeded + rediscovered lanes restore their
    /// status without an immediate re-poll and the Tokens UI isn't blank
    /// on boot. Written back after every poll and pool mutation.
    private var persistedMeta: [String: LaneMetaSnapshot] = [:]
    private var metaLoaded = false

    private var loopTask: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var stopping = false

    public init(
        client: OAuthClient = OAuthClient(),
        container: ModelContainer,
        configuration: Configuration = Configuration(),
        clock: PollerClock = SystemPollerClock(),
        activityProbe: (@Sendable () async -> Date?)? = nil,
        poolStore: TokenPoolStoring = EphemeralTokenPoolStore(),
        random: @escaping RandomSource = { Double.random(in: 0..<1) }
    ) {
        self.client = client
        self.container = container
        self.configuration = configuration
        self.clock = clock
        self.scheduler = OAuthPollScheduler(tuning: configuration.scheduler)
        self.activityProbe = activityProbe ?? Self.defaultActivityProbe(container: container)
        self.poolStore = poolStore
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

    /// Test entry — discover lanes and poll the best eligible fast-pool
    /// lane once, ignoring the cadence gate (but honoring cooldown). Polls
    /// `.unknown`/`.primary` lanes (so a never-polled token is classified);
    /// `.secondary` lanes are reached via `testLane`. Does NOT loop.
    @discardableResult
    public func runOnce() async -> PollOutcome {
        await loadPersistedMetaIfNeeded()
        ensureLanes()
        let now = clock.now()
        let idx = lanes.indices
            .filter {
                lanes[$0].state.account != .secondary
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
            primaryOrg: primaryOrg,
            activeAccountKey: activeAccountKey
        )
    }

    // MARK: - Manual test + status publishing (TokenPoolTesting)

    /// Stable, non-reversible id for a token — 12 hex chars of its
    /// SHA-256. The lane's UI identity + test-routing key; never exposes
    /// token bytes.
    static func laneId(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Test an existing lane by id. Routes through the normal poll path so
    /// the reading is persisted and the lane is stamped — a manual test
    /// spends that token's budget through the same accounting as an auto
    /// poll, never a hidden extra request.
    public func testLane(id: String) async -> TokenTestResult {
        await loadPersistedMetaIfNeeded()
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
    /// once. A different-account token reports `.otherAccount` (it isn't
    /// added by this path — use `addManualToken` to keep it).
    public func testAdHoc(token: String) async -> TokenTestResult {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(reason: "Empty token.") }
        await loadPersistedMetaIfNeeded()
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
            let isActive = classifyIsActive(org: org)
            if isActive {
                let key = activeAccountKey ?? Account.key(forOrg: org)
                await recordPoll(snap, accountKey: key, organizationId: org,
                                 subscriptionType: cred.subscriptionType, isActive: true,
                                 laneSource: .override)
                return .success(fiveHour: snap.fiveHour?.usedPercentage, sevenDay: snap.sevenDay?.usedPercentage)
            }
            return .otherAccount(org: org)
        case .failure(let error):
            return Self.testFailure(error)
        }
    }

    /// Add a manually-supplied token as an `.override` lane and poll it
    /// once to classify its account. Kept and persisted whether it's your
    /// active account (`.success`) or a *different* account (`.otherAccount`
    /// — now tracked as a separate account you can switch to). A duplicate
    /// / invalid token isn't retained.
    public func addManualToken(_ token: String) async -> TokenTestResult {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(reason: "Empty token.") }
        // Offline format gate first — reject an obviously wrong paste
        // instantly, without spending a network request on it.
        if case .invalid(let reason) = TokenFormat.validate(trimmed) {
            return .failure(reason: reason)
        }
        await loadPersistedMetaIfNeeded()
        ensureLanes()
        if let existing = lanes.first(where: { $0.credential.accessToken == trimmed }) {
            return .alreadyTracked(source: existing.source, fingerprint: Self.laneId(existing.credential.accessToken))
        }
        // Unknown local expiry — the server 401s when it lapses.
        lanes.append(Lane(
            credential: OAuthCredential(accessToken: trimmed, expiresAt: nil, subscriptionType: nil),
            source: .override,
            state: OAuthPollScheduler.LaneState(),
            consecutiveFailures: 0,
            resolvedOrg: nil
        ))
        sortLanes()
        guard let idx = lanes.firstIndex(where: { $0.credential.accessToken == trimmed }) else {
            return .failure(reason: "Couldn't add the token.")
        }
        let outcome = await pollLane(idx)
        let lane = lanes.first(where: { $0.credential.accessToken == trimmed })
        switch lane?.state.account {
        case .primary:
            savePool()
            await publishStatus()
            return Self.testResult(from: outcome)   // .success
        case .secondary:
            // A different account — keep it, tracked as a separate account.
            savePool()
            await publishStatus()
            return .otherAccount(org: lane?.resolvedOrg)
        default:
            // Unclassified (401 / invalid / transport) — don't keep it.
            lanes.removeAll { $0.credential.accessToken == trimmed }
            await saveAllLaneMeta()
            await publishStatus()
            return Self.testResult(from: outcome)
        }
    }

    /// Remove a manually-added (`.override`) lane by its opaque id.
    public func removeManualToken(id: String) async {
        lanes.removeAll { $0.source == .override && Self.laneId($0.credential.accessToken) == id }
        // Force-persist the removal (bypass savePool's "don't wipe" guard) so
        // the removed token can't reappear from the pool on the next launch.
        let confirmed = lanes.filter { $0.state.account != .unknown }
        lastSavedPoolTokens = Set(confirmed.map { $0.credential.accessToken })
        poolStore.saveAll(confirmed.map { StoredToken(credential: $0.credential, source: $0.source) })
        await saveAllLaneMeta()   // prune the removed lane's metadata
        await publishStatus()
    }

    /// Make `id` the active account. Swaps the live sample timeline to that
    /// account's, reclassifies lanes, and flips `Account.isActive`. No-op if
    /// already active or the account isn't known.
    public func setActiveAccount(id: String) async {
        await loadPersistedMetaIfNeeded()
        ensureLanes()
        guard id != activeAccountKey else { return }
        let outgoing = activeAccountKey
        let newOrg = await swapActiveTimeline(from: outgoing, to: id)
        activeAccountKey = id
        primaryOrg = newOrg
        // Reclassify every confirmed lane against the new active account.
        for i in lanes.indices where lanes[i].state.account != .unknown {
            let belongsToActive = (lanes[i].resolvedOrg == nil) || (Account.key(forOrg: lanes[i].resolvedOrg) == id)
            lanes[i].state.account = belongsToActive ? .primary : .secondary
        }
        await saveAllLaneMeta()
        await publishStatus()
    }

    /// Publish a display-safe snapshot of the lane pool + accounts +
    /// effective cadence to `TokenPoolStatus.shared` for the Settings
    /// section.
    private func publishStatus() async {
        let tuning = configuration.scheduler
        // Fast-pool lanes (active account + unclassified) set the cadence.
        let fast = lanes.filter { $0.state.account == .primary || $0.state.account == .unknown }.count
        let active = lastActivityAt.map { clock.now().timeIntervalSince($0) <= tuning.activeWindow } ?? false
        let realizedActive = max(tuning.activeInterval, tuning.perTokenMinInterval / Double(max(fast, 1)))
        let effective: TimeInterval? = fast == 0 ? nil : (active ? realizedActive : tuning.idleInterval)
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
                priority: i,
                accountKey: lane.accountKey
            )
        }
        // Lane counts per account, for the switcher.
        var laneCounts: [String: Int] = [:]
        for lane in lanes where lane.state.account != .unknown {
            laneCounts[Account.key(forOrg: lane.resolvedOrg), default: 0] += 1
        }
        let accounts = await accountSummaries(laneCounts: laneCounts)
        await MainActor.run {
            TokenPoolStatus.shared.publish(
                lanes: statuses, accounts: accounts,
                isActive: active, effectiveIntervalSeconds: effective
            )
        }
    }

    /// Build the switcher's account summaries from the persisted `Account`
    /// rows (MainActor for SwiftData).
    private func accountSummaries(laneCounts: [String: Int]) async -> [AccountStatusSummary] {
        let container = self.container
        let activeKey = activeAccountKey
        return await MainActor.run {
            let context = ModelContext(container)
            let rows = (try? context.fetch(FetchDescriptor<Account>())) ?? []
            return rows
                .map { a in
                    AccountStatusSummary(
                        id: a.id,
                        organizationId: a.organizationId,
                        displayName: a.displayName,
                        isActive: a.isActive || a.id == activeKey,
                        subscriptionType: a.subscriptionType,
                        fiveHourPct: a.latestFiveHourPct,
                        sevenDayPct: a.latestSevenDayPct,
                        extraUsageCents: a.latestExtraUsageCents,
                        lastPolledAt: a.latestPolledAt,
                        laneCount: laneCounts[a.id] ?? 0
                    )
                }
                // Active first, then most-recently-polled.
                .sorted { l, r in
                    if l.isActive != r.isActive { return l.isActive }
                    return (l.lastPolledAt ?? .distantPast) > (r.lastPolledAt ?? .distantPast)
                }
        }
    }

    private static func testResult(from outcome: PollOutcome) -> TokenTestResult {
        switch outcome {
        case .success(let fh, let sd):   return .success(fiveHour: fh, sevenDay: sd)
        case .secondaryAccount(let org): return .otherAccount(org: org)
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
        // Restore persisted lane state and publish it *before* the startup
        // delay, so the Tokens UI shows last-known status/account/expiry the
        // instant the window opens instead of flashing "no tokens yet" while
        // the delay elapses. This only reads the pool + cached metadata; the
        // delay still gates the first live poll.
        await loadPersistedMetaIfNeeded()
        ensureLanes()
        await publishStatus()

        if configuration.startupDelay > 0 {
            await nap(configuration.startupDelay)
            if stopping || Task.isCancelled { return }
        }

        while !stopping && !Task.isCancelled {
            ensureLanes()
            let activity = await activityProbe()
            lastActivityAt = activity

            if lanes.isEmpty {
                // Nothing usable — record it once and idle until rediscovery.
                lastOutcome = .credentialsNotFound
                await publishStatus()
                nextPollAt = clock.now().addingTimeInterval(configuration.scheduler.idleInterval)
                await nap(configuration.scheduler.idleInterval)
                continue
            }

            let now = clock.now()
            let decision = scheduler.decide(
                lanes: lanes.map(\.state),
                lastActivityAt: activity,
                now: now
            )
            switch decision {
            case .poll(let idx):
                _ = await pollLane(idx)
                await publishStatus()
            case .wait(let fastWait):
                // A secondary (non-active) account may be due for its slow
                // sweep even while the fast pool waits. Poll one if so; each
                // secondary lane is still gated to ≤ 1×/5min.
                if let sIdx = dueSecondaryLaneIndex(now: now) {
                    _ = await pollLane(sIdx)
                    await publishStatus()
                    continue
                }
                let secWait = nextSecondaryWait(now: now)
                let wait = [fastWait, secWait].compactMap { $0 }.min() ?? fastWait
                nextPollAt = now.addingTimeInterval(wait)
                await publishStatus()
                await nap(wait)
            }
        }
    }

    /// The least-recently-polled secondary lane that's due for its slow
    /// sweep now (past its per-lane interval and not cooling), or nil.
    private func dueSecondaryLaneIndex(now: Date) -> Int? {
        let interval = configuration.secondarySweepInterval
        return lanes.indices
            .filter { i in
                lanes[i].state.account == .secondary
                    && (lanes[i].state.cooldownUntil.map { now >= $0 } ?? true)
                    && ((lanes[i].state.lastPolledAt?.addingTimeInterval(interval) ?? .distantPast) <= now)
            }
            .min { (lanes[$0].state.lastPolledAt ?? .distantPast) < (lanes[$1].state.lastPolledAt ?? .distantPast) }
    }

    /// Seconds until the earliest secondary lane becomes due, or nil if
    /// there are no secondary lanes.
    private func nextSecondaryWait(now: Date) -> TimeInterval? {
        let interval = configuration.secondarySweepInterval
        let readyTimes = lanes.filter { $0.state.account == .secondary }.map { lane -> Date in
            let byInterval = lane.state.lastPolledAt?.addingTimeInterval(interval) ?? .distantPast
            let byCooldown = lane.state.cooldownUntil ?? .distantPast
            return max(byInterval, byCooldown)
        }
        guard let earliest = readyTimes.min() else { return nil }
        return max(configuration.scheduler.minWait, earliest.timeIntervalSince(now))
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
        // Seed from Pacer's persisted pool once per launch, so every token
        // comes back on restart without touching Claude's stores.
        if !seeded {
            seeded = true
            for stored in poolStore.loadAll() {
                if let exp = stored.credential.expiresAt, exp < now { continue }
                if lanes.contains(where: { $0.credential.accessToken == stored.credential.accessToken }) { continue }
                var lane = Lane(
                    credential: stored.credential,
                    source: stored.source,
                    state: OAuthPollScheduler.LaneState(),
                    consecutiveFailures: 0,
                    resolvedOrg: nil
                )
                applyPersistedMeta(to: &lane)   // restore last-known status
                lanes.append(lane)
            }
        }
        let noUsable = lanes.isEmpty
        let stale = lastDiscoveryAt.map { now.timeIntervalSince($0) >= configuration.laneRediscoverInterval } ?? true
        if stale || noUsable {
            // Hand the client our Desktop-origin tokens so its layered read
            // can decide whether it even needs to touch Claude Desktop.
            let cachedDesktop = lanes.filter { $0.source == .desktop }.map { $0.credential }
            mergeCandidates(client.candidateCredentials(cachedDesktopTokens: cachedDesktop))
            lastDiscoveryAt = now
        }
        // Drop lanes whose token has expired locally (server would 401).
        lanes.removeAll { lane in
            if let exp = lane.credential.expiresAt, exp < now { return true }
            return false
        }
        sortLanes()
        savePool()
    }

    /// Persist the confirmed tokens (any account) to Pacer's keychain so
    /// they survive a restart. Only confirmed lanes (`.primary`/`.secondary`
    /// — never a not-yet-classified one), and only when the token set
    /// actually changed, to avoid a keychain write every poll.
    private func savePool() {
        let confirmed = lanes.filter { $0.state.account != .unknown }
        guard !confirmed.isEmpty else { return }   // don't wipe the pool pre-confirmation
        let tokenSet = Set(confirmed.map { $0.credential.accessToken })
        guard tokenSet != lastSavedPoolTokens else { return }
        lastSavedPoolTokens = tokenSet
        poolStore.saveAll(confirmed.map { StoredToken(credential: $0.credential, source: $0.source) })
    }

    /// Union new candidate tokens into the lane set, preserving the state
    /// of lanes we already hold (Desktop lanes persist between the gated
    /// keychain re-reads, so we don't lose them when discovery skips a
    /// re-read).
    private func mergeCandidates(_ candidates: [CredentialCandidate]) {
        var known = Set(lanes.map { $0.credential.accessToken })
        for candidate in candidates where !known.contains(candidate.credential.accessToken) {
            var lane = Lane(
                credential: candidate.credential,
                source: candidate.source,
                state: OAuthPollScheduler.LaneState(),
                consecutiveFailures: 0,
                resolvedOrg: nil
            )
            applyPersistedMeta(to: &lane)   // restore last-known status for a rediscovered token
            lanes.append(lane)
            known.insert(candidate.credential.accessToken)
        }
    }

    /// Order primary-eligible sources first so the scheduler's index
    /// tie-break polls a Claude Code / override token before a Desktop
    /// one — letting the active account establish the org guard.
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
        // Persist the lane's freshly-learned state (account/org/last-poll/
        // cooldown) so it survives a restart.
        await saveAllLaneMeta()
        return outcome
    }

    /// Is a poll whose org resolved to `org` part of the active account?
    /// A nil org (server omitted the header) is treated as the active
    /// account — you can't split accounts the server never names. The first
    /// ever classification establishes the active account.
    private func classifyIsActive(org: String?) -> Bool {
        if let active = activeAccountKey {
            // A header-less active account (`default` sentinel) can't be
            // split — the server never names accounts for us, so every poll
            // is treated as that one account.
            if active == Account.defaultKey { return true }
            return org == nil || Account.key(forOrg: org) == active
        }
        // First classification — this becomes the active account.
        activeAccountKey = Account.key(forOrg: org)
        primaryOrg = org
        return true
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
            let org = snapshot.organizationId
            let isActive = classifyIsActive(org: org)
            lanes[idx].resolvedOrg = org ?? primaryOrg
            let accountKey = isActive ? (activeAccountKey ?? Account.key(forOrg: org)) : Account.key(forOrg: org)
            let sub = lanes[idx].credential.subscriptionType
            if isActive {
                lanes[idx].state.account = .primary
                await recordPoll(snapshot, accountKey: accountKey, organizationId: org,
                                 subscriptionType: sub, isActive: true,
                                 laneSource: lanes[idx].source)
                return .success(
                    fiveHourPct: snapshot.fiveHour?.usedPercentage,
                    sevenDayPct: snapshot.sevenDay?.usedPercentage
                )
            } else {
                // A different account — track it (create/update its Account
                // row + cached snapshot) but keep it out of the active
                // timeline so two accounts never mix.
                lanes[idx].state.account = .secondary
                await recordPoll(snapshot, accountKey: accountKey, organizationId: org,
                                 subscriptionType: sub, isActive: false,
                                 laneSource: lanes[idx].source)
                return .secondaryAccount(org: org)
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
        case .secondaryAccount:
            return "token is another account — tracked as secondary; \(lanes)"
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

    // MARK: - Lane metadata persistence

    /// Load persisted lane metadata + the active account once per launch
    /// (MainActor for SwiftData). Restores the active account's org so the
    /// classification is intact immediately, and populates the cache that
    /// `ensureLanes`/`mergeCandidates` read to rehydrate lanes.
    private func loadPersistedMetaIfNeeded() async {
        guard !metaLoaded else { return }
        metaLoaded = true
        let container = self.container
        struct Loaded: Sendable {
            var meta: [String: LaneMetaSnapshot]
            var activeKey: String?
            var activeOrg: String?
            var metaPrimaryOrg: String?
        }
        let loaded: Loaded = await MainActor.run {
            let context = ModelContext(container)
            let rows = (try? context.fetch(FetchDescriptor<TokenLaneMeta>())) ?? []
            var map: [String: LaneMetaSnapshot] = [:]
            var metaPrimary: String?
            for r in rows {
                let account = OAuthPollScheduler.AccountStatus(rawValue: r.accountRaw)
                map[r.id] = LaneMetaSnapshot(
                    id: r.id,
                    sourceRaw: r.sourceRaw,
                    organizationId: r.organizationId,
                    account: account,
                    expiresAt: r.expiresAt,
                    lastPolledAt: r.lastPolledAt,
                    cooldownUntil: r.cooldownUntil,
                    consecutiveFailures: r.consecutiveFailures
                )
                if account == .primary, metaPrimary == nil { metaPrimary = r.organizationId }
            }
            // The active account is the source of truth for `activeAccountKey`.
            let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
            let active = accounts.first { $0.isActive }
            return Loaded(meta: map, activeKey: active?.id, activeOrg: active?.organizationId, metaPrimaryOrg: metaPrimary)
        }
        persistedMeta = loaded.meta
        if activeAccountKey == nil { activeAccountKey = loaded.activeKey }
        if primaryOrg == nil { primaryOrg = loaded.activeOrg ?? loaded.metaPrimaryOrg }
    }

    /// Restore a freshly-seeded/discovered lane's learned state from the
    /// persisted cache, so a known token doesn't show as blank/pending or
    /// get needlessly re-polled right after launch.
    private func applyPersistedMeta(to lane: inout Lane) {
        guard let meta = persistedMeta[Self.laneId(lane.credential.accessToken)] else { return }
        lane.state.account = meta.account
        lane.state.lastPolledAt = meta.lastPolledAt
        lane.state.cooldownUntil = meta.cooldownUntil
        lane.resolvedOrg = meta.organizationId
        lane.consecutiveFailures = meta.consecutiveFailures
    }

    private func laneMetaSnapshot(for lane: Lane) -> LaneMetaSnapshot {
        LaneMetaSnapshot(
            id: Self.laneId(lane.credential.accessToken),
            sourceRaw: lane.source.rawValue,
            organizationId: lane.resolvedOrg,
            account: lane.state.account,
            expiresAt: lane.credential.expiresAt,
            lastPolledAt: lane.state.lastPolledAt,
            cooldownUntil: lane.state.cooldownUntil,
            consecutiveFailures: lane.consecutiveFailures
        )
    }

    /// Persist all current lanes' metadata (upsert by fingerprint) and
    /// prune rows for tokens no longer in the pool, so the Tokens table and
    /// the scheduler restore real state on the next launch. Called after a
    /// poll and after any pool mutation.
    private func saveAllLaneMeta() async {
        let rows = lanes.map { laneMetaSnapshot(for: $0) }
        // Keep the in-memory cache in step with what we persist.
        persistedMeta = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let keep = Set(rows.map { $0.id })
        let now = clock.now()
        let container = self.container
        await MainActor.run {
            let context = ModelContext(container)
            let existing = (try? context.fetch(FetchDescriptor<TokenLaneMeta>())) ?? []
            var byId: [String: TokenLaneMeta] = [:]
            for e in existing { byId[e.id] = e }
            for row in rows {
                if let m = byId[row.id] {
                    m.sourceRaw = row.sourceRaw
                    m.organizationId = row.organizationId
                    m.accountRaw = row.account.rawValue
                    m.expiresAt = row.expiresAt
                    m.lastPolledAt = row.lastPolledAt
                    m.cooldownUntil = row.cooldownUntil
                    m.consecutiveFailures = row.consecutiveFailures
                    m.updatedAt = now
                } else {
                    context.insert(TokenLaneMeta(
                        id: row.id,
                        sourceRaw: row.sourceRaw,
                        organizationId: row.organizationId,
                        accountRaw: row.account.rawValue,
                        expiresAt: row.expiresAt,
                        lastPolledAt: row.lastPolledAt,
                        cooldownUntil: row.cooldownUntil,
                        consecutiveFailures: row.consecutiveFailures,
                        updatedAt: now
                    ))
                }
            }
            for e in existing where !keep.contains(e.id) { context.delete(e) }
            do { try context.save() }
            catch { Log.write("OAuthPoller", "lane-meta persist failed: \(error)") }
        }
    }

    // MARK: - Account persistence

    /// Record one poll: upsert the `Account` row (identity + cached latest
    /// readings for the switcher), and — only for the **active** account —
    /// write the window/extra-usage history into the shared timeline tables
    /// stamped with the account id. Hops to the main actor for SwiftData.
    private func recordPoll(
        _ snapshot: RateLimitSnapshot,
        accountKey: String,
        organizationId: String?,
        subscriptionType: String?,
        isActive: Bool,
        laneSource: CredentialCandidate.Source
    ) async {
        let container = self.container
        let captured = snapshot
        await MainActor.run {
            let context = ModelContext(container)

            // --- Upsert the account + its cached latest readings ---
            let key = accountKey
            let accounts = (try? context.fetch(
                FetchDescriptor<Account>(predicate: #Predicate { $0.id == key })
            )) ?? []
            let account: Account
            if let existing = accounts.first {
                account = existing
            } else {
                account = Account(
                    id: key,
                    organizationId: organizationId,
                    displayName: Account.defaultName(forOrg: organizationId, subscriptionType: subscriptionType),
                    isActive: isActive,
                    firstSeenAt: captured.sampledAt,
                    lastSeenAt: captured.sampledAt,
                    subscriptionType: subscriptionType
                )
                context.insert(account)
            }
            account.lastSeenAt = captured.sampledAt
            if account.organizationId == nil, let organizationId { account.organizationId = organizationId }
            if let subscriptionType { account.subscriptionType = subscriptionType }
            if isActive { account.isActive = true }
            if let w = captured.fiveHour {
                account.latestFiveHourPct = w.usedPercentage
                account.latestFiveHourResetsAt = w.resetsAt
            }
            if let w = captured.sevenDay {
                account.latestSevenDayPct = w.usedPercentage
                account.latestSevenDayResetsAt = w.resetsAt
            }
            if let cents = captured.extraUsageCents { account.latestExtraUsageCents = cents }
            account.latestPolledAt = captured.sampledAt

            // --- History rows: active account only ---
            var wroteAnyWindow = false
            if isActive {
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
                        source: RateLimitSource.oauth,
                        accountId: key
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
                        source: RateLimitSource.oauth,
                        accountId: key
                    ))
                    wroteAnyWindow = true
                }
                // Extra-usage is account-level (not per-window); write at
                // most one row per snapshot when present. nil means the
                // field was omitted — leave the prior row rather than
                // overwrite with a phantom zero.
                if let cents = captured.extraUsageCents {
                    context.insert(ExtraUsageSample(
                        sampledAt: captured.sampledAt,
                        amountCents: cents,
                        source: RateLimitSource.oauth,
                        accountId: key
                    ))
                    wroteAnyWindow = true
                }
                // The scoped `limits[]` representation (per-model weekly
                // windows, severity, binding flag). One generic row per item,
                // all stamped with the same `sampledAt` so the dashboard reads
                // them back as one "latest batch" — a limit dropped from the
                // response simply stops appearing. Keyed by a stable composite
                // identity, so new models/kinds persist with no schema change.
                // Gated to the active account, and stamped with `accountId` so
                // the active-account timeline swap can archive/restore these
                // rows alongside `RateLimitSample` — a secondary (non-active)
                // account's limits never pollute the live timeline, and two
                // accounts that share a model identity (e.g. both have a "Fable"
                // weekly) keep separate scoped history.
                for limit in captured.limits {
                    context.insert(UsageLimitSample(
                        from: limit,
                        sampledAt: captured.sampledAt,
                        source: RateLimitSource.oauth,
                        accountId: key
                    ))
                    wroteAnyWindow = true
                }
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

    /// Swap which account's timeline the live sample tables hold: archive
    /// the outgoing active account's rows into `AccountUsageArchive`, then
    /// restore the incoming account's archived rows into the live tables,
    /// and flip `Account.isActive`. Returns the incoming account's org so
    /// the caller can update `primaryOrg`. Runs on the main actor.
    private func swapActiveTimeline(from outgoing: String?, to incoming: String) async -> String? {
        let container = self.container
        return await MainActor.run {
            let context = ModelContext(container)

            // 1. Archive the outgoing active account's live rows.
            if let outgoing {
                let rls = (try? context.fetch(FetchDescriptor<RateLimitSample>())) ?? []
                for r in rls {
                    context.insert(AccountUsageArchive(
                        accountId: outgoing,
                        kind: AccountUsageArchive.kindRateLimit,
                        sampledAt: r.sampledAt,
                        window: r.window,
                        usedPercentage: r.usedPercentage,
                        resetsAt: r.resetsAt,
                        source: r.source
                    ))
                    context.delete(r)
                }
                let extras = (try? context.fetch(FetchDescriptor<ExtraUsageSample>())) ?? []
                for e in extras {
                    context.insert(AccountUsageArchive(
                        accountId: outgoing,
                        kind: AccountUsageArchive.kindExtraUsage,
                        sampledAt: e.sampledAt,
                        amountCents: e.amountCents,
                        source: e.source
                    ))
                    context.delete(e)
                }
                let limits = (try? context.fetch(FetchDescriptor<UsageLimitSample>())) ?? []
                for l in limits {
                    context.insert(AccountUsageArchive(
                        accountId: outgoing,
                        kind: AccountUsageArchive.kindUsageLimit,
                        sampledAt: l.sampledAt,
                        usedPercentage: l.percent,
                        resetsAt: l.resetsAt,
                        source: l.source,
                        identity: l.identity,
                        limitKind: l.kind,
                        group: l.group,
                        label: l.label,
                        severity: l.severity,
                        isActive: l.isActive,
                        modelId: l.modelId,
                        modelDisplayName: l.modelDisplayName,
                        surface: l.surface
                    ))
                    context.delete(l)
                }
            }

            // 2. Restore the incoming account's archived rows (if any).
            let archived = (try? context.fetch(FetchDescriptor<AccountUsageArchive>(
                predicate: #Predicate { $0.accountId == incoming }
            ))) ?? []
            for a in archived {
                switch a.kind {
                case AccountUsageArchive.kindRateLimit:
                    context.insert(RateLimitSample(
                        sampledAt: a.sampledAt,
                        window: a.window ?? RateLimitWindowName.fiveHour,
                        usedPercentage: a.usedPercentage ?? 0,
                        resetsAt: a.resetsAt,
                        source: a.source,
                        accountId: incoming
                    ))
                case AccountUsageArchive.kindUsageLimit:
                    context.insert(UsageLimitSample(
                        sampledAt: a.sampledAt,
                        identity: a.identity ?? "",
                        kind: a.limitKind ?? "",
                        group: a.group ?? "",
                        label: a.label ?? "",
                        percent: a.usedPercentage ?? 0,
                        resetsAt: a.resetsAt,
                        severity: a.severity ?? "",
                        isActive: a.isActive ?? false,
                        modelId: a.modelId,
                        modelDisplayName: a.modelDisplayName,
                        surface: a.surface,
                        source: a.source,
                        accountId: incoming
                    ))
                default:   // kindExtraUsage
                    context.insert(ExtraUsageSample(
                        sampledAt: a.sampledAt,
                        amountCents: a.amountCents ?? 0,
                        source: a.source,
                        accountId: incoming
                    ))
                }
                context.delete(a)
            }

            // 3. Flip active flags.
            let allAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
            var incomingOrg: String?
            for acc in allAccounts {
                acc.isActive = (acc.id == incoming)
                if acc.id == incoming { incomingOrg = acc.organizationId }
            }

            do {
                try context.save()
                // Nudge every @Query consumer to refresh against the swapped
                // timeline (they auto-refresh on save, but this also drives
                // the coordination summary the rest of the app listens on).
                postScanCycleSummary(ScanCycleSummary(rateLimitsChanged: true))
            } catch {
                Log.write("OAuthPoller", "account timeline swap failed: \(error)")
            }
            return incomingOrg
        }
    }
}
