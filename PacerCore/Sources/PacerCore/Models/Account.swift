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

    // MARK: - Human identity
    //
    // The org id is stable but unreadable, and two accounts on the same plan
    // derive the *same* default name ("Claude account (max)") — which is
    // exactly the case a switcher creates, so the one place the label has to
    // work is the one place it didn't. These carry whatever real identity we
    // can observe, from Claude Code's own `oauthAccount` for the live login
    // and from an external switcher's roster for the others.

    /// The account's email, when known. Nil until observed.
    public var emailAddress: String?
    /// The org's display name, when known (e.g. "Acme's Organization").
    public var organizationName: String?

    // MARK: - Cached latest readings (for the switcher; non-active accounts
    // don't write history rows, so this is where their current usage lives)
    public var latestFiveHourPct: Double?
    public var latestFiveHourResetsAt: Date?
    public var latestSevenDayPct: Double?
    public var latestSevenDayResetsAt: Date?
    public var latestExtraUsageCents: Int?
    public var latestPolledAt: Date?

    /// What to show a person. Prefers real observed identity over the
    /// org-derived placeholder, and falls back through everything we might
    /// know before landing on the raw id — so this is never empty and never
    /// the same string for two different accounts that we have any way to
    /// tell apart.
    public var label: String {
        // A name someone typed wins outright. Anything below this line is
        // observed rather than chosen, and a rename that the email kept
        // overriding would be a control that visibly does nothing.
        if !hasDerivedName { return displayName }
        if let emailAddress, !emailAddress.isEmpty { return emailAddress }
        if let organizationName, !organizationName.isEmpty { return organizationName }
        if !displayName.isEmpty { return displayName }
        return id
    }

    /// A label short enough to sit in a column heading.
    ///
    /// `label` is for places with room — a settings row, a menu. Rendered as a
    /// pace-column title beside "5-hour ·" it is a disaster: two real accounts
    /// gave `5-HOUR · SOMEBODY@EXAMPLE.COM` wrapping onto three lines and
    /// pushing every chart down.
    ///
    /// So: a name the user typed (they chose it, and it is theirs to keep
    /// short), else an email's local part, else the org name, else the id tail.
    /// Capped, because a long org name is the same problem.
    public var shortLabel: String {
        let candidate: String
        if !Self.isDerivedName(displayName) {
            candidate = displayName
        } else if let emailAddress, let local = emailAddress.split(separator: "@").first,
                  !local.isEmpty {
            candidate = String(local)
        } else if let organizationName, !organizationName.isEmpty,
                  !organizationName.contains("@") {
            candidate = organizationName
        } else {
            candidate = "Account \(id.suffix(4))"
        }
        return candidate.count > 18 ? String(candidate.prefix(17)) + "…" : candidate
    }

    /// Whether `displayName` is still one of the auto-derived placeholders
    /// rather than something a person chose. Guards the observer from
    /// overwriting a deliberate rename.
    public var hasDerivedName: Bool { Self.isDerivedName(displayName) }

    /// The same test against a bare string, for callers that hold a display
    /// name without the model — the API's Prometheus exporter, which has to
    /// tell "the user named this" from "we made it up" to decide whether the
    /// name is worth putting in a metric label.
    public static func isDerivedName(_ name: String) -> Bool {
        name.hasPrefix("Claude account (")
            || name.hasPrefix("Account ")
            || name == "Primary account"
            || name.isEmpty
    }

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
        emailAddress: String? = nil,
        organizationName: String? = nil,
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
        self.emailAddress = emailAddress
        self.organizationName = organizationName
        self.latestFiveHourPct = latestFiveHourPct
        self.latestFiveHourResetsAt = latestFiveHourResetsAt
        self.latestSevenDayPct = latestSevenDayPct
        self.latestSevenDayResetsAt = latestSevenDayResetsAt
        self.latestExtraUsageCents = latestExtraUsageCents
        self.latestPolledAt = latestPolledAt
    }

    /// The active account as read from the store rather than from defaults.
    ///
    /// The engine uses this: it owns a `ModelContext` and nothing else, runs on
    /// its own actor, and lives long enough that a value captured at init could
    /// go stale. Reading the flag it is already keeping is self-contained —
    /// and it means a store with no accounts (a fresh install, or a test
    /// fixture) resolves to nil and reads unscoped, which is correct in both.
    public static func activeId(in context: ModelContext) -> String? {
        var d = FetchDescriptor<Account>(predicate: #Predicate { $0.isActive })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.id
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
