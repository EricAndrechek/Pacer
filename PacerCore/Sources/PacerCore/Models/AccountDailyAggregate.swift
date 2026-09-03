import Foundation
import SwiftData

/// The same daily rollup as `DailyAggregate`, split by account.
///
/// Kept **alongside** the global rollup rather than replacing it, because the
/// two answer different questions and both are wanted. Someone with a work
/// account and a personal one may reasonably ask "what did I spend today"
/// (all of it) or "what did work cost" (one of them), and which they want
/// changes by the minute — so both are computed always and switching is a
/// read, never a recompute.
///
/// Replacing `DailyAggregate`'s key with an account-aware one was the obvious
/// alternative and is a trap: views that map aggregates one-to-one onto
/// displayed rows — the per-model breakdown, for one — would list a model
/// twice the moment two accounts used it on the same day. Every global read
/// site stays untouched this way.
///
/// The cost of a second rollup is that it can drift from the first.
/// `make verify-data` checks that these rows sum to their `DailyAggregate`
/// counterpart, which is the same guard that caught the pricing drift.
@Model
public final class AccountDailyAggregate {
    /// `"<accountId>|<date>|<model>"`. Composite because SwiftData can only
    /// enforce uniqueness on a single attribute, the same trick
    /// `DailyAggregate.dateModelKey` uses.
    @Attribute(.unique) public var accountDateModelKey: String

    /// `Account.id`, or `unattributedKey` for turns recorded before the trail
    /// existed. Not optional: a nil would make the unique key ambiguous, and
    /// the distinction has to survive into the rollup or "unattributed" would
    /// silently merge into whichever account sorted first.
    public var accountId: String
    /// `YYYY-MM-DD`, local, matching `TokenSample.date`.
    public var date: String
    public var model: String

    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheCreation5mTokens: Int64
    public var cacheCreation1hTokens: Int64
    public var totalCostUSD: Double

    #Index<AccountDailyAggregate>(
        [\.accountDateModelKey],
        [\.date],
        [\.accountId, \.date]
    )

    /// Stands in for `TokenSample.accountId == nil`. A sentinel rather than
    /// an optional column so the unique key is always well-formed; the
    /// U+0000 prefix cannot collide with a real org id.
    public static let unattributedKey = "\u{0000}unattributed"

    public static func makeKey(accountId: String, date: String, model: String) -> String {
        "\(accountId)|\(date)|\(model)"
    }

    public init(
        accountId: String,
        date: String,
        model: String,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheCreation5mTokens: Int64,
        cacheCreation1hTokens: Int64,
        totalCostUSD: Double
    ) {
        self.accountDateModelKey = Self.makeKey(
            accountId: accountId, date: date, model: model)
        self.accountId = accountId
        self.date = date
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.totalCostUSD = totalCostUSD
    }

    public var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadTokens
            + cacheCreation5mTokens + cacheCreation1hTokens
    }
}
