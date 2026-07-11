import Foundation
import SwiftData

/// One observation of Anthropic's `extra_usage` field — the metered
/// overage spend Max-plan users incur once they've blown through their
/// quota. Persisted separately from `RateLimitSample` because it isn't
/// scoped to a window kind; it's an account-level cents counter that
/// monotonically rises (or jumps to a fresh value on a new billing
/// cycle) between OAuth polls.
///
/// We keep the history rather than overwriting so the dashboard can
/// show "extra spend added today" vs the running total, and so a
/// regression in Anthropic's accounting can be debugged from raw
/// rows.
@Model
public final class ExtraUsageSample {
    #Index<ExtraUsageSample>([\.sampledAt])

    public var sampledAt: Date
    /// USD cents. Use cents-as-Int so float drift across many polls
    /// doesn't silently inflate the displayed amount.
    public var amountCents: Int
    /// `"oauth"` for now — mirrors `RateLimitSample.source` so a
    /// future statusline/pushed source can be distinguished.
    public var source: String
    /// Which account (`Account.id`) this sample belongs to. Optional +
    /// additive, same contract as `RateLimitSample.accountId`: nil ⇒ the
    /// active account. See `Account`.
    public var accountId: String?

    public init(sampledAt: Date, amountCents: Int, source: String, accountId: String? = nil) {
        self.sampledAt = sampledAt
        self.amountCents = amountCents
        self.source = source
        self.accountId = accountId
    }

    public var amountUSD: Double {
        Double(amountCents) / 100
    }
}
