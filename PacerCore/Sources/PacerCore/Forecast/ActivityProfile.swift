import Foundation

/// Empirical activity profiles — the "self-learning lite" shaping that makes
/// the end-of-day and monthly projections account for *when* the user
/// actually works, not just the current slope.
///
/// On real usage, the bare slope/acceleration estimator does **not** beat
/// Pacer's naive projections: spend is session-based (it tapers in the
/// evening) and weekly (weekends are quiet), and no derivative method knows
/// the day or week is winding down. What does beat naive is the user's own
/// rhythm, learned from history:
///
/// - **Hour-of-day shape** — the typical cumulative fraction of a day's
///   spend done by each hour ("you've usually done 80% by 6pm"). Scaling
///   `soFar` by this fraction projects the day's total without assuming the
///   current rate runs to midnight. On real data this cut the end-of-day
///   error tail (p90) from ~89% to ~70% — it kills the "multiplied a hot
///   afternoon across the whole evening" overshoot.
/// - **Day-of-week weights** — how heavy each weekday is relative to the
///   average ("Sundays are a third of a weekday"). Scaling the
///   remaining-days projection by these weights instead of a flat average
///   cut the mid-month error from ~59% to ~45%.
///
/// Pure and `Date`-free: it takes pre-bucketed history and a current
/// position, so it unit-tests like the rest of `Forecast/`. The caller owns
/// fetching `HourlyAggregate` / `DailyAggregate` and the calendar math.
public enum ActivityProfile {

    // MARK: - Hour-of-day shape (end-of-day cost)

    /// The typical cumulative fraction of a day's spend completed by the end
    /// of each hour 0…23. Monotonic non-decreasing, ending at 1.0.
    public struct DayShape: Equatable, Sendable {
        /// `fractionByHour[h]` = fraction of the day's total typically done
        /// by the end of hour `h`. `fractionByHour[23] == 1`.
        public let fractionByHour: [Double]
        /// Days that fed the shape (callers can gate on a confidence floor).
        public let dayCount: Int
    }

    /// Minimum days of history before a shape is trustworthy. Below this the
    /// caller should stick with its naive projection.
    public static let minDaysForShape = 5

    /// Learn the hour-of-day shape from a set of days, each a 24-element
    /// array of that day's per-hour cost. Days with no spend are skipped
    /// (they carry no shape). The shape is the mean per-day cumulative
    /// fraction across days — robust to the wildly different daily totals
    /// that a sum-of-costs profile would let the biggest days dominate.
    ///
    /// - Returns: nil when fewer than `minDaysForShape` non-empty days.
    public static func hourOfDayShape(days: [[Double]]) -> DayShape? {
        var sumFrac = [Double](repeating: 0, count: 24)
        var count = 0
        for day in days where day.count == 24 {
            let total = day.reduce(0, +)
            guard total > 0 else { continue }
            var cum = 0.0
            for h in 0..<24 { cum += day[h]; sumFrac[h] += cum / total }
            count += 1
        }
        guard count >= minDaysForShape else { return nil }
        var frac = sumFrac.map { $0 / Double(count) }
        // Enforce monotonicity + a clean 1.0 endpoint against float drift.
        for h in 1..<24 { frac[h] = max(frac[h], frac[h - 1]) }
        frac[23] = 1
        return DayShape(fractionByHour: frac, dayCount: count)
    }

    /// Smallest fraction-of-day we'll divide by. Early in the day the shape
    /// fraction is tiny and noisy, so `soFar / fraction` would explode; below
    /// this floor we lean entirely on the naive fallback via the blend.
    public static let minShapeFraction = 0.1

