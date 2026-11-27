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
        /// Floor between discoveries triggered by the fast pool (the active
        /// account's lanes) being empty. Without it a keychain that still
        /// holds the expired token would be re-read on every loop pass.
        public var emptyPoolRediscoverInterval: TimeInterval

        public init(
            scheduler: OAuthPollScheduler.Tuning = .init(),
            startupDelay: TimeInterval = 0,
            laneCooldownBase: TimeInterval = 300,
            laneCooldownMax: TimeInterval = 3600,
            laneRediscoverInterval: TimeInterval = 1800,
            emptyPoolRediscoverInterval: TimeInterval = 60
        ) {
            self.scheduler = scheduler
            self.startupDelay = startupDelay
            self.laneCooldownBase = laneCooldownBase
            self.laneCooldownMax = laneCooldownMax
            self.laneRediscoverInterval = laneRediscoverInterval
            self.emptyPoolRediscoverInterval = emptyPoolRediscoverInterval
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
    private let switcherCache: @Sendable () -> SwitcherUsageCache.Contents
    /// Accounts already provisioned from cswap's roster, so an unchanged
    /// roster costs a set comparison rather than a store fetch per ingest.
    private var provisionedSwitcherAccounts: Set<String> = []

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
        /// The same token was refused with HTTP 403 `forbidden403ParkAfter` polls
        /// in a row: parked in place (the lane stays, cooling for 6 h), not
        /// dropped, so the pool and the signed-in credential are untouched (#434).
        case forbiddenParked
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
        /// Lanes the scheduler will poll ahead of its cadence gate (#214).
        public let probeFirstLaneCount: Int
        /// Whether this launch has read a token from Claude Code's keychain
        /// item, which is when the `[OAuthPoller] ok keychain` line is written
        /// (#325).
        public let keychainTokenRead: Bool
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
        /// Polls in a row that got HTTP 403; every other outcome resets it (#434).
        /// Manual tests (the Settings "Test" button) are not counted. A park
        /// keeps it, so the first poll after the 6 h that is refused again
        /// parks again rather than starting a new streak of three (#482).
        var consecutive403 = 0
        /// Parked after repeated 403s: `state.cooldownUntil` is the retry time.
        /// Cleared by the next poll's outcome, so the pill never outlives it.
        var refused403 = false
        /// When this lane last took a good reading, and when its current 403
        /// streak began: a lane vouches for the network only if it succeeded
        /// after the streak started (#434).
        var lastSuccessAt: Date?
        var streak403Start: Date?
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
    /// written to SwiftData (`TokenLaneMeta`) by `readLaneMeta` and
    /// `writeLaneMeta` (OAuthPoller+Store.swift), and cached in-memory so lane
    /// seeding/rediscovery can restore state without a fetch. Keyed by the
    /// lane fingerprint (`id`).
    struct LaneMetaSnapshot: Sendable, Equatable {
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
    /// Nil for the store's own answer (`latestActivity`), read synchronously
    /// on the poller's queue. A nonisolated async closure would run those two
    /// fetches on the cooperative pool instead.
    private let activityProbe: (@Sendable () async -> Date?)?
    private let random: RandomSource

    /// The poller's executor: a serial dispatch queue of its own (#445), the
    /// shape `ArenaRuntime`'s actors use.
    ///
    /// Its work blocks. A poll is a couple of saves and a handful of fetches,
    /// the keychain reads of discovery, cswap's cache read off disk, and the
    /// hourly eviction over three tables, all synchronous by design: each
    /// store write is one section from its first fetch to its save, which is
    /// what keeps the writes in order and the switcher ingest atomic
    /// (OAuthPoller+Store.swift). As a default actor that ran on a thread of
    /// the cooperative pool, which has one per core for every task in the app.
    /// Under memory pressure one fetch can take seconds, and for that long the
    /// pool was a thread short. On this queue the same sections hold a
    /// dispatch thread of their own instead. The actor is still serial, so
    /// the order and the atomicity are unchanged.
    ///
    /// Utility, the class the loop already ran at (it is started from the
    /// scan loop, at `ScanCoordinator.loopPriority`), so in steady state
    /// nothing runs sooner or later than before. Not background
    /// (`BackgroundQoS`): that tier is for work nothing waits on. It is
    /// throttled for CPU and I/O, and a saturated Mac can give it no CPU at
    /// all (#431). A poll that does not run is a stale meter and an alert that
    /// cannot fire, and a slow page-in is exactly when I/O throttling would
    /// cost the most. Not higher either: nothing here is UI work. The queue's
    /// class is a floor, not a cap: a higher-priority caller (the Settings
    /// Test button, from main) has its job run at its own priority. The class
    /// is the same in a test process, so tests run the poller the way the
    /// app does.
    private let queue = DispatchSerialQueue(label: OAuthPoller.queueLabel, qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    /// The queue's label: what a stack or a hang report names the thread by.
    nonisolated static let queueLabel = "com.ericandrechek.pacer.oauth-poller"

    private var lanes: [Lane] = []
    /// The active account's org (nil when the header was absent). Kept for
    /// the same-account classification and the snapshot/debug surface.
    private var primaryOrg: String?
    /// The active account's key (`Account.id`). nil until the first
    /// successful poll (or a restore from persisted `Account.isActive`).
    private var activeAccountKey: String?
    private var lastDiscoveryAt: Date?
    /// When discovery last ran because the fast pool was empty; throttles
    /// that trigger (`Configuration.emptyPoolRediscoverInterval`).
    private var lastEmptyPoolDiscoveryAt: Date?
    /// Where the signed-in credential's account is published for the
    /// attribution trail. nil in tests that do not exercise attribution.
    private let signedInCredential: SignedInCredentialMonitor?
    /// The token the Claude Code keychain held at the last discovery, and
    /// when that read happened. Tracked separately from `Lane.source`
    /// because a lane keeps its `.keychain` label after the keychain has
    /// moved on to another account's token; only this says what is live.
    private var liveKeychainToken: String?
    private var liveKeychainReadAt: Date?
    /// Most recent activity time seen by the loop, cached so status
    /// publishes can report active/idle without another probe.
    private var lastActivityAt: Date?
    private var lastOutcome: PollOutcome?
    /// Which lane the last logged poll used, so a change of token is worth a
    /// line even when the outcome category has not moved.
    private var lastPolledLaneId: String?
    /// Set by the first discovery this launch that reads a token from Claude
    /// Code's keychain item, which also writes the `ok keychain` line (#325).
    private var keychainTokenRead = false
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

    /// Each account's plan as last applied, and its newest plan events, so a
    /// poll decides whether its plan is news without a fetch (#413). Loaded
    /// from the store the first time an account reports a plan, here on the
    /// poller, then kept. The poller is the only writer of an account's plan
    /// fields and of `AccountPlanEvent`, so what it remembers is what the
    /// store holds; a save that fails forgets the account, and its next poll
    /// reads it again.
    private var planStates: [String: AccountPlanState] = [:]

    private var loopTask: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var stopping = false
    /// Whether `publishStatus` writes the process-wide `UsageScope` mirror.
    /// Always in the app. Off by default in a test process: `UsageScope.shared`
    /// and its App Group mirror are one value for the whole process, and a
    /// poller in any parallel suite writing it would clobber the suites that
    /// assert on it (#260). The tests that assert the mirror call
    /// `UsageScope` / `reconcileScopeMirror` directly.
    private var publishesScope = !PacerPreferences.isTestProcess

    func stopPublishingScopeForTesting() { publishesScope = false }

    public init(
        client: OAuthClient = OAuthClient(),
        container: ModelContainer,
        configuration: Configuration = Configuration(),
        clock: PollerClock = SystemPollerClock(),
        activityProbe: (@Sendable () async -> Date?)? = nil,
        poolStore: TokenPoolStoring = EphemeralTokenPoolStore(),
        /// Injected so tests do not read the developer's real switcher cache —
        /// the same seam every other machine-touching source here has. The
        /// default reads nothing in a test process, for a test that forgets.
        switcherCache: @escaping @Sendable () -> SwitcherUsageCache.Contents
            = { PacerPreferences.isTestProcess
                    ? .empty : SwitcherUsageCache.read(at: SwitcherUsageCache.defaultURL()) },
        random: @escaping RandomSource = { Double.random(in: 0..<1) },
        signedInCredential: SignedInCredentialMonitor? = nil
    ) {
        self.signedInCredential = signedInCredential
        self.client = client
        self.container = container
        self.configuration = configuration
        self.clock = clock
        self.switcherCache = switcherCache
        self.scheduler = OAuthPollScheduler(tuning: configuration.scheduler)
        self.activityProbe = activityProbe
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
        let publishesScope = self.publishesScope
        Task.detached {
            // Same gate as every other scope write: it repairs the shared
            // mirror, so a test-process poller must not run it (#260).
            if publishesScope { await Self.reconcileScopeMirror(container: container) }
            await Self.foldArchiveIntoLiveTables(container: container)
        }
        loopTask = Task { [weak self] in
            await self?.loop()
        }
    }

    /// Test seam: whether the loop is running.
    var isLoopRunningForTesting: Bool { loopTask != nil }

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
        loadPersistedMetaIfNeeded()
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
            }.count,
            probeFirstLaneCount: lanes.filter { $0.state.probeFirst }.count,
            keychainTokenRead: keychainTokenRead
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
        loadPersistedMetaIfNeeded()
        ensureLanes()
        guard let idx = lanes.firstIndex(where: { Self.laneId($0.credential.accessToken) == id }) else {
            return .failure(reason: "That token is no longer available.")
        }
        let outcome = await pollLane(idx, manual: true)
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
        loadPersistedMetaIfNeeded()
        ensureLanes()
        if let idx = lanes.firstIndex(where: { $0.credential.accessToken == trimmed }) {
            let outcome = await pollLane(idx, manual: true)
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
                // Not a lane of the pool, but the same fingerprint it would
                // have as one, so the reading names the token that took it.
                recordPoll(snap, accountKey: key, organizationId: org,
                           subscriptionType: cred.subscriptionType,
                           rateLimitTier: cred.rateLimitTier, isActive: true,
                           laneSource: .override, laneId: Self.laneId(trimmed))
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
        loadPersistedMetaIfNeeded()
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
        let outcome = await pollLane(idx, manual: true)
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
            saveAllLaneMeta()
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
        saveAllLaneMeta()   // prune the removed lane's metadata
        await publishStatus()
    }

    /// Re-read the Claude Code keychain now rather than on the rediscover
    /// interval, and publish what it holds.
    ///
    /// Called by the scan loop when `~/.claude.json` names an account the last
    /// keychain read disagrees with: the only way to know whether that is a
    /// real switch or a stale config write is to look at the credential
    /// again. Cheap (a silent keychain read) and throttled by the caller.
    public func refreshSignedInCredential() async {
        // Persisted lane metadata first: it is what says whose a known token
        // is. Without it a launch-time re-read would publish the signed-in
        // token as unresolved, and an unresolved token cannot veto anything.
        loadPersistedMetaIfNeeded()
        lastDiscoveryAt = nil
        let before = lanes.count
        ensureLanes()
        wakeIfNewLane(countBefore: before)
    }

    /// Read every token source now. Called when a credential setting changes
    /// (Settings → Authentication), so turning a source on or off does not
    /// wait for the next scheduled discovery.
    public func rediscoverTokens() async {
        loadPersistedMetaIfNeeded()
        lastDiscoveryAt = nil
        let before = lanes.count
        ensureLanes()
        wakeIfNewLane(countBefore: before)
        await publishStatus()
    }

    /// Cancel the loop's nap when discovery added a lane or marked one
    /// `probeFirst`, so the loop re-decides now instead of when the nap ends
    /// (#214). Never polls here: polling stays in the loop, because actor
    /// reentrancy could otherwise interleave two polls.
    private func wakeIfNewLane(countBefore: Int) {
        if lanes.count > countBefore || lanes.contains(where: { $0.state.probeFirst }) {
            notifyActivity()
        }
    }

    /// Publish the account of the token the keychain holds, if a keychain
    /// read has happened. A token not yet resolved publishes as unknown,
    /// which is what makes a real switch visible before its first poll.
    private func publishSignedInCredential(resolvedKey: String? = nil) {
        guard let signedInCredential, let token = liveKeychainToken,
              let readAt = liveKeychainReadAt else { return }
        let lane = lanes.first { $0.credential.accessToken == token }
        let key: String? = resolvedKey ?? lane.flatMap { lane in
            guard lane.state.account != .unknown, let org = lane.resolvedOrg else { return nil }
            return Account.key(forOrg: org)
        }
        signedInCredential.publish(accountKey: key, readAt: readAt)
    }

    /// Make `id` the active account. Swaps the live sample timeline to that
    /// account's, reclassifies lanes, and flips `Account.isActive`.
    ///
    /// `seed` is what the caller knows about an account Pacer may never have
    /// polled — the login the trail just accepted. With it, a missing row is
    /// created first, so activation always finds something to activate and
    /// the account is on every surface before its first reading (#241).
    /// Without it (the Settings switcher, which lists only known rows) an
    /// unknown id activates nothing, as before.
    public func setActiveAccount(id: String) async {
        await setActiveAccount(id: id, seed: nil, seenAt: nil)
    }

    /// `seenAt` is when the change that led here was first seen, for the log.
    public func setActiveAccount(id: String, seed: Account.Seed?, seenAt: Date?) async {
        loadPersistedMetaIfNeeded()
        ensureLanes()

        // Reclassify even when the id already matches, rather than returning
        // early. Lane classification is restored from persisted meta and can
        // disagree with the restored `activeAccountKey` — a lane saved
        // `.secondary` under a previous active account stays `.secondary`
        // forever if the only thing that repairs it is a *change* of account.
        // That is a silent, self-perpetuating wrong answer, and the repair is
        // three comparisons.
        let unchanged = (id == activeAccountKey)
        // The store can disagree with `activeAccountKey` even when the id
        // matches: a login seen before it had a row left every row inactive.
        // `activateAccount` is idempotent and cheap (a handful of rows), so it
        // runs whenever there is a seed to provision from, not only on a change.
        var storeChanged = false
        if unchanged, seed != nil {
            let activation = activateAccount(id, seed: seed)
            storeChanged = activation.changed
            if storeChanged {
                Log.write("OAuthPoller", "account \(id.prefix(4)) active\(Self.sinceNote(seenAt))")
                if activation.exists { announceActivation(id) }
            }
        }
        if !unchanged {
            let activation = activateAccount(id, seed: seed)
            let newOrg = activation.organizationId
            activeAccountKey = id
            primaryOrg = newOrg
            storeChanged = true
            Log.write("OAuthPoller",
                      "account \(id.prefix(4)) active\(activation.created ? " (new — no reading yet)" : "")"
                        + Self.sinceNote(seenAt))
            // Before the lane rediscovery below, which can run a keychain
            // subprocess: the news that the login moved waits for nothing.
            if activation.exists { announceActivation(id) }

            // The login moved, so Claude Code has just written a *different*
            // token to the keychain — the one thing that makes the lane set
            // certainly out of date. Reclassifying the lanes we already hold
            // is not enough: the account being switched to may have no lane at
            // all, because its token was rotated in while Pacer was standing
            // 30 minutes off its rediscover interval.
            //
            // Observed: after a switch, every poll for eight minutes belonged
            // to the account the user had just left, while the one they moved
            // to had no lane to poll. Its readings came only from the
            // switcher's cache, and anything Pacer learns from a credential —
            // the plan tier, most visibly — could not arrive at all.
            //
            // A keychain read is silent and this happens once per switch, so
            // the cost is one subprocess at exactly the moment the answer is
            // known to have changed.
            lastDiscoveryAt = nil
            ensureLanes()
        }
        var reclassified = 0
        for i in lanes.indices where lanes[i].state.account != .unknown {
            let belongsToActive = (lanes[i].resolvedOrg == nil) || (Account.key(forOrg: lanes[i].resolvedOrg) == id)
            let want: OAuthPollScheduler.AccountStatus = belongsToActive ? .primary : .secondary
            if lanes[i].state.account != want { reclassified += 1 }
            lanes[i].state.account = want
        }
        if unchanged {
            guard reclassified > 0 || storeChanged else { return }
            if reclassified > 0 {
                Log.write("OAuthPoller",
                          "repaired \(reclassified) lane(s) whose account no longer matched the active one")
            }
        }
        saveAllLaneMeta()
        await publishStatus()
    }

    /// Tell off-main readers the store's active row is now `id`, from here
    /// rather than through `UsageScope` (#254). That path is three main-actor
    /// hops (the summaries fetch, the scope write, the observer's wake), and a
    /// switch is exactly when the main actor is busiest: every surface redraws
    /// for the new account. Only for a row that exists, the same rule
    /// `publishStatus` keeps: an id the store does not know is not a login
    /// anyone can be told about.
    private func announceActivation(_ id: String) {
        if publishesScope { UsageScope.mirrorActiveAccount(id) }
        PacerAccountChange(activeAccountId: id, since: Date()).post(from: self)
    }

    /// " (+412 ms since seen)", for lining a switch up across the log (#192).
    private static func sinceNote(_ seenAt: Date?) -> String {
        guard let seenAt else { return "" }
        return " (+\(Int(Date().timeIntervalSince(seenAt) * 1000)) ms since seen)"
    }

    /// Rename an account. Identity is the org id, so this touches nothing but
    /// the label — `setActiveAccount`'s timeline swap has no counterpart here.
    ///
    /// Clearing the name restores the derived placeholder rather than leaving
    /// an empty string, because `Account.label` treats a blank name as absent
    /// and would fall through to the raw uuid.
    public func renameAccount(id: String, to name: String) async {
        // Here on the poller, the actor that upserts these rows on every poll
        // (#429), so a rename and a poll never write one row from two actors
        // at once.
        if Self.writeAccountName(id: id, to: name, container: container) {
            AccountWriteSignal.post(from: self)
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
                accountKey: lane.accountKey,
                refusedReason: lane.refused403 ? Self.refusedReason(until: lane.state.cooldownUntil) : nil
            )
        }
        // Lane counts per account, for the switcher.
        var laneCounts: [String: Int] = [:]
        for lane in lanes where lane.state.account != .unknown {
            laneCounts[Account.key(forOrg: lane.resolvedOrg), default: 0] += 1
        }
        // Read here, on the poller, not inside the main-actor block below
        // (#417): this runs on every poll, and a fetch on main is the PACER-19
        // shape. Only the finished value crosses to main.
        let accounts = Self.accountSummaries(container: container, laneCounts: laneCounts,
                                             activeKey: activeAccountKey)
        // Only ever an id the *store* knows. `activeAccountKey` is the poller's
        // in-memory guess and is `Account.defaultKey` until a response carries
        // an org header — publishing that wrote "default" into App Group
        // defaults, and every read scoped to it matched nothing at all. Not an
        // empty chart you would notice as a bug: just gauges that stopped
        // having a value.
        let activeId = accounts.first(where: \.isActive)?.id
        let publishesScope = self.publishesScope
        await MainActor.run {
            if publishesScope { UsageScope.shared.setActiveAccount(activeId) }
            TokenPoolStatus.shared.publish(
                lanes: statuses, accounts: accounts,
                isActive: active, effectiveIntervalSeconds: effective
            )
        }
    }

    /// Build the switcher's account summaries from the persisted `Account`
    /// rows, on a context of its own.
    ///
    /// Not on the main actor (#417). `publishStatus` runs on every poll, and
    /// this fetched every `Account` inside `MainActor.run` each time: small
    /// while there are a few accounts, but under memory pressure a fetch can
    /// page the store back in, and on main that is a stall (PACER-19, #413).
    /// A fresh context reads what is saved, which is all the main-actor
    /// version saw too: it also made a context of its own. Pure reads, so it
    /// runs wherever it is called; the poller calls it on its own executor,
    /// the way `LiveMeterDrift.measure` and `AccountList.read` read.
    nonisolated static func accountSummaries(
        container: ModelContainer, laneCounts: [String: Int], activeKey: String?
    ) -> [AccountStatusSummary] {
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

    private static func testResult(from outcome: PollOutcome) -> TokenTestResult {
        switch outcome {
        case .success(let fh, let sd):   return .success(fiveHour: fh, sevenDay: sd)
        case .secondaryAccount(let org): return .otherAccount(org: org)
        case .rateLimited:               return .failure(reason: "Rate-limited (429). This token is cooling down.")
        case .unauthorized:              return .failure(reason: "Anthropic rejected this token (401).")
        case .forbiddenParked:           return .failure(reason: "Anthropic keeps refusing this token (HTTP 403).")
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
        loadPersistedMetaIfNeeded()
        ensureLanes()
        await publishStatus()

        if configuration.startupDelay > 0 {
            await nap(configuration.startupDelay)
            if stopping || Task.isCancelled { return }
        }

        while !stopping && !Task.isCancelled {
            ensureLanes()
            _ = ingestSwitcherCache()
            let activity = await currentActivity()
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
                // A non-active account may be due for its sweep even while the
                // fast pool waits. Each of its lanes is still gated to ≤ 1×/5min,
                // and its lanes take turns rather than going together (#350).
                let sweep = scheduler.decideSweep(
                    lanes: lanes.map(\.state), accountKeys: lanes.map(\.accountKey),
                    interval: configuration.secondarySweepInterval, now: now)
                if case .poll(let sIdx)? = sweep {
                    _ = await pollLane(sIdx)
                    await publishStatus()
                    continue
                }
                var wait = fastWait
                if case .wait(let sweepWait)? = sweep { wait = min(wait, sweepWait) }
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
    ///
    /// One ingest at a time, by structure: an ingest is one synchronous
    /// section on the poller, its store reads and writes included (#429). The
    /// loop and the file watcher (#241) both ask for one, and neither can
    /// start while the other runs, so neither can replay the other's reading.
    /// (When the writes hopped to the main actor, an ingest suspended in the
    /// middle, and an in-flight flag folded a second request into a re-run.)
    private func ingestSwitcherCache() -> SwitcherIngestTally {
        var tally = SwitcherIngestTally()
        let contents = switcherCache()
        let readings = contents.readings
        tally.accounts = provisionSwitcherAccounts(contents.accounts)
        forgetSwitcherSchedule(
            exceptAccounts: Set(readings.map { Account.key(forOrg: $0.organizationId) }))
        guard !readings.isEmpty else { return tally }
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
            lastSwitcherIngestAt[key] = reading.fetchedAt
            guard Self.isNewerThanStored(reading.fetchedAt, account: key, container: container)
            else { continue }
            tally.readings += 1

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
            // percentages and nothing about the account behind them.
            //
            // This is a supplement, not a substitute. Pacer still polls any
            // account it holds a usable token for — the secondary sweep runs
            // every `perTokenMinInterval` — so an account being read from the
            // cache here is not thereby unpolled. `recordPoll` never
            // overwrites a known plan with nil, so a plan learned from a real
            // poll survives every cache ingest after it.
            recordPoll(snapshot, accountKey: key,
                       organizationId: reading.organizationId,
                       subscriptionType: nil,
                       isActive: activeAccountKey == key,
                       laneSource: .parked,
                       laneId: nil,
                       source: RateLimitSource.cswap)
        }
        return tally
    }

    /// What one read of cswap's cache added, for the event-driven log line.
    private struct SwitcherIngestTally {
        var readings = 0
        var accounts = 0
    }

    /// Read cswap's cache now rather than on the loop's next pass — called
    /// when the file changes (#241, #192). A switch through cswap shows up
    /// here first: the roster names the account, and its readings are often
    /// already in the file before Pacer has a lane for its token.
    ///
    /// Logs one line when the read recorded something new — readings and/or
    /// accounts, with the ms since the write was seen — and nothing when it
    /// recorded nothing: cswap rewrites its cache every poll, mostly with
    /// data Pacer already holds, and a line per write would be noise.
    public func ingestSwitcherCacheNow(seenAt: Date? = nil) async {
        let tally = ingestSwitcherCache()
        await publishStatus()
        guard tally.readings > 0 || tally.accounts > 0 else { return }
        var parts: [String] = []
        if tally.readings > 0 { parts.append("\(tally.readings) reading(s)") }
        if tally.accounts > 0 { parts.append("\(tally.accounts) new account(s)") }
        let lag = seenAt.map { " (+\(Int(Date().timeIntervalSince($0) * 1000)) ms since the write was seen)" } ?? ""
        Log.write("OAuthPoller", "switcher cache changed: recorded " + parts.joined(separator: ", ") + lag)
    }

    /// Give every account cswap lists a row, readings or not (#241).
    ///
    /// The roster is the one place an account Pacer has never polled is named
    /// before anyone switches to it, so this is what lets Settings and the
    /// menu list it straight away. Creates only — `Account.ensure` never
    /// touches a row that exists — and the in-memory set keeps an unchanged
    /// roster from costing a store read on every pass.
    @discardableResult
    private func provisionSwitcherAccounts(_ listed: [SwitcherUsageCache.ListedAccount]) -> Int {
        let missing = listed.filter {
            !provisionedSwitcherAccounts.contains(Account.key(forOrg: $0.organizationId))
        }
        guard !missing.isEmpty else { return 0 }
        let seeds = missing.map(Account.Seed.init)
        // On the poller, not the main actor (#429).
        let write = Self.writeRosterAccounts(seeds, container: container)
        if write.saved { AccountWriteSignal.post(from: self) }
        let created = write.created
        provisionedSwitcherAccounts.formUnion(seeds.map(\.id))
        if !created.isEmpty {
            Log.write("OAuthPoller",
                      "listed \(created.count) account(s) from the switcher's roster before any reading: "
                        + created.map { String($0.prefix(4)) }.joined(separator: ", "))
        }
        return created.count
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
            // And when it last got an answer, which Pacer ingests: a reading
            // Pacer has, so the lane isn't "overdue" for one of its own (#207).
            lanes[i].state.externalLastSuccessAt = reading.fetchedAt
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
    ///
    /// Read on the poller, on a context of its own, not on the main actor
    /// (#417): it runs on the poll cadence, for every new switcher reading.
    /// The main-actor version made a fresh context too, so it saw the same
    /// saved rows.
    nonisolated static func isNewerThanStored(_ at: Date, account: String,
                                              container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        var d = FetchDescriptor<RateLimitSample>(
            predicate: LimitScope.rateLimitPredicate(account: account),
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        d.fetchLimit = 1
        guard let newest = (try? context.fetch(d))?.first else { return true }
        return at > newest.sampledAt
    }

    /// Cancellable sleep. `notifyActivity()` / `stop()` cancel the inner
    /// task to return early; `try?` swallows the CancellationError so the
    /// loop simply re-evaluates (or exits on `stopping`).
    ///
    /// A nap that starts after `stop()` doesn't sleep. `stop()` cancels the
    /// sleeper it finds, and when it lands while the loop is suspended
    /// somewhere else — a poll, a main-actor publish — there is none to find.
    /// The loop then started a fresh one, an unstructured task that doesn't
    /// inherit the loop's cancellation, and `stop()` waited it out — up to the
    /// ten-minute idle interval. That held up the app's quit and hung CI.
    /// Nothing suspends between the check and `sleeper = task`, so a `stop()`
    /// either ran before the check or finds this sleeper to cancel.
    private func nap(_ seconds: TimeInterval) async {
        guard seconds > 0, !stopping, !Task.isCancelled else { return }
        let clock = self.clock
        let task = Task { _ = try? await clock.sleep(seconds: seconds) }
        sleeper = task
        // The loop task's own cancellation reaches the sleep too.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
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
            // A seeded credential can be older than the code reading it, and
            // for a token no live source still offers there is nothing to
            // replace it with: `mergeCandidates` refreshes a lane's credential
            // only when a *current* copy of the same token turns up.
            //
            // That is the state a rotated-away account lands in. Its token
            // still polls fine — usage keeps flowing — but the description of
            // it stays whatever the pool holds, so a field added since is
            // absent until that account is the live login again and the
            // keychain offers the token afresh. Usage is never affected; only
            // the metadata is.
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
        var discovered = false
        if stale || noUsable {
            discoverLanes(now: now, full: true)
            discovered = true
        } else if emptyPoolDiscoveryDue(now) {
            discoverLanes(now: now, full: false)
            discovered = true
        }
        dropExpiredLanes(now: now)
        // The sweep can itself empty the fast pool: the token it just dropped
        // was the active account's, and Claude Code has very likely already
        // written its replacement. Look again in this pass rather than the
        // next one (the throttle still applies).
        if !discovered, emptyPoolDiscoveryDue(now) {
            discoverLanes(now: now, full: false)
            dropExpiredLanes(now: now)
        }
        sortLanes()
        savePool()
    }

    /// True when no `.primary`/`.unknown` lane remains — the same set
    /// `OAuthPollScheduler.decide` treats as usable — and the last
    /// empty-pool discovery is older than the throttle.
    ///
    /// **Why this is separate from `noUsable`.** Secondary lanes (another
    /// account's Desktop tokens) keep `lanes.isEmpty` false, so losing every
    /// fast-pool lane used to wait out `laneRediscoverInterval`. On
    /// 2026-10-07 the active account's only token expired at 18:14Z and the
    /// lane was dropped; Claude Code refreshed it within seconds, but the next
    /// discovery was 18:34Z, so the account every pacing decision reads went
    /// 9-10 minutes stale (#212).
    ///
    /// A lane parked after repeated 403s does not count (#482). It keeps its
    /// `.primary` or `.unknown` slot, so it used to hold this look off for its
    /// whole 6 h, and a token refused from its first poll stays `.unknown` for
    /// good; meanwhile the replacement Claude Code wrote went unread until the
    /// scheduled discovery.
    private func emptyPoolDiscoveryDue(_ now: Date) -> Bool {
        guard !lanes.contains(where: {
            !$0.refused403 && ($0.state.account == .primary || $0.state.account == .unknown)
        })
        else { return false }
        return lastEmptyPoolDiscoveryAt.map {
            now.timeIntervalSince($0) >= configuration.emptyPoolRediscoverInterval
        } ?? true
    }

    /// Re-read Claude's stores and merge what they offer into `lanes`.
    ///
    /// `full: false` is the once-a-minute empty-pool look: it never reads
    /// `Claude Safe Storage`, and it leaves `lastDiscoveryAt` alone so the
    /// scheduled full discovery still runs on time. At that cadence a
    /// declined Desktop prompt would be back within the minute, every minute,
    /// which is the prompt loop v0.3.9 removed. The token it is looking for is
    /// Claude Code's, in the keychain, and reading that never prompts.
    private func discoverLanes(now: Date, full: Bool) {
        // Hand the client our Desktop-origin tokens so its layered read
        // can decide whether it even needs to touch Claude Desktop.
        let cachedDesktop = lanes.filter { $0.source == .desktop }.map { $0.credential }
        let candidates = client.candidateCredentials(cachedDesktopTokens: cachedDesktop,
                                                     allowDesktopKeyRead: full)
        mergeCandidates(candidates)
        if full { lastDiscoveryAt = now }
        lastEmptyPoolDiscoveryAt = now
        // Remember what the keychain holds *now*, so the attribution trail
        // can tell a real switch (the keychain changed) from a stale
        // `oauthAccount` written by some other Claude Code process (it
        // did not).
        liveKeychainToken = candidates.first { $0.source == .keychain }?.credential.accessToken
        liveKeychainReadAt = liveKeychainToken == nil ? nil : now
        // One line per launch saying the keychain read works (#325): the
        // post-install check in AGENTS.md greps for it. It is written here,
        // where launch's first discovery reads the item, rather than when the
        // token is next polled. On a machine where an account switcher fetches
        // the signed-in account's usage, Pacer can go well past fifteen
        // minutes without polling that token, and the per-poll `ok 5h=` lines
        // only appear for the active account on a change of outcome.
        if !keychainTokenRead, let live = liveKeychainToken {
            keychainTokenRead = true
            Log.write("OAuthPoller", "ok keychain: read Claude Code's token; " + Self.laneLabel(
                laneCount: lanes.count, lane: lanes.first { $0.credential.accessToken == live },
                liveKeychainToken: live))
        }
        // The token Claude Code is billing now, never polled: let the
        // scheduler poll it ahead of the endpoint-cadence gate (#214).
        if let live = liveKeychainToken,
           let i = lanes.firstIndex(where: { $0.credential.accessToken == live }),
           lanes[i].state.account == .unknown, lanes[i].state.lastPolledAt == nil {
            lanes[i].state.probeFirst = true
        }
        publishSignedInCredential()
    }

    /// Drop lanes whose token has expired locally (server would 401).
    private func dropExpiredLanes(now: Date) {
        lanes.removeAll { lane in
            if let exp = lane.credential.expiresAt, exp < now { return true }
            return false
        }
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

    // MARK: - Stalled lanes (telemetry)

    /// A lane that was polled before, whose credential is still good and that
    /// is not cooling down, yet has not been polled for this long: the
    /// scheduler is starving it (or deferring to another client for good).
    /// Longer than `externalYieldMax` twice over, so ordinary yielding to
    /// cswap never counts.
    static let stalledLaneAfter: TimeInterval = 30 * 60

    /// How many of these lanes are stalled. Pure, for tests.
    static func stalledLaneCount(lastPolledAt: [Date?], expiresAt: [Date?], cooldownUntil: [Date?],
                                 now: Date, after threshold: TimeInterval = stalledLaneAfter) -> Int {
        var n = 0
        for i in lastPolledAt.indices {
            guard let last = lastPolledAt[i], now.timeIntervalSince(last) >= threshold else { continue }
            if let exp = expiresAt[i], exp <= now { continue }
            if let cool = cooldownUntil[i], cool > now { continue }
            n += 1
        }
        return n
    }

    private var lastStalledNoteAt: Date?


    /// After each poll: tally `oauth.lane_stalled` when a lane has gone quiet,
    /// at most once an hour. A loop over a handful of lanes and a counter add;
    /// nothing is sent from here (the check-in sends the tally).
    private func noteStalledLanes(now: Date) {
        if let last = lastStalledNoteAt, now.timeIntervalSince(last) < 3_600 { return }
        let n = Self.stalledLaneCount(
            lastPolledAt: lanes.map { $0.state.lastPolledAt },
            expiresAt: lanes.map { $0.credential.expiresAt },
            cooldownUntil: lanes.map { $0.state.cooldownUntil },
            now: now)
        guard n > 0 else { return }
        lastStalledNoteAt = now
        TelemetryCounters.add("oauth.lane_stalled", n)
    }

    /// A lane's token refused with 403 this many polls in a row is parked (#434).
    /// One 403 between successes keeps the ordinary cooling.
    static let forbidden403ParkAfter = 3
    /// How long a parked lane waits. A changed token is a different lane, so it
    /// is polled at once; this only paces retries of the same refused token.
    static let forbidden403Backoff: TimeInterval = 6 * 3600

    enum ForbiddenKind: String { case permission, edge, unknown }

    /// What a 403 looks like, judged locally and never sent or logged beyond
    /// this one word. Anthropic's own refusals are JSON with an error type
    /// `permission_error`; a WAF, proxy or region block answers with an HTML or
    /// plain-text page. Nothing else is a reliable signal, so anything that is
    /// neither is `.unknown` and treated like a permission refusal.
    nonisolated static func forbiddenKind(body: String) -> ForbiddenKind {
        if body.contains("permission_error") { return .permission }
        let head = body.drop(while: \.isWhitespace).prefix(1)
        if head == "<" { return .edge }
        if !body.isEmpty, head != "{" { return .edge }
        return .unknown
    }

    /// Why a lane refused `forbidden403ParkAfter` times in a row was left to
    /// ordinary cooling. The raw value is the `oauth.lane_park_declined.<reason>`
    /// counter's last word (#482).
    enum ParkDecline: String, CaseIterable {
        /// The body is an edge page (WAF, proxy, region block), not Anthropic's.
        case edge
        /// The body is not `permission_error` and the lane has never had a
        /// good reading, so there is no account whose other lanes could vouch.
        case noAccount = "no_account"
        /// No lane that could vouch took a good reading during the streak.
        case noSibling = "no_sibling"
    }

    /// Park, or why not (nil parks). Pure, so the rule is tested on its own.
    ///
    /// A park needs another lane that is healthy and took a good reading since
    /// the streak began, as evidence that the network and the endpoint work and
    /// only this token is refused. Which lanes count depends on the body:
    ///
    /// - `permission_error` is Anthropic's API answering, so the request got
    ///   there. Any healthy lane, of any account, then shows the path is fine
    ///   (#482). Requiring the same account left two cases that never parked:
    ///   a token refused from its first poll (an account is learned only from
    ///   a good reading) and an account whose only token is refused, the field
    ///   case behind #482, polled about 24 times a day for ever.
    /// - Any other non-edge body is unproven, so it keeps #434's rule: a lane
    ///   of the same account must vouch.
    nonisolated static func parkDecline(kind: ForbiddenKind, hasAccount: Bool,
                                        sameAccountHealthy: Bool, anyHealthy: Bool) -> ParkDecline? {
        switch kind {
        case .edge: return .edge
        case .permission: return anyHealthy ? nil : .noSibling
        case .unknown:
            guard hasAccount else { return .noAccount }
            return sameAccountHealthy ? nil : .noSibling
        }
    }

    private var lastAllForbiddenLogAt: Date?

    static func refusedReason(until: Date?) -> String {
        guard let until else { return "Anthropic refused this token (HTTP 403)" }
        return "Anthropic refused this token (HTTP 403) — retrying at "
            + until.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - One poll

    @discardableResult
    private func pollLane(_ idx: Int, manual: Bool = false) async -> PollOutcome {
        guard idx < lanes.count else { return .credentialsNotFound }
        let credential = lanes[idx].credential
        let polledAt = Date()
        let result = await client.fetchUsage(using: credential)
        let now = clock.now()
        // Every poll is tallied (the check-in's outcome rates: 401/429...),
        // but only slow ones are sent as timings: a poll a minute per lane on
        // every Mac would spend the free plan's metric quota on normal polls.
        let outcomeClass = Self.telemetryOutcome(result)
        let pollMs = Date().timeIntervalSince(polledAt) * 1000
        TelemetryCounters.add("oauth.poll.\(outcomeClass)")
        TelemetryCounters.add(pollMs < 1000 ? "oauth.poll_ms.lt1s" : pollMs < 5000 ? "oauth.poll_ms.1_5s" : "oauth.poll_ms.gt5s")
        if pollMs >= 2000 {
            Telemetry.distribution("oauth.poll_ms", pollMs, unit: .millisecond,
                                   attributes: ["outcome": .string(outcomeClass)])
        }
        lastPollAt = now
        // Guard: the lane array can change across the await (rediscovery
        // never runs concurrently on the same actor, but be defensive).
        guard idx < lanes.count, lanes[idx].credential.accessToken == credential.accessToken else {
            return lastOutcome ?? .transport
        }
        lanes[idx].state.lastPolledAt = now
        lanes[idx].state.probeFirst = false

        let previous = lastOutcome
        let previousLane = lastPolledLaneId
        // The lane as it was polled: a 401 or an expiry removes it, and the log
        // line must name that one, not whichever lane slid into its slot.
        let polledLane = lanes[idx]
        let outcome = apply(result: result, laneIndex: idx, now: now, manual: manual)
        lastOutcome = outcome
        noteStalledLanes(now: now)
        lastPolledLaneId = idx < lanes.count
            ? Self.laneId(lanes[idx].credential.accessToken) : nil
        // Log a change of lane as well as a change of outcome. Deduping on the
        // outcome alone hid which token was being spent, which is the one thing
        // that matters when two clients share one: a run of identical `ok`
        // lines could be one lane every minute or six lanes in rotation, and
        // there was no way to tell them apart from outside.
        //
        // Except a non-active account's sweep, which rotates through its
        // tokens by design, so every poll is a change of lane. Seven Desktop
        // tokens wrote the same "tracked as secondary" line 84 times an hour.
        // It gets one line an hour instead, saying how its polls were spread.
        if case .secondaryAccount = outcome, idx < lanes.count, let key = lanes[idx].accountKey {
            if let spread = noteSweepPoll(account: key, at: now, after: previous) {
                Log.write("OAuthPoller", Self.summarize(
                    outcome: outcome, laneCount: lanes.count, lane: lanes[idx],
                    liveKeychainToken: liveKeychainToken) + spread)
            }
        } else if !Self.sameCategory(previous, outcome) || previousLane != lastPolledLaneId {
            Log.write("OAuthPoller", Self.summarize(
                outcome: outcome, laneCount: lanes.count,
                lane: Self.removedByPoll(outcome) ? polledLane : (idx < lanes.count ? lanes[idx] : nil),
                liveKeychainToken: liveKeychainToken))
        }
        // Persist the lane's freshly-learned state (account/org/last-poll/
        // cooldown) so it survives a restart.
        saveAllLaneMeta()
        return outcome
    }

    private static func removedByPoll(_ outcome: PollOutcome) -> Bool {
        switch outcome {
        case .unauthorized, .tokenExpired: return true
        default: return false
        }
    }

    /// A poll's outcome as a small enumerable label: `ok`, `401`, `403`,
    /// `429`, `5xx`, `http_other`, `transport`, `expired`, `schema_mismatch`,
    /// or `credentials` (nothing to poll with, or the keychain refused).
    /// Never the body or an error description.
    nonisolated static func telemetryOutcome(_ result: Result<RateLimitSnapshot, OAuthClientError>) -> String {
        switch result {
        case .success: return "ok"
        case .failure(let error):
            switch error {
            case .unauthorized: return "401"
            case .rateLimited: return "429"
            case .http(let status, _):
                if status == 403 { return "403" }
                return (500..<600).contains(status) ? "5xx" : "http_other"
            case .transport: return "transport"
            case .tokenExpired: return "expired"
            case .responseSchemaMismatch: return "schema_mismatch"
            case .credentialsNotFound, .keychainAccessDenied, .keychainMalformed, .keychainStatus:
                return "credentials"
            }
        }
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
        now: Date,
        manual: Bool = false
    ) -> PollOutcome {
        // The 403 streak is consecutive: any other outcome ends it (#434), and a
        // lane that is polled again is no longer shown as refused until this
        // poll says so.
        // A manual Test of a parked lane that fails keeps the park: the 6 h is
        // not replaced by a cooling that is shorter. A manual success un-parks.
        if manual, idx < lanes.count, lanes[idx].refused403, case .failure(let e) = result {
            switch e {
            case .http(let s, _): return .http(status: s)
            case .rateLimited(let ra): return .rateLimited(retryAfter: ra)
            case .transport: return .transport
            case .responseSchemaMismatch: return .responseSchemaMismatch
            default: break
            }
        }
        if idx < lanes.count {
            lanes[idx].refused403 = false
            if case .failure(.http(403, _)) = result {} else {
                lanes[idx].consecutive403 = 0
                lanes[idx].streak403Start = nil
            }
        }
        switch result {
        case .success(let snapshot):
            lanes[idx].consecutiveFailures = 0
            lanes[idx].consecutive403 = 0
            lanes[idx].refused403 = false
            lanes[idx].lastSuccessAt = now
            lanes[idx].state.cooldownUntil = nil
            lanes[idx].lastTopPercent = [snapshot.fiveHour?.usedPercentage,
                                         snapshot.sevenDay?.usedPercentage]
                .compactMap { $0 }.max()
            lanes[idx].lastSoonestReset = [snapshot.fiveHour?.resetsAt,
                                           snapshot.sevenDay?.resetsAt]
                .compactMap { $0 }.min()
            let org = snapshot.organizationId
            // This poll does not decide who is signed in, even when it holds
            // the credential Claude Code bills. That is decided in one place:
            // the attribution trail, which weighs `~/.claude.json` against the
            // live keychain credential this poller publishes just below.
            // `ScanCoordinator` then moves the active account when the trail's
            // login changes, and only then.
            //
            // This poll used to switch the active account whenever a
            // `.keychain` lane named another org. Two deciders disagreed, and
            // the active account flapped between three accounts every few
            // minutes (#149). The label was the trigger. A switch puts another
            // account's token in the keychain, and the outgoing token stays in
            // the pool, still valid for hours and still labelled `.keychain`.
            // cswap keeps its copy in its own `claude-swap` items, which Pacer
            // does not read, so no discovery relabels it. Every sweep of it
            // then looked like the "signed-in credential" of the account the
            // user had just left. It also undid a manual pick from the Tokens
            // settings on the next poll, which the coordinator's transition
            // rule exists to respect.
            let isActive = classifyIsActive(org: org)
            lanes[idx].resolvedOrg = org ?? primaryOrg
            // The lane's classification is set further down, so name the
            // account directly: this response just said whose token it is.
            if lanes[idx].credential.accessToken == liveKeychainToken,
               let resolved = lanes[idx].resolvedOrg {
                publishSignedInCredential(resolvedKey: Account.key(forOrg: resolved))
            }
            let accountKey = isActive ? (activeAccountKey ?? Account.key(forOrg: org)) : Account.key(forOrg: org)
            let sub = lanes[idx].credential.subscriptionType
            let tier = lanes[idx].credential.rateLimitTier
            // The lane that took this reading, by the fingerprint
            // `TokenLaneMeta` and the Tokens table use (#352).
            let laneId = Self.laneId(lanes[idx].credential.accessToken)
            if isActive {
                lanes[idx].state.account = .primary
                recordPoll(snapshot, accountKey: accountKey, organizationId: org,
                           subscriptionType: sub, rateLimitTier: tier, isActive: true,
                           laneSource: lanes[idx].source, laneId: laneId)
                return .success(
                    fiveHourPct: snapshot.fiveHour?.usedPercentage,
                    sevenDayPct: snapshot.sevenDay?.usedPercentage
                )
            } else {
                // A different account — track it (create/update its Account
                // row + cached snapshot) but keep it out of the active
                // timeline so two accounts never mix.
                lanes[idx].state.account = .secondary
                recordPoll(snapshot, accountKey: accountKey, organizationId: org,
                           subscriptionType: sub, rateLimitTier: tier, isActive: false,
                           laneSource: lanes[idx].source, laneId: laneId)
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

        case .failure(.http(let status, let body)):
            if status == 403, !manual {
                if lanes[idx].consecutive403 == 0 { lanes[idx].streak403Start = now }
                lanes[idx].consecutive403 += 1
                if lanes[idx].consecutive403 >= Self.forbidden403ParkAfter, park403(idx, body: body, now: now) {
                    return .forbiddenParked
                }
            }
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

    /// Park lane `idx` for `forbidden403Backoff` after repeated 403s, in place:
    /// the lane stays in the pool (so the persisted pool, a manual token's row
    /// and the signed-in credential are untouched) and only its cooldown moves.
    /// Returns false, leaving ordinary cooling, when the refusals do not look
    /// like this token's own (`parkDecline`): no healthy lane beside it (VPN,
    /// proxy, region, WAF, every lane failing together) or an edge page rather
    /// than Anthropic's JSON.
    ///
    /// A park can take an account's last usable lane, the active account's
    /// included (#482). The once-a-minute empty-pool discovery skips parked
    /// lanes, so the token Claude Code writes next is picked up within the
    /// minute rather than at the scheduled rediscovery.
    private func park403(_ idx: Int, body: String, now: Date) -> Bool {
        let kind = Self.forbiddenKind(body: body)
        // A vouching lane took a good reading after this streak began.
        let key = lanes[idx].accountKey
        let since = lanes[idx].streak403Start ?? .distantPast
        let healthy = lanes.indices.filter { i in
            let l = lanes[i]
            return i != idx && !l.refused403
                && l.consecutive403 == 0 && l.consecutiveFailures == 0
                && (l.lastSuccessAt.map { $0 >= since } ?? false)
        }
        let decline = Self.parkDecline(
            kind: kind, hasAccount: key != nil,
            sameAccountHealthy: key != nil && healthy.contains { lanes[$0].accountKey == key },
            anyHealthy: !healthy.isEmpty)
        if let decline {
            // Counted on every declined attempt (a local tally, drained by the
            // daily check-in), so the field says which rule keeps a refused
            // token from parking.
            TelemetryCounters.add("oauth.lane_park_declined.\(decline.rawValue)")
            if lastAllForbiddenLogAt.map({ now.timeIntervalSince($0) >= 3_600 }) ?? true {
                lastAllForbiddenLogAt = now
                let why: String
                switch decline {
                case .edge: why = "an edge-looking response — looks like the network, not the token"
                case .noAccount: why = "no account yet to vouch within — the body is not Anthropic's permission_error"
                case .noSibling:
                    why = kind == .permission
                        ? "no healthy lane of any account beside it — looks like the network, not the token"
                        : "no healthy lane of the account beside it — looks like the network, not the token"
                }
                Log.write("OAuthPoller", "http 403 ×\(lanes[idx].consecutive403) on \(kind.rawValue) body with "
                    + "\(why); not parking (\(decline.rawValue)); lanes=\(lanes.count)")
            }
            return false
        }
        // `consecutive403` is kept: a 403 on the first poll after the 6 h is the
        // same refusal and parks again at once (#482).
        lanes[idx].refused403 = true
        lanes[idx].state.cooldownUntil = now.addingTimeInterval(Self.forbidden403Backoff)
        TelemetryCounters.add("oauth.lane_parked_403")
        return true
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

    /// A non-active account's successful sweep polls since its last log line.
    private struct SweepLogWindow {
        var lastLineAt: Date?
        var polls: [Date] = []
    }
    private var sweepLog: [String: SweepLogWindow] = [:]
    static let sweepLineEvery: TimeInterval = 3_600

    /// Record a successful sweep poll of `key` and say whether it gets a log
    /// line: the account's first this launch, the first after a failure, and
    /// then one an hour. Returns the line's suffix, or nil for no line.
    private func noteSweepPoll(account key: String, at now: Date, after previous: PollOutcome?) -> String? {
        var window = sweepLog[key] ?? SweepLogWindow()
        window.polls.append(now)
        defer { sweepLog[key] = window }
        let recovering: Bool
        switch previous {
        case nil, .success?, .secondaryAccount?: recovering = false
        default: recovering = true
        }
        if let last = window.lastLineAt, now.timeIntervalSince(last) < Self.sweepLineEvery, !recovering {
            return nil
        }
        let spread = Self.sweepSpread(window.polls)
        window.lastLineAt = now
        window.polls = [now]
        return spread
    }

    /// "; 84 polls in 60 min, gap median 43 s, shortest 42 s" — how one
    /// account's sweep was spread, from the poll that wrote the last line to
    /// this one. Evenly staggered, n lanes give gaps of interval/n (#350);
    /// lanes firing together show as a shortest gap of a few seconds. Empty
    /// until there are two gaps to describe.
    static func sweepSpread(_ polls: [Date]) -> String {
        guard polls.count >= 3, let first = polls.first, let last = polls.last else { return "" }
        let gaps = zip(polls, polls.dropFirst()).map { $1.timeIntervalSince($0) }.sorted()
        let minutes = Int((last.timeIntervalSince(first) / 60).rounded())
        return "; \(polls.count - 1) polls in \(minutes) min, gap median \(Int(gaps[gaps.count / 2].rounded())) s"
            + ", shortest \(Int(gaps[0].rounded())) s"
    }

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

    private static func laneLabel(laneCount: Int, lane: Lane?, liveKeychainToken: String?) -> String {
        // Which credential, and whose. Enough to tell a Desktop token from the
        // Claude Code one an account switcher is also holding, without ever
        // putting the token itself in a log file.
        //
        // `keychain(old)` is a token the keychain held once but not now: a lane
        // keeps its `.keychain` label after a switch. Bare `keychain/<account>`
        // for the account the user had just left read as "the signed-in
        // credential" and misled the #149 diagnosis.
        let which = lane.map { l in
            let org = l.accountKey.map { String($0.prefix(4)) } ?? "?"
            let former = l.source == .keychain && l.credential.accessToken != liveKeychainToken
            return "\(former ? "keychain(old)" : l.source.rawValue)/\(org) "
        } ?? ""
        return "\(which)lanes=\(laneCount)"
    }

    private static func summarize(
        outcome: PollOutcome, laneCount: Int, lane: Lane? = nil,
        liveKeychainToken: String? = nil
    ) -> String {
        let lanes = laneLabel(laneCount: laneCount, lane: lane, liveKeychainToken: liveKeychainToken)
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
        case .forbiddenParked:
            return "http 403 ×\(forbidden403ParkAfter) — parked lane (retry in \(Int(forbidden403Backoff / 3600)) h); \(lanes)"
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
    ///
    /// Off the main actor (#417): the loop asks once per pass, and two fetches
    /// on main per poll are the PACER-19 shape. A fresh context, as before.
    /// Called here rather than through a closure, so the fetches run on the
    /// poller's queue with its other store work (#445). An injected probe
    /// (tests) is awaited wherever it runs.
    private func currentActivity() async -> Date? {
        if let activityProbe { return await activityProbe() }
        return Self.latestActivity(container: container)
    }

    /// The newest `TokenSample` or `SessionInfo` moment, on a context of its
    /// own. Pure reads; safe off the main actor.
    nonisolated static func latestActivity(container: ModelContainer) -> Date? {
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

    // MARK: - Lane metadata persistence

    /// Load persisted lane metadata + the active account once per launch.
    /// Restores the active account's org so the classification is intact
    /// immediately, and populates the cache that `ensureLanes`/
    /// `mergeCandidates` read to rehydrate lanes.
    ///
    /// Read here on the poller, not the main actor (#429), and synchronous:
    /// a caller that arrives while it runs cannot proceed on an empty cache.
    private func loadPersistedMetaIfNeeded() {
        guard !metaLoaded else { return }
        metaLoaded = true
        let loaded = Self.readLaneMeta(container: container)
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
        // The park itself is restored above (its cooldown); restore that it was
        // one, which the lane meta has no field for (#482). A park is the only
        // cooldown longer than `laneCooldownMax` past its poll (`cooldownLane`
        // caps every other one there), so the span says so. Without this the
        // first 403 after a relaunch began a new streak of three, the lane did
        // not read as refused, and it held off the empty-pool discovery.
        if Self.persistedMetaIsPark(lastPolledAt: meta.lastPolledAt, cooldownUntil: meta.cooldownUntil,
                                    cooldownMax: configuration.laneCooldownMax) {
            lane.refused403 = true
            lane.consecutive403 = Self.forbidden403ParkAfter
            lane.streak403Start = meta.lastPolledAt
        }
    }

    /// Whether a persisted cooldown is a 403 park rather than ordinary
    /// cooling. One second of slack for the store's date round trip. A manual
    /// Test in a park's last hour moves `lastPolledAt` up to the end, and that
    /// lane restores as ordinary cooling: it then needs three 403s again.
    nonisolated static func persistedMetaIsPark(lastPolledAt: Date?, cooldownUntil: Date?,
                                                cooldownMax: TimeInterval) -> Bool {
        guard let lastPolledAt, let cooldownUntil else { return false }
        return cooldownUntil.timeIntervalSince(lastPolledAt) > cooldownMax + 1
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
    ///
    /// Written here on the poller, not the main actor (#429): it runs after
    /// every poll, and its fetch of every row could page the store in on main.
    /// Nothing reads `TokenLaneMeta` on a signal; the next launch reads it.
    private func saveAllLaneMeta() {
        let rows = lanes.map { laneMetaSnapshot(for: $0) }
        // Keep the in-memory cache in step with what we persist.
        persistedMeta = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        Self.writeLaneMeta(rows, now: clock.now(), container: container)
    }

    // MARK: - Account persistence

    /// Record one poll: upsert the `Account` row (identity + cached latest
    /// readings for the switcher), and — only for the **active** account —
    /// write the window/extra-usage history into the shared timeline tables
    /// stamped with the account id.
    ///
    /// Every read and write here runs on the poller (#429): the main actor is
    /// sent only the signals, after the save has landed, and the poll never
    /// waits for it. Synchronous, so no other call on the poller can run
    /// between deciding what to write and writing it.
    private func recordPoll(
        _ snapshot: RateLimitSnapshot,
        accountKey: String,
        organizationId: String?,
        subscriptionType: String?,
        rateLimitTier: String? = nil,
        isActive: Bool,
        laneSource: CredentialCandidate.Source,
        /// The fingerprint (`laneId`) of the token that took the reading,
        /// stamped on every sample row it writes (#352), so per-lane
        /// freshness and the stagger in #350 can be checked after the log has
        /// rotated. Nil when no token of Pacer's took it: the switcher cache.
        laneId: String?,
        /// Which mechanism produced this observation. Defaults to a live poll;
        /// the switcher-cache path passes its own so the rows say where they
        /// came from and the dashboard's source chip stays honest.
        source: String = RateLimitSource.oauth
    ) {
        let container = self.container
        let captured = snapshot
        // What the live meter showed for each window just before these
        // readings land (#318), measured before the save so its record
        // (`LiveMeterOutcome`, #352) lands in the same save as the readings.
        // Here on the poller, not the main actor: a few bounded reads of its
        // own, the ones the drift log made after the save until now.
        let meterReadings: [(key: String, reading: MeterReading)] =
            [(RateLimitWindowName.fiveHour, captured.fiveHour), (RateLimitWindowName.sevenDay, captured.sevenDay)]
            .compactMap { key, w in
                w.map { (key, MeterReading(at: captured.sampledAt, percent: $0.usedPercentage, resetsAt: $0.resetsAt)) }
            }
            + captured.limits.map {
                ($0.identity, MeterReading(at: captured.sampledAt, percent: $0.percent, resetsAt: $0.resetsAt))
            }
        let measured = LiveMeterDrift.measure(container: container, account: accountKey,
                                              at: captured.sampledAt, readings: meterReadings)
        // Whether this poll's plan is news, decided here rather than by a
        // fetch of the plan events inside the write below (#413).
        let plan = observePlan(account: accountKey, subscriptionType: subscriptionType,
                               rateLimitTier: rateLimitTier, at: captured.sampledAt,
                               reportedBy: laneSource.rawValue)
        let write = Self.writePoll(PollRecord(
            snapshot: captured, accountKey: accountKey, organizationId: organizationId,
            subscriptionType: subscriptionType, rateLimitTier: rateLimitTier, isActive: isActive,
            laneSource: laneSource, laneId: laneId, source: source, plan: plan, measured: measured,
            evictStaleRows: Self.evictionIsDue(now: captured.sampledAt)),
            container: container)
        guard write.saved else {
            // The plan this poll decided never reached the store: read it again
            // next time rather than trust a memory of a write that did not land.
            planStates[accountKey] = nil
            return
        }
        // The row's cached readings, which the window's title shows
        // (`AccountList`), and its plan when `plan` moved it: one post for
        // both, since they land in this one save. From here, off main: its
        // listener hops on its own (`AccountList`), so a busy main thread
        // holds up nothing here.
        AccountWriteSignal.post(from: self)
        // The rest goes to the main actor as finished values, once the save
        // above has landed, and the poll does not wait for it: the next poll's
        // writes need nothing from main. In the order they had when the write
        // ran on main: the summary, then the generation.
        let key = accountKey
        let written = captured.sampledAt
        let wroteRows = write.wroteRows
        Task { @MainActor in
            // For every account, carrying which one. Posting only for the
            // active login left a widget scoped to the other account, and
            // that account's engine, stale until something else wrote
            // (#142). The throttles downstream (per widget kind, the refit
            // floor) make the extra posts cheap.
            if wroteRows {
                postScanCycleSummary(ScanCycleSummary(rateLimitsChanged: true, rateLimitAccountId: key))
            }
            // Every account's rows, not only the active one's: the pace
            // chart and menu draw all of them. See `RateLimitWriteSignal`.
            RateLimitWriteSignal.shared.note(written, account: key)
        }
        // The drift lines for what was measured above (#318): log writes only,
        // off the main actor.
        if wroteRows, !measured.isEmpty {
            Task.detached(priority: .utility) { LiveMeterDrift.log(account: key, measurements: measured) }
        }
    }

    /// Apply a poll's reported plan to the account's remembered state and say
    /// what the poll's save must write (`AccountPlanState`). Nil when the poll
    /// reports no plan (a switcher-cache reading), which reads nothing.
    ///
    /// The first report for an account reads its row and newest events, here
    /// on the poller and never on the main actor; every report after that is
    /// decided in memory. Synchronous, so two polls of one account cannot both
    /// decide against the same state.
    private func observePlan(
        account key: String, subscriptionType: String?, rateLimitTier: String?,
        at observedAt: Date, reportedBy: String?
    ) -> AccountPlanState.Change? {
        guard subscriptionType != nil || rateLimitTier != nil else { return nil }
        var state = planStates[key] ?? AccountPlanState.load(accountId: key, in: ModelContext(container))
        let change = state.observe(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier,
                                   at: observedAt, reportedBy: reportedBy)
        planStates[key] = state
        return change
    }

    /// Test seam: the plan state the poller holds for `account`, if loaded.
    func planStateForTesting(_ account: String) -> AccountPlanState? { planStates[account] }

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
    ///
    /// With a `seed`, a missing row is created first (`Account.ensure`), in the
    /// same context and the same save as the flag flip, so no reader can see
    /// the switch half-done: every row inactive and the new one absent.
    ///
    /// Saved explicitly. The flip used to rely on the throwaway context's
    /// autosave, and what `publishStatus` mirrors into `UsageScope` is read
    /// back from the store a moment later — it has to be there.
    private func activateAccount(_ incoming: String, seed: Account.Seed? = nil) -> Activation {
        // On the poller, not the main actor (#429): a switch is when main is
        // busiest, redrawing every surface for the new account.
        let activation = Self.writeActivation(incoming, seed: seed, container: container)
        if activation.saved { AccountWriteSignal.post(from: self) }
        return activation
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
                    accountId: row.accountId,
                    laneId: row.laneId))
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
                    accountId: row.accountId,
                    laneId: row.laneId))
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

        // Folded and adopted rows are older than the live ones, which is why
        // the signal is a generation rather than a newest-timestamp.
        let newestFolded = archived.map(\.sampledAt).max()
        Task { @MainActor in
            RateLimitWriteSignal.shared.noteHistoryRewritten(newestFolded)
            postScanCycleSummary(ScanCycleSummary(rateLimitsChanged: true))
        }
    }
}
