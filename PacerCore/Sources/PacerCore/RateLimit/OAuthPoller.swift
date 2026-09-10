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

        /// Per-lane floor for a non-active account's lanes.
        ///
        /// **The per-token invariant and nothing more.** This used to add
        /// `idleInterval` on top, putting the other account on a ten-minute
        /// sweep while the signed-in one was read every minute — and the
        /// account you have just switched *away* from is usually the one that
        /// matters, because you switched away from it for a reason.
        ///
        /// What that cost, measured on a real switch: `~/.claude.json` flipped
        /// to the other account for six minutes and flipped back. That is not a
        /// bug — Pacer read it correctly, five seconds behind `cswap`'s own log
        /// — but it demoted the account actually doing the work to the slow
        /// tier while it climbed from 87% to 98%, so the dashboard sat on a
        /// stale 87% through exactly the stretch where the number mattered.
        ///
        /// Five minutes is the floor, not a choice: `perTokenMinInterval` is
        /// the usage endpoint's own budget per token, and it is shared with
        /// whatever else is asking — `cswap` is already taking 429s on it. An
        /// account with one token cannot be fresher than that; one with several
        /// is read more often by rotating through them.
        var secondarySweepInterval: TimeInterval {
            scheduler.perTokenMinInterval
        }
    }

    /// Last switcher-cache timestamp ingested per account, so an unchanged
    /// file costs one comparison rather than a store query each cycle.
    private var lastSwitcherIngestAt: [String: Date] = [:]
    private let switcherCache: @Sendable () -> [SwitcherUsageCache.Reading]

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
        /// Lanes whose `.primary`/`.secondary` classification disagrees with
        /// whether their token actually belongs to the active account.
        ///
        /// Should always be zero. It is not a derived nicety: the two facts are
        /// persisted separately — `activeAccountKey` from `Account.isActive`,
        /// the classification from `TokenLaneMeta` — so a restart can restore a
        /// pair that disagrees, and the symptom is silent (the signed-in
        /// account's token drops to the slow secondary sweep and its readings
        /// are filed as some other account's).
        public let misclassifiedLaneCount: Int
    }

    public typealias RandomSource = @Sendable () -> Double

    /// One pollable token + its scheduling state.
    private struct Lane {
        /// `var` because a lane outlives the credential it was built from: the
        /// token stays the same while the *description* of it gains fields
        /// across Pacer versions, and a lane that could never take the newer
        /// copy carried the older one for the life of the token.
        var credential: OAuthCredential
        let source: CredentialCandidate.Source
        var state: OAuthPollScheduler.LaneState
        var consecutiveFailures: Int
        /// The account this token resolved to (from a successful poll's
        /// `anthropic-organization-id`); nil until first polled.
        var resolvedOrg: String?

        /// The highest window utilisation this lane last saw, and the soonest
        /// reset it reported. Recorded for diagnostics — an earlier version
        /// used them to sweep a near-the-cap account faster than an idle one,
        /// which was the wrong shape: every account now gets the per-token
        /// floor, so there is no slow tier left to escape from.
        var lastTopPercent: Double?
        var lastSoonestReset: Date?

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
    /// Which lane the last logged poll used, so a change of token is worth a
    /// line even when the outcome category has not moved.
    private var lastPolledLaneId: String?
    private var lastPollAt: Date?
    private var nextPollAt: Date?

    /// Pacer's persistent token pool (its own keychain). Seeded into lanes
    /// once per launch so tokens survive a restart without reading Claude's
    /// stores; re-saved when the confirmed token set changes.
    private let poolStore: TokenPoolStoring
    private var seeded = false
    /// What the pool on disk currently represents — token *and* stored shape,
    /// so a description refresh is a change worth writing.
    private var lastSavedPoolTokens: Set<String> = []

    private static func poolSignature(_ credentials: [OAuthCredential]) -> Set<String> {
        Set(credentials.map { "\($0.accessToken)|\($0.storedVersion ?? 0)" })
    }

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
        /// Injected so tests do not read the developer's real switcher cache —
        /// the same seam every other machine-touching source here has.
        switcherCache: @escaping @Sendable () -> [SwitcherUsageCache.Reading]
            = { SwitcherUsageCache.readings(at: SwitcherUsageCache.defaultURL()) },
        random: @escaping RandomSource = { Double.random(in: 0..<1) }
    ) {
        self.client = client
        self.container = container
        self.configuration = configuration
        self.clock = clock
        self.switcherCache = switcherCache
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
        // Off the loop task on purpose: the fold is a pass over tens of
        // thousands of rows on first run and polling must not wait on it. In
        // steady state it is a handful of index probes.
        let container = self.container
        Task.detached {
            await Self.reconcileScopeMirror(container: container)
            await Self.foldArchiveIntoLiveTables(container: container)
        }
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
            activeAccountKey: activeAccountKey,
            misclassifiedLaneCount: lanes.filter { lane in
                guard lane.state.account != .unknown, let active = activeAccountKey else { return false }
                let belongs = (lane.resolvedOrg == nil) || (Account.key(forOrg: lane.resolvedOrg) == active)
                return belongs != (lane.state.account == .primary)
            }.count
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
                                 subscriptionType: cred.subscriptionType,
                                 rateLimitTier: cred.rateLimitTier, isActive: true,
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
        lastSavedPoolTokens = Self.poolSignature(confirmed.map(\.credential))
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

        // Reclassify even when the id already matches, rather than returning
        // early. Lane classification is restored from persisted meta and can
        // disagree with the restored `activeAccountKey` — a lane saved
        // `.secondary` under a previous active account stays `.secondary`
        // forever if the only thing that repairs it is a *change* of account.
        // That is a silent, self-perpetuating wrong answer, and the repair is
        // three comparisons.
        let unchanged = (id == activeAccountKey)
        if !unchanged {
            let newOrg = await activateAccount(id)
            activeAccountKey = id
            primaryOrg = newOrg
        }
        var reclassified = 0
        for i in lanes.indices where lanes[i].state.account != .unknown {
            let belongsToActive = (lanes[i].resolvedOrg == nil) || (Account.key(forOrg: lanes[i].resolvedOrg) == id)
            let want: OAuthPollScheduler.AccountStatus = belongsToActive ? .primary : .secondary
            if lanes[i].state.account != want { reclassified += 1 }
            lanes[i].state.account = want
        }
        if unchanged {
            guard reclassified > 0 else { return }
            Log.write("OAuthPoller",
                      "repaired \(reclassified) lane(s) whose account no longer matched the active one")
        }
        await saveAllLaneMeta()
        await publishStatus()
    }

    /// Rename an account. Identity is the org id, so this touches nothing but
    /// the label — `setActiveAccount`'s timeline swap has no counterpart here.
    ///
    /// Clearing the name restores the derived placeholder rather than leaving
    /// an empty string, because `Account.label` treats a blank name as absent
    /// and would fall through to the raw uuid.
    public func renameAccount(id: String, to name: String) async {
        let container = self.container
        // On the main actor because that is where `recordPoll` upserts these
        // rows. Two contexts writing one `Account` from different actors is a
        // race worth not having for a field nobody writes twice.
        await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })
            guard let account = (try? context.fetch(descriptor))?.first else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            account.displayName = trimmed.isEmpty
                ? Account.defaultName(forOrg: account.organizationId,
                                      subscriptionType: account.subscriptionType)
                : trimmed
            try? context.save()
        }
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
        // Only ever an id the *store* knows. `activeAccountKey` is the poller's
        // in-memory guess and is `Account.defaultKey` until a response carries
        // an org header — publishing that wrote "default" into App Group
        // defaults, and every read scoped to it matched nothing at all. Not an
        // empty chart you would notice as a bug: just gauges that stopped
        // having a value.
        let activeId = accounts.first(where: \.isActive)?.id
        await MainActor.run {
            UsageScope.shared.setActiveAccount(activeId)
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
                        // `label`, not `displayName`: two accounts on the
                        // same plan derive the identical placeholder, and a
                        // switcher is exactly the setup that produces two.
                        displayName: a.label,
                        isActive: a.isActive || a.id == activeKey,
                        subscriptionType: a.subscriptionType,
                        rateLimitTier: a.rateLimitTier,
                        fiveHourPct: a.latestFiveHourPct,
                        sevenDayPct: a.latestSevenDayPct,
                        extraUsageCents: a.latestExtraUsageCents,
                        lastPolledAt: a.latestPolledAt,
                        laneCount: laneCounts[a.id] ?? 0,
                        switcherSlot: a.switcherSlot
                    )
                }
                // The switcher's slot order when there is one — someone who
                // types `cswap switch 2` should find account 2 second here.
                // Otherwise active first, then most-recently-polled.
                .sorted { l, r in
                    switch (l.switcherSlot, r.switcherSlot) {
                    case let (a?, b?) where a != b: return a < b
                    case (nil, _?): return false
                    case (_?, nil): return true
                    default: break
                    }
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
            await ingestSwitcherCache()
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

    /// Record anything the account switcher has fetched that Pacer has not.
    ///
    /// Free — it is a file read, not a request — and it is the only way to see
    /// an account whose token Pacer cannot use: one it has never been signed
    /// into on this machine, or one whose credential is being 429'd because
    /// two clients are polling it. Measured at the time of writing: the
    /// signed-in account's reading was 26 minutes old in Pacer and 30 seconds
    /// old in the switcher's cache.
    ///
    /// Strictly additive. A reading is dropped unless it is newer than what
    /// Pacer already holds for that account, so a stale cache can never walk a
    /// live series backwards, and an absent file is simply nothing.
    private func ingestSwitcherCache() async {
        let readings = switcherCache()
        forgetSwitcherSchedule(
            exceptAccounts: Set(readings.map { Account.key(forOrg: $0.organizationId) }))
        guard !readings.isEmpty else { return }
        for reading in readings {
            let key = Account.key(forOrg: reading.organizationId)

            // The *schedule* is applied unconditionally, before any freshness
            // test on the data.
            //
            // This was the other way round and it deadlocked: the guard that
            // keeps Pacer clear of cswap's requests was only installed when a
            // cswap reading was ingested, and a reading only appears when cswap
            // *succeeds* — so while cswap was being 429'd, nothing told Pacer
            // to leave it room, and Pacer's polling is what kept it 429'd.
            // Measured in that state: Pacer took zero 429s over ten minutes and
            // cswap took them steadily. Pacer winning is not the goal; cswap
            // needs this data to switch accounts on a limit.
            //
            // When cswap will poll is a fact whether or not its last attempt
            // worked. Only recording a sample needs the data to be new.
            noteSwitcherActivity(account: key, with: reading)

            if let seen = lastSwitcherIngestAt[key], seen >= reading.fetchedAt { continue }
            guard await isNewerThanStored(reading.fetchedAt, account: key) else {
                lastSwitcherIngestAt[key] = reading.fetchedAt
                continue
            }
            lastSwitcherIngestAt[key] = reading.fetchedAt

            let snapshot = RateLimitSnapshot(
                sampledAt: reading.fetchedAt,
                fiveHour: reading.fiveHour.map {
                    RateLimitWindow(usedPercentage: $0.percent, resetsAt: $0.resetsAt)
                },
                sevenDay: reading.sevenDay.map {
                    RateLimitWindow(usedPercentage: $0.percent, resetsAt: $0.resetsAt)
                },
                extraUsageCents: nil,
                organizationId: reading.organizationId,
                limits: reading.scoped.map { row in
                    UsageLimit(
                        kind: "weekly_scoped", group: "weekly", percent: row.percent,
                        severity: UsageLimitSeverity("normal"), resetsAt: row.resetsAt,
                        scope: UsageLimitScope(
                            model: UsageLimitScope.Model(id: nil, displayName: row.name),
                            surface: nil),
                        isActive: false)
                })
            // No credential here, and therefore no plan: this is a *usage
            // reading* lifted from the switcher's cache, which carries
            // percentages and nothing about the account behind them. Pacer
            // reads it precisely so it does not poll another client's token
            // and rate-limit them both.
            //
            // So an account Pacer only ever sees through this path keeps
            // whatever plan it was last polled with, and none at all if it
            // never was. `recordPoll` never overwrites a known plan with nil,
            // so the detail arrives — and stays — the first time that account
            // is the live login.
            await recordPoll(snapshot, accountKey: key,
                             organizationId: reading.organizationId,
                             subscriptionType: nil,
                             isActive: activeAccountKey == key,
                             laneSource: .parked,
                             source: RateLimitSource.cswap)
        }
    }

    /// Tell the scheduler what cswap has spent on this account's tokens, and
    /// when it will spend again.
    ///
    /// **Facts, not a schedule.** An earlier version computed a target time
    /// itself — poll at the midpoint of cswap's gap — which worked and was the
    /// wrong shape: it overrode a scheduler that already scales cadence with
    /// token count (`perTokenMinInterval / usableLanes`, so five tokens is one
    /// minute) and already backs a lane off on 429. Replacing that with a fixed
    /// rule threw both away.
    ///
    /// So this only supplies the input that was missing. Backwards: cswap's
    /// fetch counted as a poll of that token, because it spent the same budget.
    /// Forwards: when cswap says it will poll next, so the scheduler can avoid
    /// crowding it. What cadence falls out is then the scheduler's decision,
    /// and it adapts — a wide cswap interval leaves room for Pacer at its own
    /// floor, a narrow one does not.
    private func noteSwitcherActivity(
        account key: String, with reading: SwitcherUsageCache.Reading
    ) {
        let hold = Self.switcherHold(for: reading)
        for i in lanes.indices
        where lanes[i].accountKey == key && Self.sharesBudgetWithSwitcher(lanes[i].source) {
            // Backwards: when cswap last spent this token's budget. Kept apart
            // from `lastPolledAt`, which stays Pacer's own poll — the scheduler
            // needs both, and folding them together is what let a stuck cswap
            // hide how long Pacer had gone without a reading.
            lanes[i].state.externalLastPollAt = hold.spentAt
            // Forwards: where cswap says it is going next.
            lanes[i].state.externalNextPollAt = hold.nextPollAt
        }
    }

    /// What one cswap reading says about a shared token: when its budget was
    /// last spent, and when the other client intends to spend it next.
    ///
    /// Split out from the lane walk because it is the whole policy, and the
    /// lanes are just where it gets written.
    struct SwitcherHold: Equatable {
        let spentAt: Date
        let nextPollAt: Date?
    }

    /// A request spends the budget whether or not it returns anything, so the
    /// mark is the later of "asked" and "answered" — see
    /// `SwitcherUsageCache.Reading.lastAttemptAt`.
    ///
    /// Counting failures deliberately has no escape hatch here. It looked like
    /// it needed one — a client stuck retrying would hold the lane down
    /// forever — but the answer to that is not to pretend its requests are not
    /// happening. They are, and polling into them is what keeps a throttled
    /// token throttled. The bound belongs on Pacer's own staleness instead, and
    /// lives in the scheduler as `externalYieldMax`.
    static func switcherHold(for reading: SwitcherUsageCache.Reading) -> SwitcherHold {
        SwitcherHold(
            spentAt: max(reading.fetchedAt, reading.lastAttemptAt ?? .distantPast),
            nextPollAt: reading.nextPollAt)
    }

    /// Forget a schedule for lanes no reading covers.
    ///
    /// Without this, a `nextPollAt` from cswap's last write outlives cswap
    /// itself: uninstall it, or have it drop an account, and the lane keeps
    /// deferring to a client that is not running.
    private func forgetSwitcherSchedule(exceptAccounts covered: Set<String>) {
        for i in lanes.indices
        where (lanes[i].state.externalNextPollAt != nil
               || lanes[i].state.externalLastPollAt != nil)
            && !covered.contains(lanes[i].accountKey ?? "") {
            lanes[i].state.externalNextPollAt = nil
            lanes[i].state.externalLastPollAt = nil
        }
    }

    /// Whether a lane holds the same credential cswap polls.
    ///
    /// The budget is per token, so only the tokens cswap actually uses are
    /// affected — and cswap swaps Claude Code's credential, nothing else. A
    /// Claude Desktop token for the same account is a *different* credential
    /// with its own budget and is untouched by anything cswap does.
    ///
    /// Getting this wrong is not theoretical: the first version marked every
    /// lane of the account, which stamped all five of the work account's
    /// Desktop lanes with one timestamp. That collapsed their stagger — they
    /// had been polled about fifty seconds apart, and afterwards all became due
    /// together — so an account with five tokens refreshed at the same rate as
    /// one with a single token. Exactly the multi-token spreading this was
    /// supposed to preserve.
    private static func sharesBudgetWithSwitcher(_ source: CredentialCandidate.Source) -> Bool {
        switch source {
        case .keychain, .parked: return true
        case .desktop, .held, .override: return false
        }
    }

    /// Newest stored sample for an account, so an older cached reading is not
    /// replayed over a fresher poll.
    private func isNewerThanStored(_ at: Date, account: String) async -> Bool {
        let container = self.container
        return await MainActor.run {
            let context = ModelContext(container)
            var d = FetchDescriptor<RateLimitSample>(
                predicate: LimitScope.rateLimitPredicate(account: account),
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
            d.fetchLimit = 1
            guard let newest = (try? context.fetch(d))?.first else { return true }
            return at > newest.sampledAt
        }
    }

    /// The least-recently-polled secondary lane that's due for its sweep now
    /// (past its per-lane interval and not cooling), or nil.
    ///
    /// **Per lane, deliberately — that is the multi-token design working.**
    /// The budget Anthropic enforces is per *token*, so an account holding five
    /// credentials really can be read five times as often without costing any
    /// other account anything. Spreading load across an account's tokens to
    /// shorten its refresh interval is the point of the token pool.
    ///
    /// This was briefly changed to budget per account, on the theory that five
    /// Desktop lanes were starving the signed-in account's single lane. That
    /// theory was wrong: the 429s only ever landed on the signed-in account's
    /// own token, never on the five that were being polled twelve times as
    /// often, which is exactly what a per-token budget looks like. The real
    /// contention was Pacer and `cswap` polling the *same* token — fixed by
    /// reading cswap's cache instead. Throttling by account fixed nothing and
    /// gave up a real feature, so it is reverted.
    ///
    /// Eligibility itself is `OAuthPollScheduler.readyAt`, the same rule the
    /// fast pool uses, differing only in the interval. This method had its own
    /// partial copy of it — cooldown and Pacer's own spacing, plus half of the
    /// external check — so a secondary lane could keep its distance from
    /// Pacer's polls while landing squarely on another client's.
    private func dueSecondaryLaneIndex(now: Date) -> Int? {
        let interval = configuration.secondarySweepInterval
        return lanes.indices
            .filter {
                lanes[$0].state.account == .secondary
                    && scheduler.readyAt(lanes[$0].state, interval: interval, now: now) <= now
            }
            .min { (lanes[$0].state.lastPolledAt ?? .distantPast) < (lanes[$1].state.lastPolledAt ?? .distantPast) }
    }

    /// Seconds until the earliest secondary lane becomes due, or nil if
    /// there are no secondary lanes.
    private func nextSecondaryWait(now: Date) -> TimeInterval? {
        let interval = configuration.secondarySweepInterval
        let readyTimes = lanes.filter { $0.state.account == .secondary }.map {
            scheduler.readyAt($0.state, interval: interval, now: now)
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
        // Signature, not token set: refreshing a credential's description
        // leaves the tokens identical, and comparing only those would keep the
        // older shape on disk forever — which is how the pool came to be the
        // thing hiding a field the keychain had all along.
        let signature = Self.poolSignature(confirmed.map(\.credential))
        guard signature != lastSavedPoolTokens else { return }
        lastSavedPoolTokens = signature
        poolStore.saveAll(confirmed.map { StoredToken(credential: $0.credential, source: $0.source) })
    }

    /// Union new candidate tokens into the lane set, preserving the state
    /// of lanes we already hold (Desktop lanes persist between the gated
    /// keychain re-reads, so we don't lose them when discovery skips a
    /// re-read).
    ///
    /// **A known token still gets its description refreshed.** This used to
    /// skip any candidate whose token it already had, which is right for lane
    /// *state* and wrong for the credential itself: lanes are seeded from
    /// Pacer's persisted pool at launch, so a credential serialised by an older
    /// build stayed in place even as live sources returned a richer copy of the
    /// same token. `rateLimitTier` was invisible for exactly this reason — the
    /// keychain had it, `KeychainOAuth` parsed it, and the lane it should have
    /// reached was already occupied by a pooled credential that predated the
    /// field.
    ///
    /// Only a strictly newer stored shape replaces one, so this converges after
    /// a single discovery rather than rewriting a lane every cycle, and lane
    /// state is carried across untouched.
    private func mergeCandidates(_ candidates: [CredentialCandidate]) {
        var known = Set(lanes.map { $0.credential.accessToken })
        for candidate in candidates {
            guard !known.contains(candidate.credential.accessToken) else {
                guard candidate.credential.isCurrentStoredShape,
                      let idx = lanes.firstIndex(where: {
                          $0.credential.accessToken == candidate.credential.accessToken
                      }),
                      !lanes[idx].credential.isCurrentStoredShape
                else { continue }
                lanes[idx].credential = candidate.credential
                continue
            }
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
            // Below the live sources, above Desktop: a parked credential
            // speaks for a real Claude Code login, just not the current one,
            // so it should establish its account before a Desktop token gets
            // the chance to claim the same org.
            case .parked:   return 3
            case .desktop:  return 4
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
        let previousLane = lastPolledLaneId
        let outcome = await apply(result: result, laneIndex: idx, now: now)
        lastOutcome = outcome
        lastPolledLaneId = idx < lanes.count
            ? Self.laneId(lanes[idx].credential.accessToken) : nil
        // Log a change of lane as well as a change of outcome. Deduping on the
        // outcome alone hid which token was being spent, which is the one thing
        // that matters when two clients share one: a run of identical `ok`
        // lines could be one lane every minute or six lanes in rotation, and
        // there was no way to tell them apart from outside.
        if !Self.sameCategory(previous, outcome) || previousLane != lastPolledLaneId {
            Log.write("OAuthPoller", Self.summarize(
                outcome: outcome, laneCount: lanes.count,
                lane: idx < lanes.count ? lanes[idx] : nil))
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
            lanes[idx].lastTopPercent = [snapshot.fiveHour?.usedPercentage,
                                         snapshot.sevenDay?.usedPercentage]
                .compactMap { $0 }.max()
            lanes[idx].lastSoonestReset = [snapshot.fiveHour?.resetsAt,
                                           snapshot.sevenDay?.resetsAt]
                .compactMap { $0 }.min()
            let org = snapshot.organizationId
            // The live Claude Code credential outranks the config file.
            //
            // `ActiveAccountObserver` reads `oauthAccount` out of
            // `~/.claude.json`, which is right whenever one Claude Code owns
            // that file. Run several at once — all sharing `~/.claude`, which
            // is the default — and a session that started under another account
            // rewrites the object with *its* identity, undoing a switcher's
            // work without the switcher knowing. Observed on the maintainer's
            // machine: cswap logged three switches to the personal account and
            // Pacer saw two reversions to the work account at times cswap
            // logged nothing at all, because the credential said one thing and
            // the config file said another.
            //
            // This lane holds the credential Claude Code actually bills, and
            // the response just named its org. That is not a guess, and it
            // costs nothing extra. It wins.
            //
            // No thrash: the observer only votes when the *file* changes, so
            // adopting the credential here settles it until the next real
            // switch.
            if lanes[idx].source == .keychain, let org,
               let key = Optional(Account.key(forOrg: org)), key != activeAccountKey,
               activeAccountKey != nil, activeAccountKey != Account.defaultKey {
                Log.write("OAuthPoller",
                          "signed-in credential resolves to \(key.prefix(4)) but the config "
                            + "said \(activeAccountKey?.prefix(4) ?? "-") — trusting the credential")
                await setActiveAccount(id: key)
            }
            let isActive = classifyIsActive(org: org)
            lanes[idx].resolvedOrg = org ?? primaryOrg
            let accountKey = isActive ? (activeAccountKey ?? Account.key(forOrg: org)) : Account.key(forOrg: org)
            let sub = lanes[idx].credential.subscriptionType
            let tier = lanes[idx].credential.rateLimitTier
            if isActive {
                lanes[idx].state.account = .primary
                await recordPoll(snapshot, accountKey: accountKey, organizationId: org,
                                 subscriptionType: sub, rateLimitTier: tier, isActive: true,
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
                                 subscriptionType: sub, rateLimitTier: tier, isActive: false,
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

    private static func summarize(
        outcome: PollOutcome, laneCount: Int, lane: Lane? = nil
    ) -> String {
        // Which credential, and whose. Enough to tell a Desktop token from the
        // Claude Code one an account switcher is also holding, without ever
        // putting the token itself in a log file.
        let which = lane.map { l in
            let org = l.accountKey.map { String($0.prefix(4)) } ?? "?"
            return "\(l.source.rawValue)/\(org) "
        } ?? ""
        let lanes = "\(which)lanes=\(laneCount)"
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

    /// Most recent persisted OAuth sample for one account's window (or nil).
    ///
    /// Scoped by account because the live table holds every account's rows.
    /// Unscoped, "the previous reading" would routinely be a *different*
    /// account's, and the non-monotonic diagnostic would fire on every poll
    /// that happened to interleave two logins.
    @MainActor
    private static func latestSample(_ context: ModelContext, window: String,
                                     accountId: String) -> RateLimitSample? {
        var d = FetchDescriptor<RateLimitSample>(
            predicate: #Predicate {
                $0.window == window && $0.source == "oauth" && $0.accountId == accountId
            },
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
        rateLimitTier: String? = nil,
        isActive: Bool,
        laneSource: CredentialCandidate.Source,
        /// Which mechanism produced this observation. Defaults to a live poll;
        /// the switcher-cache path passes its own so the rows say where they
        /// came from and the dashboard's source chip stays honest.
        source: String = RateLimitSource.oauth
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
                    subscriptionType: subscriptionType,
                    rateLimitTier: rateLimitTier
                )
                context.insert(account)
            }
            account.lastSeenAt = captured.sampledAt
            if account.organizationId == nil, let organizationId { account.organizationId = organizationId }
            if let subscriptionType { account.subscriptionType = subscriptionType }
            if let rateLimitTier { account.rateLimitTier = rateLimitTier }
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

            // --- History rows: every account, stamped ---
            //
            // This used to be `if isActive { live } else { archive }`, and the
            // swap in `setActiveAccount` moved rows between the two so the
            // live tables always held exactly one account. That kept every
            // read site free of accounts at the price of the other account's
            // pace chart not existing: 45,973 archived rows on this machine,
            // current to the minute, that nothing could draw.
            //
            // Now every account writes here and reads filter by `accountId`.
            // The archive keeps its second job — cold storage past
            // `liveWindowDays` — and `evictStaleLiveRows` still fills it.
            var wroteActiveWindow = false
            if let window = captured.fiveHour {
                Self.logIfUsageWentDown(
                    windowName: RateLimitWindowName.fiveHour,
                    prior: Self.latestSample(context, window: RateLimitWindowName.fiveHour, accountId: key),
                    newUsed: window.usedPercentage,
                    newReset: window.resetsAt,
                    laneSource: laneSource
                )
                context.insert(RateLimitSample(
                    sampledAt: captured.sampledAt,
                    window: RateLimitWindowName.fiveHour,
                    usedPercentage: window.usedPercentage,
                    resetsAt: window.resetsAt,
                    source: source,
                    accountId: key
                ))
                wroteActiveWindow = wroteActiveWindow || isActive
            }
            if let window = captured.sevenDay {
                Self.logIfUsageWentDown(
                    windowName: RateLimitWindowName.sevenDay,
                    prior: Self.latestSample(context, window: RateLimitWindowName.sevenDay, accountId: key),
                    newUsed: window.usedPercentage,
                    newReset: window.resetsAt,
                    laneSource: laneSource
                )
                context.insert(RateLimitSample(
                    sampledAt: captured.sampledAt,
                    window: RateLimitWindowName.sevenDay,
                    usedPercentage: window.usedPercentage,
                    resetsAt: window.resetsAt,
                    source: source,
                    accountId: key
                ))
                wroteActiveWindow = wroteActiveWindow || isActive
            }
            // Extra-usage is account-level (not per-window); write at
            // most one row per snapshot when present. nil means the
            // field was omitted — leave the prior row rather than
            // overwrite with a phantom zero.
            if let cents = captured.extraUsageCents {
                context.insert(ExtraUsageSample(
                    sampledAt: captured.sampledAt,
                    amountCents: cents,
                    source: source,
                    accountId: key
                ))
                wroteActiveWindow = wroteActiveWindow || isActive
            }
            // The scoped `limits[]` representation (per-model weekly
            // windows, severity, binding flag). One generic row per item,
            // all stamped with the same `sampledAt` so the dashboard reads
            // them back as one "latest batch" — a limit dropped from the
            // response simply stops appearing. Keyed by a stable composite
            // identity, so new models/kinds persist with no schema change.
            // Two accounts that share a model identity (e.g. both have a
            // "Fable" weekly) keep separate scoped history via `accountId`.
            for limit in captured.limits {
                context.insert(UsageLimitSample(
                    from: limit,
                    sampledAt: captured.sampledAt,
                    source: source,
                    accountId: key
                ))
                wroteActiveWindow = wroteActiveWindow || isActive
            }
            if Self.evictionIsDue(now: captured.sampledAt) {
                let moved = Self.evictStaleLiveRows(context: context, accountId: key)
                if moved > 0 {
                    Log.write("OAuthPoller",
                              "evicted \(moved) live row(s) older than \(Int(Self.liveWindowDays))d to the archive")
                }
            }
            do {
                try context.save()
                if wroteActiveWindow {
                    postScanCycleSummary(ScanCycleSummary(rateLimitsChanged: true))
                }
            } catch {
                Log.write("OAuthPoller", "persist failed: \(error)")
            }
        }
    }

    /// Whether any live row predates `accountId`. One indexed count per table,
    /// so the steady-state cost of re-running the fold every launch is three
    /// index probes.
    @ScanActor
    private static func hasUnstampedLiveRows(_ context: ModelContext) -> Bool {
        let rl = (try? context.fetchCount(FetchDescriptor<RateLimitSample>(
            predicate: #Predicate { $0.accountId == nil }))) ?? 0
        if rl > 0 { return true }
        let ul = (try? context.fetchCount(FetchDescriptor<UsageLimitSample>(
            predicate: #Predicate { $0.accountId == nil }))) ?? 0
        if ul > 0 { return true }
        let eu = (try? context.fetchCount(FetchDescriptor<ExtraUsageSample>(
            predicate: #Predicate { $0.accountId == nil }))) ?? 0
        return eu > 0
    }

    /// Test seam for the eviction pass — it is the one piece of the swap
    /// whose correctness is "nothing was lost", which is worth asserting
    /// directly rather than through a full poll cycle.
    @MainActor
    static func testEvictStaleLiveRows(context: ModelContext, accountId: String) -> Int {
        evictStaleLiveRows(context: context, accountId: accountId)
    }

    /// When eviction last ran. In-memory only: re-running once after a
    /// restart costs one bounded pass and saves persisting a timestamp
    /// nothing else needs.
    nonisolated(unsafe) private static var lastEvictionAt: Date?

    private static func evictionIsDue(now: Date) -> Bool {
        guard let last = lastEvictionAt else {
            lastEvictionAt = now
            return true
        }
        guard now.timeIntervalSince(last) >= 3600 else { return false }
        lastEvictionAt = now
        return true
    }

    /// Move the active account's live rows older than the window into the
    /// archive, so the live tables stay a bounded cache.
    ///
    /// Without this the bound only applies on a switch, and a single-account
    /// user — who never switches — accumulates live rows forever. That is
    /// exactly how this machine reached 90,200 live rate-limit rows: nothing
    /// was ever wrong, they simply never left.
    ///
    /// Eviction, not deletion. Every row is written to the archive before it
    /// is removed, and the archive is never pruned.
    @MainActor
    private static func evictStaleLiveRows(context: ModelContext, accountId: String) -> Int {
        let cutoff = Date().addingTimeInterval(-liveWindowDays * 86_400)
        var moved = 0

        let rls = (try? context.fetch(FetchDescriptor<RateLimitSample>(
            predicate: #Predicate { $0.sampledAt < cutoff }))) ?? []
        for r in rls {
            context.insert(AccountUsageArchive(
                accountId: r.accountId ?? accountId,
                kind: AccountUsageArchive.kindRateLimit,
                sampledAt: r.sampledAt, window: r.window,
                usedPercentage: r.usedPercentage, resetsAt: r.resetsAt,
                source: r.source))
            context.delete(r)
            moved += 1
        }

        let extras = (try? context.fetch(FetchDescriptor<ExtraUsageSample>(
            predicate: #Predicate { $0.sampledAt < cutoff }))) ?? []
        for e in extras {
            context.insert(AccountUsageArchive(
                accountId: e.accountId ?? accountId,
                kind: AccountUsageArchive.kindExtraUsage,
                sampledAt: e.sampledAt, amountCents: e.amountCents,
                source: e.source))
            context.delete(e)
            moved += 1
        }

        let limits = (try? context.fetch(FetchDescriptor<UsageLimitSample>(
            predicate: #Predicate { $0.sampledAt < cutoff }))) ?? []
        for l in limits {
            context.insert(AccountUsageArchive(
                accountId: l.accountId ?? accountId,
                kind: AccountUsageArchive.kindUsageLimit,
                sampledAt: l.sampledAt, usedPercentage: l.percent,
                resetsAt: l.resetsAt, source: l.source,
                identity: l.identity, limitKind: l.kind, group: l.group,
                label: l.label, severity: l.severity, isActive: l.isActive,
                modelId: l.modelId, modelDisplayName: l.modelDisplayName,
                surface: l.surface))
            context.delete(l)
            moved += 1
        }
        return moved
    }

    /// How much history the live sample tables hold.
    ///
    /// The live tables are a *cache of the active account's recent window*,
    /// not the record — `AccountUsageArchive` is the record and keeps
    /// everything, so bounding this evicts nothing. The widest reader is the
    /// forecast engine's 32-day backtest (`fetchRate`/`fetchScopedLimits`);
    /// every view reads 8 days. 35 days clears both with margin.
    ///
    /// Why it has to be bounded at all: the swap moves every row it touches
    /// through a single `MainActor` block, and this machine had accumulated
    /// **177,689** archived rows in five months — all of which would have
    /// been restored into the live tables on the next switch back, on the
    /// main thread, to satisfy readers that wanted the newest few thousand.
    /// Unbounded, the freeze grows for as long as the app is installed.
    static let liveWindowDays: Double = 35

    /// Make `incoming` the active account. Returns its org so the caller can
    /// update `primaryOrg`.
    ///
    /// This used to *move rows*: archive the outgoing account's live samples,
    /// restore the incoming account's from the archive. That kept the live
    /// tables holding exactly one account, which is why no read site had to
    /// know about accounts — and why the other account's pace chart did not
    /// exist. Measured at real row counts the swap was **107,705 rows and
    /// 14.3 seconds**, several times a day for anyone auto-switching.
    ///
    /// Every sample now carries `accountId` and reads filter on it, so
    /// switching is a flag flip. The rows never move.
    private func activateAccount(_ incoming: String) async -> String? {
        let container = self.container
        return await MainActor.run {
            let accounts = (try? ModelContext(container).fetch(FetchDescriptor<Account>())) ?? []
            var incomingOrg: String?
            for account in accounts {
                account.isActive = (account.id == incoming)
                if account.id == incoming { incomingOrg = account.organizationId }
            }
            return incomingOrg
        }
    }

    /// Point App Group defaults at the account the *store* says is active.
    ///
    /// The store's `isActive` flag is the truth; defaults are a mirror of it so
    /// the widget process — which cannot see the app's standard defaults — can
    /// resolve the same scope. A mirror that has drifted scopes every read to
    /// an account with no rows, which is not an empty chart anyone files as a
    /// bug: the gauges just quietly stop having a value.
    ///
    /// It drifted the first time this shipped. `publishStatus` was writing the
    /// poller's in-memory `activeAccountKey`, which is `Account.defaultKey`
    /// until a response carries an org header — so defaults held `"default"`
    /// while the store held a uuid. Both ends now publish only ids the store
    /// knows, and this runs at every launch to repair whatever is there.
    @ScanActor
    static func reconcileScopeMirror(container: ModelContainer) async {
        let context = ModelContext(container)
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        guard let active = accounts.first(where: \.isActive)?.id ?? accounts.first?.id
        else { return }
        // Unconditional: see `republishActiveAccount`. A reconcile that skips
        // the write when this process already agrees cannot repair a mirror
        // that is missing or wrong for everyone else.
        await MainActor.run { UsageScope.shared.republishActiveAccount(active) }
    }

    /// Bring every account's recent history back out of the archive.
    ///
    /// Before per-account reads, a non-active account's samples lived only in
    /// `AccountUsageArchive` — on this machine 45,973 rate-limit rows spanning
    /// four months, current to the minute, that nothing could draw. Now that
    /// the live tables are account-aware, that history belongs in them.
    ///
    /// Bounded to `liveWindowDays`, matching what a switch used to restore and
    /// what `evictStaleLiveRows` maintains. Older rows stay archived: they are
    /// the permanent record, nothing reads them from the live tables, and
    /// moving them would be a long pass that buys nothing.
    ///
    /// Runs on `@ScanActor`, batched and yielding, for the same reason the
    /// swap did — it is tens of thousands of rows and the scan loop shares the
    /// actor.
    ///
    /// **Runs every launch, not once.** It was written with a meta-key guard,
    /// and the first real run moved 111,250 rows in 20.8 s but left 1,250
    /// behind — the newest four hours, which a `sampledAt >= cutoff` fetch
    /// should plainly have included. A one-shot pass turns whatever caused
    /// that into a permanent hole in the chart; a pass that repeats fixes it
    /// on the next launch and keeps costing nothing, because steady state is
    /// one indexed predicate returning zero rows. `evictStaleLiveRows` moves
    /// rows the other way only once they are *older* than the same window, so
    /// the two can never trade the same row back and forth.
    ///
    /// The meta key is still written — it records when the first fold ran.
    @ScanActor
    static func foldArchiveIntoLiveTables(container: ModelContainer, now: Date = Date()) async {
        let context = ModelContext(container)
        let started = Date()

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let storeActiveId = accounts.first(where: \.isActive)?.id ?? accounts.first?.id
        let cutoff = now.addingTimeInterval(-liveWindowDays * 86_400)
        let archived = (try? context.fetch(FetchDescriptor<AccountUsageArchive>(
            predicate: #Predicate { $0.sampledAt >= cutoff }))) ?? []

        var pending = 0
        func flush(force: Bool = false) async {
            guard force || pending >= 2_000 else { return }
            pending = 0
            do { try context.save() } catch {
                Log.write("OAuthPoller", "archive fold batch failed: \(error)")
            }
            await Task.yield()
        }

        guard !archived.isEmpty || hasUnstampedLiveRows(context) else { return }

        for row in archived {
            switch row.kind {
            case AccountUsageArchive.kindRateLimit:
                context.insert(RateLimitSample(
                    sampledAt: row.sampledAt,
                    window: row.window ?? RateLimitWindowName.fiveHour,
                    usedPercentage: row.usedPercentage ?? 0,
                    resetsAt: row.resetsAt,
                    source: row.source,
                    accountId: row.accountId))
            case AccountUsageArchive.kindUsageLimit:
                context.insert(UsageLimitSample(
                    sampledAt: row.sampledAt,
                    identity: row.identity ?? "",
                    kind: row.limitKind ?? "",
                    group: row.group ?? "",
                    label: row.label ?? "",
                    percent: row.usedPercentage ?? 0,
                    resetsAt: row.resetsAt,
                    severity: row.severity ?? "",
                    isActive: row.isActive ?? false,
                    modelId: row.modelId,
                    modelDisplayName: row.modelDisplayName,
                    surface: row.surface,
                    source: row.source,
                    accountId: row.accountId))
            default:   // kindExtraUsage
                context.insert(ExtraUsageSample(
                    sampledAt: row.sampledAt,
                    amountCents: row.amountCents ?? 0,
                    source: row.source,
                    accountId: row.accountId))
            }
            context.delete(row)
            pending += 1
            await flush()
        }

        // Adopt any unstamped live rows.
        //
        // They predate `accountId` entirely, which means they predate Pacer
        // knowing about more than one account — so they are the active
        // account's by definition. Stamping them here is what lets every read
        // site be a plain `accountId == x` instead of carrying a "…or nil, but
        // only when x is the active one" clause fifty times over.
        if let activeId = storeActiveId {
            var adopted = 0
            for row in (try? context.fetch(FetchDescriptor<RateLimitSample>(
                predicate: #Predicate { $0.accountId == nil }))) ?? [] {
                row.accountId = activeId
                adopted += 1
                pending += 1
                await flush()
            }
            for row in (try? context.fetch(FetchDescriptor<UsageLimitSample>(
                predicate: #Predicate { $0.accountId == nil }))) ?? [] {
                row.accountId = activeId
                adopted += 1
                pending += 1
                await flush()
            }
            for row in (try? context.fetch(FetchDescriptor<ExtraUsageSample>(
                predicate: #Predicate { $0.accountId == nil }))) ?? [] {
                row.accountId = activeId
                adopted += 1
                pending += 1
                await flush()
            }
            if adopted > 0 {
                Log.write("OAuthPoller", "adopted \(adopted) unstamped live row(s) as \(activeId)")
            }
        }

        let metaKey = ClaudeCodeMetaKey.archiveFoldedIntoLive
        let recorded = (try? context.fetch(FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate { $0.key == metaKey })))?.first
        if recorded == nil {
            context.insert(ClaudeCodeMeta(
                key: metaKey, value: ISO8601DateFormatter().string(from: now)))
        }
        await flush(force: true)

        // Say so when the pass did not fully drain, rather than leaving a
        // silent gap. The next launch will pick up whatever is named here.
        let leftover = (try? context.fetchCount(FetchDescriptor<AccountUsageArchive>(
            predicate: #Predicate { $0.sampledAt >= cutoff }))) ?? 0
        Log.write("OAuthPoller",
                  "folded \(archived.count) archived row(s) back into the live tables in "
                    + "\(Int(Date().timeIntervalSince(started) * 1000))ms"
                    + (leftover > 0 ? " — \(leftover) recent row(s) still archived" : ""))

        Task { @MainActor in
            postScanCycleSummary(ScanCycleSummary(rateLimitsChanged: true))
        }
    }
}
