import Foundation
import SwiftData

/// Cold storage for a **non-active** account's usage timeline.
///
/// Pacer keeps exactly one account's history "live" in `RateLimitSample` /
/// `ExtraUsageSample` — the active account — so every existing read site
/// (menu bar, dashboard, charts, alerts) keeps working unchanged and always
/// reflects the active account. When the user switches which account is
/// active, the poller *swaps* timelines: the outgoing account's live rows
/// are folded into this archive (stamped with its `accountId`), and the
/// incoming account's archived rows are restored into the live tables. See
/// `OAuthPoller.setActiveAccount`.
///
/// One archive type carries all sample kinds (rate-limit windows, extra-usage
/// cents, and scoped `limits[]` rows) to keep the schema small; `kind`
/// disambiguates and the unused fields are simply nil for the other kinds.
/// Nothing here is a secret (no token bytes; org identity lives on `Account`),
/// and like the rest of Pacer's data it never leaves the device.
///
/// The scoped-limit columns are all optional + additive (SwiftData
/// lightweight-migration-safe), so adding scoped-history archiving needs no
/// store reset. They mirror `UsageLimitSample`'s fields one-for-one, with its
/// rate-limit `kind` stored as `limitKind` (the archive's own `kind` is the
/// row-type discriminator), and `percent` folded onto the shared
/// `usedPercentage`/`resetsAt` columns.
@Model
public final class AccountUsageArchive {
    /// Which account this archived row belongs to (`Account.id`).
    public var accountId: String
    /// `"rate_limit"`, `"extra_usage"`, or `"usage_limit"` — mirrors the live
    /// table it came from. String, not enum, for the same forward-compat reason
    /// the sample tables use strings.
    public var kind: String
    public var sampledAt: Date
    /// rate-limit only: `"five_hour"` / `"seven_day"`.
    public var window: String?
    /// rate-limit + usage-limit: 0–100 (`UsageLimitSample.percent`).
    public var usedPercentage: Double?
    /// rate-limit + usage-limit.
    public var resetsAt: Date?
    /// extra-usage only: USD cents.
    public var amountCents: Int?
    /// The live row's `source` (`"oauth"` / `"statusline"`), preserved so a
    /// restored row is indistinguishable from one that was never archived.
    public var source: String

    // Scoped `limits[]` columns (kind == kindUsageLimit). All optional/additive.
    public var identity: String?
    /// `UsageLimitSample.kind` (the rate-limit family, e.g. "weekly_scoped").
    public var limitKind: String?
    public var group: String?
    public var label: String?
    public var severity: String?
    public var isActive: Bool?
    public var modelId: String?
    public var modelDisplayName: String?
    public var surface: String?

    #Index<AccountUsageArchive>([\.accountId])

    public init(
        accountId: String,
        kind: String,
        sampledAt: Date,
        window: String? = nil,
        usedPercentage: Double? = nil,
        resetsAt: Date? = nil,
        amountCents: Int? = nil,
        source: String,
        identity: String? = nil,
        limitKind: String? = nil,
        group: String? = nil,
        label: String? = nil,
        severity: String? = nil,
        isActive: Bool? = nil,
        modelId: String? = nil,
        modelDisplayName: String? = nil,
        surface: String? = nil
    ) {
        self.accountId = accountId
        self.kind = kind
        self.sampledAt = sampledAt
        self.window = window
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.amountCents = amountCents
        self.source = source
        self.identity = identity
        self.limitKind = limitKind
        self.group = group
        self.label = label
        self.severity = severity
        self.isActive = isActive
        self.modelId = modelId
        self.modelDisplayName = modelDisplayName
        self.surface = surface
    }

    public static let kindRateLimit = "rate_limit"
    public static let kindExtraUsage = "extra_usage"
    public static let kindUsageLimit = "usage_limit"
}
