import Foundation

/// Result of a user-initiated token test (the Settings "Test" button),
/// routed through the poller so it persists like any poll and counts
/// against that token's budget rather than racing it.
public enum TokenTestResult: Sendable, Equatable {
    case success(fiveHour: Double?, sevenDay: Double?)
    /// The token belongs to a *different* Anthropic account. No longer
    /// dropped: it's tracked as a separate `Account` you can switch to.
    /// Carries that account's org id for the UI.
    case otherAccount(org: String?)
    case failure(reason: String)
    /// Add-token only: the token is already in the pool — nothing added.
    /// Carries the matching lane's source + fingerprint so the UI can say
    /// *which* token it is (and highlight its row).
    case alreadyTracked(source: CredentialCandidate.Source, fingerprint: String)
    /// The poller isn't running (no background service) — nothing to route to.
    case unavailable
}

/// A display-safe snapshot of one poll lane. Carries no raw token — only
/// an opaque stable `id` (a hash) for identity + test routing, and the
/// facts the Tokens settings section shows.
public struct TokenLaneStatus: Sendable, Identifiable, Equatable {
    public let id: String
    public let source: CredentialCandidate.Source
    public let organizationId: String?
    public let account: OAuthPollScheduler.AccountStatus
    public let expiresAt: Date?
    public let lastPolledAt: Date?
    public let cooldownUntil: Date?
    public let consecutiveFailures: Int
    /// Selection rank (0 = highest priority). Mirrors the poller's
    /// primary-first ordering.
    public let priority: Int
    /// The `Account.id` this lane resolved to (nil until classified), so the
    /// Tokens UI can group lanes under their account.
    public let accountKey: String?

    public init(
        id: String,
        source: CredentialCandidate.Source,
        organizationId: String?,
        account: OAuthPollScheduler.AccountStatus,
        expiresAt: Date?,
        lastPolledAt: Date?,
        cooldownUntil: Date?,
        consecutiveFailures: Int,
        priority: Int,
        accountKey: String? = nil
    ) {
        self.id = id
        self.source = source
        self.organizationId = organizationId
        self.account = account
        self.expiresAt = expiresAt
        self.lastPolledAt = lastPolledAt
        self.cooldownUntil = cooldownUntil
        self.consecutiveFailures = consecutiveFailures
        self.priority = priority
        self.accountKey = accountKey
    }
}

/// A display-safe summary of one tracked account for the Tokens switcher.
/// Non-active accounts don't write history rows, so their current usage is
/// carried here (cached on the `Account` row by the poller).
public struct AccountStatusSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let organizationId: String?
    public let displayName: String
    public let isActive: Bool
    public let subscriptionType: String?
    public let fiveHourPct: Double?
    public let sevenDayPct: Double?
    public let extraUsageCents: Int?
    public let lastPolledAt: Date?
    /// How many pollable lanes (tokens) currently resolve to this account.
    public let laneCount: Int

    public init(
        id: String,
        organizationId: String?,
        displayName: String,
        isActive: Bool,
        subscriptionType: String?,
        fiveHourPct: Double?,
        sevenDayPct: Double?,
        extraUsageCents: Int?,
        lastPolledAt: Date?,
        laneCount: Int
    ) {
        self.id = id
        self.organizationId = organizationId
        self.displayName = displayName
        self.isActive = isActive
        self.subscriptionType = subscriptionType
        self.fiveHourPct = fiveHourPct
        self.sevenDayPct = sevenDayPct
        self.extraUsageCents = extraUsageCents
        self.lastPolledAt = lastPolledAt
        self.laneCount = laneCount
    }
}

/// Implemented by the poller so the UI can request a poll of a specific
/// token without reaching into the actor's state. Both routes persist the
/// result and stamp the lane so a manual test spends the token's budget
/// through the same accounting as an automatic poll.
public protocol TokenPoolTesting: AnyObject, Sendable {
    /// Test an existing lane by its opaque `id` (from `TokenLaneStatus`).
    func testLane(id: String) async -> TokenTestResult
    /// Test a raw token the UI holds. If it matches a known lane, that lane
    /// is stamped too.
    func testAdHoc(token: String) async -> TokenTestResult
    /// Add a manually-supplied token (e.g. from another Mac) to the pool as
    /// a `.override` lane, polling it once to classify its account. Returns
    /// `.alreadyTracked` if it's already a lane, `.success` if it's your
    /// active account, `.otherAccount` if it's a *different* account (kept
    /// and tracked as a separate account you can switch to), or `.failure`
    /// (and doesn't keep it) if the token is invalid.
    func addManualToken(_ token: String) async -> TokenTestResult
    /// Remove a manually-added (`.override`) lane by its opaque `id`.
    func removeManualToken(id: String) async
    /// Make the account with this `Account.id` the active one — the account
    /// whose usage drives the menu bar, dashboard, and alerts. Swaps which
    /// account's timeline the shared sample tables hold; no-op if it's
    /// already active or unknown.
    func setActiveAccount(id: String) async
}

/// Process-wide, MainActor-isolated snapshot of the OAuth token pool —
/// same shape as `PacerToday.shared`. The poller publishes lane status
/// and the effective cadence here; the Settings "Tokens" section reads
/// it. A weak `tester` lets the section route "Test" clicks back to the
/// running poller.
@MainActor
@Observable
public final class TokenPoolStatus {

    public static let shared = TokenPoolStatus()

    public private(set) var lanes: [TokenLaneStatus] = []
    /// Every account the poller is tracking, for the Tokens switcher. Empty
    /// for a brand-new single-account user until the first poll classifies
    /// their account (the lanes still render meanwhile).
    public private(set) var accounts: [AccountStatusSummary] = []
    /// False until the poller publishes for the first time this launch. Lets
    /// the Settings section show a brief "loading" state instead of a
    /// misleading "no tokens yet" before the persisted pool is restored.
    public private(set) var hasLoaded: Bool = false
    /// Whether the poller currently considers Claude usage "active"
    /// (recent) — drives the faster cadence.
    public private(set) var isActive: Bool = false
    /// The realized endpoint poll interval given the current lane count
    /// and active/idle state, for the "updating every ~N" header.
    public private(set) var effectiveIntervalSeconds: TimeInterval?
    public private(set) var lastUpdated: Date?

    /// The running poller, set on `start()`. Weak so a stopped poller
    /// doesn't leak; nil ⇒ tests return `.unavailable`.
    public weak var tester: (any TokenPoolTesting)?

    private init() {}

    /// The active account's id, if one has been established.
    public var activeAccountId: String? { accounts.first { $0.isActive }?.id }

    public func publish(
        lanes: [TokenLaneStatus],
        accounts: [AccountStatusSummary],
        isActive: Bool,
        effectiveIntervalSeconds: TimeInterval?
    ) {
        self.lanes = lanes
        self.accounts = accounts
        self.isActive = isActive
        self.effectiveIntervalSeconds = effectiveIntervalSeconds
        self.lastUpdated = Date()
        self.hasLoaded = true
    }

    public func testLane(id: String) async -> TokenTestResult {
        await tester?.testLane(id: id) ?? .unavailable
    }

    public func testAdHoc(token: String) async -> TokenTestResult {
        await tester?.testAdHoc(token: token) ?? .unavailable
    }

    public func addManualToken(_ token: String) async -> TokenTestResult {
        await tester?.addManualToken(token) ?? .unavailable
    }

    public func removeManualToken(id: String) async {
        await tester?.removeManualToken(id: id)
    }

    public func setActiveAccount(id: String) async {
        await tester?.setActiveAccount(id: id)
    }
}
