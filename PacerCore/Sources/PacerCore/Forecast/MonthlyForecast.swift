import Foundation

/// Project a calendar month's total cost from the days observed so far.
/// Simple-average extrapolation — same shape Claude God uses (`:632-649`),
/// same shape ccusage's monthly forecasts use. Conservative enough to
/// stay readable; precise enough to catch "I'm on track to blow my
/// budget this month."
public enum MonthlyForecast {

    /// Computed result. All non-optional so views can render without
    /// branching once `compute` returns non-nil; the function returns
    /// nil only when there isn't enough signal to project.
    public struct Projection: Equatable, Sendable {
        /// Days in the current month that had ANY cost data. A vacation
        /// day with $0 spent doesn't count (otherwise a week off
        /// drags the average down and a workday spike doesn't show).
        public let daysWithData: Int
        /// Sum across `daysWithData` divided by `daysWithData`.
        public let averageDailyCost: Double
        /// Calendar days in this month (28..31).
        public let daysInMonth: Int
        /// 1-indexed day-of-month for "today" relative to the user's
        /// local calendar.
        public let dayOfMonth: Int
        /// Total cost recorded so far this month — sum across every
        /// day in the input set, whether it had data or not.
        public let monthSoFar: Double
        /// Projected total: `monthSoFar + averageDailyCost × daysRemaining`.
        /// Days-remaining count includes today only if today is a
        /// not-yet-completed day (`dayOfMonth < daysInMonth`); on the
        /// last day of the month the projection collapses to
        /// `monthSoFar`.
        public let projectedMonthTotal: Double
    }

    /// Minimum days-with-data before we'll publish a projection. With
    /// only one day's data the variance is too high to be useful.
    /// Claude God uses 3; we match.
    public static let minDaysWithData = 3

    /// Compute a projection from a series of (date, cost) pairs and a
    /// reference "today" used for current-month boundaries. The caller
    /// owns date arithmetic (which calendar, which timezone) — pass
    /// pairs whose date strings sort lexicographically (`YYYY-MM-DD`).
    ///
    /// - Parameters:
    ///   - dailyCosts: total cost per `YYYY-MM-DD` date string. ONLY
    ///     dates within the current month are considered; outside-month
    ///     entries are silently ignored so callers can pass a 30-day
    ///     window without filtering it.
    ///   - now: reference "today" — defaults to `Date()`. Tests pin
    ///     this so the month boundary is deterministic.
    ///   - calendar: defaults to `.current`; tests inject UTC for
    ///     timezone-stable assertions.
    ///   - weekdayWeights: optional empirical day-of-week profile. When
    ///     supplied, `projectedMonthTotal` is shaped by scaling
    ///     month-so-far across the remaining days' weekday weights instead
    ///     of a flat daily average — so a month with a heavy-weekday stretch
    ///     elapsed and quiet weekends remaining doesn't over-project. `nil`
    ///     keeps the flat-average projection. (On real data the day-of-week
    ///     shaping cut mid-month error materially; see `ActivityProfile`.)
    /// - Returns: nil if `daysWithData < minDaysWithData` or the
    ///   month-of-now is unparseable.
    public static func compute(
        dailyCosts: [String: Double],
        now: Date = Date(),
        calendar: Calendar = .current,
        weekdayWeights: ActivityProfile.WeekdayWeights? = nil
    ) -> Projection? {
        let monthPrefix = monthPrefix(of: now, calendar: calendar)
        // Filter to the current month and skip $0 days (so a long
        // vacation doesn't dilute the average).
        var perDay: [String: Double] = [:]
        for (date, cost) in dailyCosts where date.hasPrefix(monthPrefix) {
            perDay[date, default: 0] += cost
        }
        let activeCosts = perDay.values.filter { $0 > 0 }
        guard activeCosts.count >= minDaysWithData else { return nil }

        let monthSoFar = perDay.values.reduce(0, +)
        let averageDailyCost = activeCosts.reduce(0, +) / Double(activeCosts.count)

        let dayOfMonth = calendar.component(.day, from: now)
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        // "Days remaining" excludes today itself — if a day has any
        // cost it's already accounted for in `monthSoFar` and double-
        // counting at the daily rate would over-project. The last day
        // of the month collapses to 0 remaining.
        let daysRemaining = max(0, daysInMonth - dayOfMonth)

        // Flat-average projection (the baseline). When a weekday profile is
        // supplied, reshape it so the remaining days are weighted by their
        // weekday instead of all counting the same.
        var projectedTotal = monthSoFar + averageDailyCost * Double(daysRemaining)
        if let weights = weekdayWeights {
            let year = calendar.component(.year, from: now)
            let month = calendar.component(.month, from: now)
            let weekday: (Int) -> Int = { day in
                var dc = DateComponents()
                dc.year = year; dc.month = month; dc.day = day
                guard let date = calendar.date(from: dc) else { return 1 }
                return calendar.component(.weekday, from: date)
            }
            let elapsed = (1...dayOfMonth).map(weekday)
            let remaining = dayOfMonth < daysInMonth
                ? Array((dayOfMonth + 1)...daysInMonth).map(weekday)
                : []
            projectedTotal = ActivityProfile.projectedMonthTotal(
                monthSoFar: monthSoFar,
                elapsedWeekdays: elapsed,
                remainingWeekdays: remaining,
                weights: weights,
                naive: projectedTotal
            )
        }

        return Projection(
            daysWithData: activeCosts.count,
            averageDailyCost: averageDailyCost,
            daysInMonth: daysInMonth,
            dayOfMonth: dayOfMonth,
            monthSoFar: monthSoFar,
            projectedMonthTotal: projectedTotal
        )
    }

    /// `YYYY-MM-` prefix for the given date in the supplied calendar.
    /// Mirrors `TokenSample.formatDate`'s separator so the prefix
    /// `.hasPrefix` test matches.
    static func monthPrefix(of date: Date, calendar: Calendar) -> String {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        return String(format: "%04d-%02d-", year, month)
    }
}
