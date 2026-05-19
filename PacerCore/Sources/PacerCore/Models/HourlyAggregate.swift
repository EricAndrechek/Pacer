import Foundation
import SwiftData

/// Pre-computed `(date, hour, model)` rollup of `TokenSample` rows.
/// Recomputed by `HourlyAggregateRecomputer` whenever its bucket gets
/// dirtied during a scan — never by per-row triggers, never by views.
///
/// The hourly grain matters because two view cards on the dashboard
/// — `TodayTimelineCard` (24-bar hour-of-day chart) and
/// `LiveActivityCard` (last-hour burn rate) — were the last surfaces
/// that walked raw `TokenSample` rows on every scan tick. On a busy
/// day with ~3000 samples, each tick was thousands of
/// `effectiveCostUSD(mode:)` calls + dictionary inserts just to bucket
/// by hour or sum the trailing hour. With this rollup both queries
/// become small predicate-filtered fetches (≤24 hours × ~5 models =
/// ≤120 rows for today; ≤2 hours × ~5 models = ≤10 rows for live
/// activity).
///
/// `dateHourModelKey == "${date}|${hour}|${model}"` is the unique
/// primary key — three components so SwiftData uniqueness applies
/// cleanly. Hour is the 0–23 local-zone hour-of-day, matching the
/// `date` column's local-zone semantics on `TokenSample`.
@Model
public final class HourlyAggregate {
    // Hot predicates: today-scoped `date == today` (TodayTimelineCard,
    // PerModelTodayCard if we later migrate it), and last-hours-scoped
    // `date >= cutoff` (LiveActivityCard). The single-column `date`
    // index covers both. The compound `(date, hour)` lets the
    // recomputer's per-bucket upsert path resolve a row in one shot.
    #Index<HourlyAggregate>([\.date], [\.date, \.hour], [\.date, \.hour, \.model])

    @Attribute(.unique) public var dateHourModelKey: String
    public var date: String   // YYYY-MM-DD, user's local zone
    public var hour: Int      // 0–23, user's local zone
    public var model: String
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheCreation5mTokens: Int64
    public var cacheCreation1hTokens: Int64
    /// Total cost for this `(date, hour, model)` bucket, computed by
    /// `HourlyAggregateRecomputer` with the user's current cost mode.
    /// Stored so the read path doesn't have to re-apply pricing.
    public var totalCostUSD: Double
    /// Distinct `TokenSample` rows in this bucket. Surfaces as the
    /// "N samples in the last hour" hint on `LiveActivityCard`.
    public var sampleCount: Int

    public init(
        date: String,
        hour: Int,
        model: String,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cacheCreation5mTokens: Int64 = 0,
        cacheCreation1hTokens: Int64 = 0,
        totalCostUSD: Double = 0,
        sampleCount: Int = 0
    ) {
        self.dateHourModelKey = Self.makeKey(date: date, hour: hour, model: model)
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

    public static func makeKey(date: String, hour: Int, model: String) -> String {
        "\(date)|\(hour)|\(model)"
    }
}
