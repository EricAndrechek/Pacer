import Foundation
import SwiftData

/// Persisted per-token scheduling metadata for the OAuth poll pool.
///
/// The tokens themselves live in Pacer's keychain (`TokenPoolStoring`);
/// this is the *derived* state the poller learns by polling — which
/// account a token resolved to, when it last polled, whether it's cooling
/// down — keyed by the token's opaque fingerprint (`OAuthPoller.laneId`).
///
/// Persisting it means the Settings "Tokens" table shows real status,
/// account, expiry and "updated" immediately on launch instead of a row
/// of placeholders until the first poll lands — and the poller restores
/// each lane's cooldown / last-polled / account so it doesn't re-poll a
/// just-polled token (spending its budget) right after a restart.
///
/// No secret lives here (no token bytes — only the fingerprint), but the
/// org id is account-identifying, so like the rest of Pacer's data it
/// stays in the local App Group store and never leaves the device.
@Model
public final class TokenLaneMeta {
    /// The lane's opaque fingerprint (`OAuthPoller.laneId`) — 12 hex chars
    /// of the token's SHA-256. Unique so writes upsert by token identity.
    @Attribute(.unique) public var id: String
    /// `CredentialCandidate.Source.rawValue` — keychain / desktop / held / override.
    public var sourceRaw: String
    /// The account (`anthropic-organization-id`) this token resolved to.
    public var organizationId: String?
    /// `AccountStatus` raw string — unknown / primary / foreign.
    public var accountRaw: String
    /// Local token expiry, when known.
    public var expiresAt: Date?
    public var lastPolledAt: Date?
    public var cooldownUntil: Date?
    public var consecutiveFailures: Int
    /// When this row was last written — lets a stale-pool cleanup prune
    /// metadata for tokens that have gone away.
    public var updatedAt: Date

    public init(
        id: String,
        sourceRaw: String,
        organizationId: String?,
        accountRaw: String,
        expiresAt: Date?,
        lastPolledAt: Date?,
        cooldownUntil: Date?,
        consecutiveFailures: Int,
        updatedAt: Date
    ) {
        self.id = id
        self.sourceRaw = sourceRaw
        self.organizationId = organizationId
        self.accountRaw = accountRaw
        self.expiresAt = expiresAt
        self.lastPolledAt = lastPolledAt
        self.cooldownUntil = cooldownUntil
        self.consecutiveFailures = consecutiveFailures
        self.updatedAt = updatedAt
    }
}

// MARK: - AccountStatus <-> raw string

extension OAuthPollScheduler.AccountStatus {
    public var rawValue: String {
        switch self {
        case .unknown:   return "unknown"
        case .primary:   return "primary"
        case .secondary: return "secondary"
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "primary":              self = .primary
        // v0.3.22 persisted a different-account token as "foreign" (then
        // dropped it). Multi-account tracks it instead, as a secondary.
        case "secondary", "foreign": self = .secondary
        default:                     self = .unknown
        }
    }
}
