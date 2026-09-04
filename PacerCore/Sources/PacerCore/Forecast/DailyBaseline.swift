import Foundation

/// The zero-filled run of complete days a user's cost statistics are ranked
/// against, and the ranking itself.
///
/// Lives outside the engine because the same statement — "yesterday was your
/// third-highest day in 22 weeks" — has to be answerable *per account*, and the
/// engine fits one series: its parameters, snapshot trail and self-evaluation
/// records all assume a single history. A rank over daily costs needs none of
/// that; it is arithmetic. Extracting it means the scoped answer and the
/// engine's answer are the same code rather than two implementations that agree
/// until they don't.
///
/// **Zero-filled, and that is load-bearing.** A day with no usage is a real
/// day you didn't spend on, so it counts in the denominator and pushes
/// yesterday up the ranking. Ranking only against days that *have* rows would
/// quietly say "third-highest in 22 weeks" while meaning "third of the 40 days
/// I happened to work".
public enum DailyBaseline {

    /// Every calendar day from the earliest tracked day up to (not including)
    /// today, in order, zero-filled.
    public static func priorDays(
        costsByDay: [String: Double], now: Date, calendar: Calendar
    ) -> [(day: Date, cost: Double)] {
        let todayKey = TokenSample.formatDate(now, timeZone: calendar.timeZone)
        guard let minKey = costsByDay.keys.filter({ $0 < todayKey }).min(),
              let start = EngineFeatures.parseDay(minKey, calendar: calendar) else { return [] }
        var out: [(day: Date, cost: Double)] = []
        var day = start
        while true {
            let key = TokenSample.formatDate(day, timeZone: calendar.timeZone)
            guard key < todayKey else { break }
            out.append((day, costsByDay[key] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    /// Yesterday's cost, its position from the top, and how many days it was
    /// ranked against. `nil` under a week of history — a "highest in 1w" claim
    /// is noise, not a notice.
    public static func yesterdayRank(
        baseline: [Double], minimumDays: Int = 7
    ) -> (cost: Double, rankFromTop: Int, of: Int)? {
        guard let yesterday = baseline.last, baseline.count >= minimumDays else { return nil }
        let higher = baseline.filter { $0 > yesterday }.count
        return (yesterday, higher + 1, baseline.count)
    }

    /// The whole answer from a set of daily rollup rows — what a scoped caller
    /// has on hand. Several rows share a date (one per model), so they are
    /// summed per day first.
    public static func yesterdayRank(
        rows: [DailyRow], now: Date = Date(), calendar: Calendar = .current
    ) -> (cost: Double, rankFromTop: Int, of: Int)? {
        var byDay: [String: Double] = [:]
        for row in rows { byDay[row.date, default: 0] += row.totalCostUSD }
        let prior = priorDays(costsByDay: byDay, now: now, calendar: calendar)
        return yesterdayRank(baseline: prior.map(\.cost))
    }
}
