import Foundation

/// Day-of-week candidate for the **monthly** surface: scale month-so-far by
/// the remaining days' weekday weights instead of a flat average, so a heavy
/// weekday stretch elapsed with quiet weekends remaining doesn't over-project.
/// Reuses the tested `ActivityProfile`; the shipped monthly method, now a
/// tournament candidate.
///
/// The period-agnostic candidates (`AverageRateForecaster`,
/// `RecencyWeightedSlopeForecaster`, the ML `RegressorForecaster`) work on the
/// monthly surface unchanged — only this weekday method and the EOD
/// hour-of-day method are surface-specific.
public struct WeekdayWeightsForecaster: Forecaster {
    public let id = "weekday-weights"
    public let complexity = 2
    public init() {}

    public func projectTotal(_ input: ForecastInput) -> Double? {
        // (weekday, cost) for every day across the prior complete months,
        // including zero-cost days (a quiet weekend is signal, not a gap) —
        // recovered by differencing each prior's daily cumulative series.
        var dayCosts: [(weekday: Int, cost: Double)] = []
        for prior in input.priorPeriods {
            var previous = 0.0
            for point in prior.points.sorted(by: { $0.at < $1.at }) {
                let cost = max(0, point.cumulative - previous)
                previous = point.cumulative
                dayCosts.append((weekday: input.calendar.component(.weekday, from: point.at), cost: cost))
            }
        }
        guard let weights = ActivityProfile.weekdayWeights(days: dayCosts) else { return nil }

        // Weekdays of the current month's elapsed vs remaining days. The day
        // containing `now` counts as elapsed (its spend is in soFar), matching
        // MonthlyForecast.
        var elapsed: [Int] = []
        var remaining: [Int] = []
        let nowDay = input.calendar.startOfDay(for: input.now)
        var day = input.calendar.startOfDay(for: input.periodStart)
        while day < input.periodEnd {
            let weekday = input.calendar.component(.weekday, from: day)
            if day <= nowDay { elapsed.append(weekday) } else { remaining.append(weekday) }
            guard let next = input.calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        guard !elapsed.isEmpty else { return nil }

        let naive = input.elapsedFraction > 0.02 ? input.soFar / input.elapsedFraction : input.soFar
        return ActivityProfile.projectedMonthTotal(
            monthSoFar: input.soFar,
            elapsedWeekdays: elapsed,
            remainingWeekdays: remaining,
            weights: weights,
            naive: naive
        )
    }
}

/// Canonical candidate rosters per surface. The period-agnostic methods appear
/// in both; the shape methods are surface-specific. The ML candidate is added
/// separately by the caller (it needs a trained predictor).
public enum ForecastRoster {
    /// End-of-day cost candidates.
    public static func endOfDay() -> [any Forecaster] {
        [
            AverageRateForecaster(),
            RecentRateForecaster(),
            RecencyWeightedSlopeForecaster(),
            HourOfDayShapeForecaster(),
        ]
    }

    /// Monthly total candidates.
    public static func monthly() -> [any Forecaster] {
        [
            AverageRateForecaster(),
            RecencyWeightedSlopeForecaster(),
            WeekdayWeightsForecaster(),
        ]
    }
}
