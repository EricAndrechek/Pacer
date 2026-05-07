import Foundation
import SwiftData

/// Materialized daily roll-up of `TokenSample` rows, one per
/// `(date, model)` pair. Recomputed in the background by
/// `AggregateRecomputer` when underlying samples change — never by
/// per-row triggers. Querying this table is the read path for the
/// dashboard, MenuBarExtra, and widgets; a typed view never sums raw
/// samples directly.
///
/// `dateModelKey` is `${date}|${model}` and is the unique primary key.
/// Both components are non-null so SwiftData's uniqueness works
/// straightforwardly (unlike `TokenSample.dedupKey`).
@Model
public final class DailyAggregate {
    @Attribute(.unique) public var dateModelKey: String
    public var date: String
    public var model: String
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheCreation5mTokens: Int64
    public var cacheCreation1hTokens: Int64
    /// Total cost in USD for this (date, model) bucket, computed by
    /// `CostCalculator` from the summed token columns plus the model's
    /// pricing row at recompute time. Stored so the read path doesn't
    /// have to re-apply pricing for every chart redraw.
    public var totalCostUSD: Double

    public init(
        date: String,
        model: String,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cacheCreation5mTokens: Int64 = 0,
        cacheCreation1hTokens: Int64 = 0,
        totalCostUSD: Double = 0
    ) {
        self.dateModelKey = Self.makeKey(date: date, model: model)
        self.date = date
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.totalCostUSD = totalCostUSD
    }

    public static func makeKey(date: String, model: String) -> String {
        "\(date)|\(model)"
    }
}
