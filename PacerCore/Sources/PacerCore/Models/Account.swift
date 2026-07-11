import Foundation
import SwiftData

/// A distinct Anthropic account (organization) Pacer is tracking.
///
/// Pacer used to assume a single account: the first successful poll pinned
/// a "primary org" and any token that resolved to a *different* org was
/// marked foreign and dropped. That guard kept two accounts' usage from
/// ever mixing into one timeline — but it also meant a person signed into
/// more than one account (work + personal, or account switching) silently
/// lost every account but the first.
///
/// Now each distinct org the poller sees becomes an `Account`. Exactly one
/// account is **active** (`isActive`) at a time; the active account is the
/// one whose usage history lives in `RateLimitSample` / `ExtraUsageSample`
/// and therefore drives the menu bar, dashboard, alerts, and everything
/// downstream. Switching the active account swaps which timeline those
/// tables hold (see `OAuthPoller.setActiveAccount` + `AccountUsageArchive`),
/// so no read site needs to know about accounts and no account's history is
/// ever corrupted by another's.
///
/// Non-active accounts are still polled (each token no more than once per
/// 5 min, the same per-token invariant as before) and their *latest*
/// window readings are cached on this row (`latestFiveHourPct` …), so the
/// Tokens settings switcher can show every account's current usage without
/// writing a second account's samples into the shared timeline.
///
/// The org id is account-identifying but not a secret; like the rest of
/// Pacer's data it stays in the local App Group store and never leaves the
/// device.
@Model
public final class Account {
    /// Stable identity. The `anthropic-organization-id` when the server
    /// returns one; otherwise the `defaultKey` sentinel for the lone
    /// header-less account (you can't distinguish two accounts the server
    /// never names, so they collapse to one — which matches the old
    /// "nil org matches primary" behavior).
    @Attribute(.unique) public var id: String
    /// The raw `anthropic-organization-id`, or nil if the server never
    /// surfaced one for this account.
    public var organizationId: String?
    /// User-facing label. Defaults to a derived name; a rename UI can set
    /// it later without touching identity (`id` stays the org).
    public var displayName: String
    /// Exactly one account has this true — the one driving the timeline
    /// tables and all display. Enforced by the poller, not the schema.
    public var isActive: Bool
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    /// From the token's `subscriptionType` (e.g. `max20x`), when known —
    /// lets the switcher hint the plan.
    public var subscriptionType: String?

    // MARK: - Cached latest readings (for the switcher; non-active accounts
    // don't write history rows, so this is where their current usage lives)
    public var latestFiveHourPct: Double?
    public var latestFiveHourResetsAt: Date?
    public var latestSevenDayPct: Double?
    public var latestSevenDayResetsAt: Date?
    public var latestExtraUsageCents: Int?
    public var latestPolledAt: Date?

    /// Sentinel id for the account whose org the server never returned.
    public static let defaultKey = "default"

    public init(
        id: String,
        organizationId: String?,
        displayName: String,
        isActive: Bool,
        firstSeenAt: Date,
        lastSeenAt: Date,
        subscriptionType: String? = nil,
        latestFiveHourPct: Double? = nil,
        latestFiveHourResetsAt: Date? = nil,
        latestSevenDayPct: Double? = nil,
        latestSevenDayResetsAt: Date? = nil,
        latestExtraUsageCents: Int? = nil,
        latestPolledAt: Date? = nil
    ) {
        self.id = id
        self.organizationId = organizationId
        self.displayName = displayName
        self.isActive = isActive
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.subscriptionType = subscriptionType
        self.latestFiveHourPct = latestFiveHourPct
        self.latestFiveHourResetsAt = latestFiveHourResetsAt
        self.latestSevenDayPct = latestSevenDayPct
        self.latestSevenDayResetsAt = latestSevenDayResetsAt
        self.latestExtraUsageCents = latestExtraUsageCents
        self.latestPolledAt = latestPolledAt
    }

    /// The account key for an observed org id — the org itself, or the
    /// header-less sentinel. Single-sourced so the poller and the account
    /// bookkeeping agree.
    public static func key(forOrg org: String?) -> String {
        guard let org, !org.isEmpty else { return defaultKey }
        return org
    }

    /// A reasonable default label when an account is first discovered.
    /// Short and org-derived; the user can rename later.
    public static func defaultName(forOrg org: String?, subscriptionType: String?) -> String {
        if let sub = subscriptionType, !sub.isEmpty {
            return "Claude account (\(sub))"
        }
        if let org, !org.isEmpty {
            return "Account \(String(org.suffix(4)))"
        }
        return "Primary account"
    }
}
