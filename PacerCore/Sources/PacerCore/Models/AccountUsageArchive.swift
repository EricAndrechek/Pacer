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
/// One archive type carries both sample kinds (rate-limit windows and
/// extra-usage cents) to keep the schema small; `kind` disambiguates and
/// the unused fields are simply nil for the other kind. Nothing here is a
/// secret (no token bytes; org identity lives on `Account`), and like the
/// rest of Pacer's data it never leaves the device.
@Model
public final class AccountUsageArchive {
    /// Which account this archived row belongs to (`Account.id`).
    public var accountId: String
    /// `"rate_limit"` or `"extra_usage"` — mirrors the live table it came
    /// from. String, not enum, for the same forward-compat reason the
    /// sample tables use strings.
    public var kind: String
    public var sampledAt: Date
    /// rate-limit only: `"five_hour"` / `"seven_day"`.
    public var window: String?
    /// rate-limit only: 0–100.
    public var usedPercentage: Double?
    /// rate-limit only.
    public var resetsAt: Date?
    /// extra-usage only: USD cents.
    public var amountCents: Int?
    /// The live row's `source` (`"oauth"` / `"statusline"`), preserved so a
    /// restored row is indistinguishable from one that was never archived.
    public var source: String

    #Index<AccountUsageArchive>([\.accountId])

    public init(
        accountId: String,
        kind: String,
        sampledAt: Date,
        window: String? = nil,
        usedPercentage: Double? = nil,
        resetsAt: Date? = nil,
        amountCents: Int? = nil,
        source: String
    ) {
        self.accountId = accountId
        self.kind = kind
        self.sampledAt = sampledAt
        self.window = window
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.amountCents = amountCents
        self.source = source
    }

    public static let kindRateLimit = "rate_limit"
    public static let kindExtraUsage = "extra_usage"
}