    /// Project the day's total cost from `soFar` (cumulative cost through the
    /// end of `throughHour`) using the learned `shape`, blended with the
    /// caller's `naive` projection.
    ///
    /// `profile = soFar / fractionDoneByHour`. The blend weights the profile
    /// by how much of the day has elapsed (`fraction`), so early in the day —
    /// when the profile is least certain — it defers to `naive`, and by
    /// evening it trusts the profile (which knows the day is nearly done).
    /// This blend is what tested best on real data (best error tail without
    /// giving up the median).
    public static func projectedEndOfDay(
        soFar: Double,
        throughHour: Int,
        shape: DayShape,
        naive: Double
    ) -> Double {
        guard (0...23).contains(throughHour) else { return naive }
        let fraction = shape.fractionByHour[throughHour]
        guard fraction >= minShapeFraction else { return naive }
        let profile = soFar / fraction
        let w = min(1, max(0, fraction))
        return w * profile + (1 - w) * naive
    }

    // MARK: - Day-of-week weights (monthly total)

    /// Per-weekday spend multipliers, normalized to mean 1 across the seven
    /// days. `weight[wd] == 1.5` means that weekday typically runs 50% above
    /// the daily average; `0.3` means a third of it.
    public struct WeekdayWeights: Equatable, Sendable {
        /// Keyed by `Calendar` weekday (1 = Sunday … 7 = Saturday), matching
        /// `Calendar.component(.weekday:)`. Always 7 entries.
        public let weightByWeekday: [Int: Double]
        /// Distinct calendar days that fed the weights.
        public let dayCount: Int

        public func weight(_ weekday: Int) -> Double { weightByWeekday[weekday] ?? 1 }
    }

    /// Minimum distinct calendar days before weekday weights are trustworthy
    /// (≈ two weeks, so every weekday is seen at least twice).
    public static let minDaysForWeekdayWeights = 14

    /// Learn weekday weights from a history of `(weekday, cost)` calendar
    /// days. **Include zero-cost days** (a quiet Sunday is signal, not a
    /// gap) so the weekend really reads as light. Weights are each weekday's
    /// mean cost divided by the grand mean, so they average to 1.
    ///
    /// - Returns: nil when fewer than `minDaysForWeekdayWeights` days, or the
    ///   history is entirely zero (no shape to learn).
    public static func weekdayWeights(days: [(weekday: Int, cost: Double)]) -> WeekdayWeights? {
        guard days.count >= minDaysForWeekdayWeights else { return nil }
        var sum = [Int: Double](), cnt = [Int: Double]()
        for d in days {
            sum[d.weekday, default: 0] += d.cost
            cnt[d.weekday, default: 0] += 1
        }
        let means: [Int: Double] = Dictionary(uniqueKeysWithValues: (1...7).map {
            ($0, (cnt[$0] ?? 0) > 0 ? (sum[$0] ?? 0) / cnt[$0]! : 0)
        })
        let grand = means.values.reduce(0, +) / 7
        guard grand > 0 else { return nil }
        let weights = Dictionary(uniqueKeysWithValues: means.map { ($0.key, $0.value / grand) })
        return WeekdayWeights(weightByWeekday: weights, dayCount: days.count)
    }

    /// Project the month's total by scaling `monthSoFar` from the weekday
    /// weight already elapsed to the weight remaining — instead of a flat
    /// daily average. `elapsedWeekdays` are the weekdays of the days already
    /// counted in `monthSoFar`; `remainingWeekdays` are the weekdays still to
    /// come. Falls back to `naive` when the elapsed weight is degenerate.
    public static func projectedMonthTotal(
        monthSoFar: Double,
        elapsedWeekdays: [Int],
        remainingWeekdays: [Int],
        weights: WeekdayWeights,
        naive: Double
    ) -> Double {
        let wElapsed = elapsedWeekdays.reduce(0.0) { $0 + weights.weight($1) }
        guard wElapsed > 0 else { return naive }
        let wRemaining = remainingWeekdays.reduce(0.0) { $0 + weights.weight($1) }
        return monthSoFar * (wElapsed + wRemaining) / wElapsed
    }
}
