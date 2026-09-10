import Foundation
import SwiftData

/// `HourlyAggregate`, split by account.
///
/// Second in the pattern `AccountDailyAggregate` established: kept alongside
/// the global rollup rather than replacing it, so every existing read site is
/// untouched and both scopes are always available without a recompute.
///
/// See `AccountDailyAggregate` for why replacing the global rollup's key is a
/// trap, and `make verify-data` for the check that keeps the two in step.
@Model
public final class AccountHourlyAggregate {
    /// `"<accountId>|<date>|<hour>|<model>"`. Composite because SwiftData can
    /// only enforce uniqueness on one attribute.
    @Attribute(.unique) public var accountDateHourModelKey: String

    /// `Account.id`, or `AccountDailyAggregate.unattributedKey` for turns
    /// recorded before the trail existed.
    public var accountId: String
    public var date: String
    /// Local hour 0–23, matching `HourlyAggregate.hour` and stored — never
    /// re-derived, so a DST boundary cannot re-bucket history.
    public var hour: Int
    public var model: String

    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheCreation5mTokens: Int64
    public var cacheCreation1hTokens: Int64
    public var totalCostUSD: Double
    /// Turns in the bucket.
    ///
    /// The global rollup always had this; the per-account one did not, on the
    /// reasoning that it was "only a quiet-hour hint, never a number the user
    /// reads". That was wrong — the dashboard's Now tile gates its *entire*
    /// contents on it, so under any per-account scope the tile read
    /// "Nothing running." however hard you were working.
    ///
    /// Defaulted rather than optional so every read is a plain `Int`; rows
    /// written before this existed report 0 until the recompute-version bump
    /// rebuilds them.
    public var sampleCount: Int = 0

    #Index<AccountHourlyAggregate>(
        [\.accountDateHourModelKey],
        [\.date],
        [\.accountId, \.date]
    )

    public static func makeKey(
        accountId: String, date: String, hour: Int, model: String
    ) -> String {
        "\(accountId)|\(date)|\(hour)|\(model)"
    }

    public init(
        accountId: String, date: String, hour: Int, model: String,
        inputTokens: Int64, outputTokens: Int64, cacheReadTokens: Int64,
        cacheCreation5mTokens: Int64, cacheCreation1hTokens: Int64,
        totalCostUSD: Double,
        sampleCount: Int = 0
    ) {
        self.accountDateHourModelKey = Self.makeKey(
            accountId: accountId, date: date, hour: hour, model: model)
        self.accountId = accountId
        self.date = date
        self.hour = hour
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.totalCostUSD = totalCostUSD
        self.sampleCount = sampleCount
    }
}
