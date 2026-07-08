import Foundation

/// Result of a user-initiated token test (the Settings "Test" button),
/// routed through the poller so it persists like any poll and counts
/// against that token's budget rather than racing it.
public enum TokenTestResult: Sendable, Equatable {
    case success(fiveHour: Double?, sevenDay: Double?)
    case foreignAccount(org: String?)
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

    public init(
        id: String,
        source: CredentialCandidate.Source,
        organizationId: String?,
        account: OAuthPollScheduler.AccountStatus,
        expiresAt: Date?,
        lastPolledAt: Date?,
        cooldownUntil: Date?,
        consecutiveFailures: Int,
        priority: Int
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
    /// a `.override` lane, polling it once to confirm the account. Returns
    /// `.alreadyTracked` if it's already a lane, `.foreignAccount` /
    /// `.failure` (and doesn't keep it) if it isn't your account / invalid.
    func addManualToken(_ token: String) async -> TokenTestResult
    /// Remove a manually-added (`.override`) lane by its opaque `id`.
    func removeManualToken(id: String) async
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

    public func publish(
        lanes: [TokenLaneStatus],
        isActive: Bool,
        effectiveIntervalSeconds: TimeInterval?
    ) {
        self.lanes = lanes
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
}
