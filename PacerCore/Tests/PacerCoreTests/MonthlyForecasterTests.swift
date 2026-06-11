import Foundation
import Testing
@testable import PacerCore

@Suite("Monthly forecast candidate")
struct MonthlyForecasterTests {

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        var dc = DateComponents(); dc.year = y; dc.month = m; dc.day = d; dc.hour = h
        return utc.date(from: dc)!
    }

    /// A month as daily cumulative points, cost per day from `dailyCost(weekday)`.
    private func month(_ y: Int, _ m: Int, dailyCost: (Int) -> Double) -> ForecastInput.PriorPeriod {
        let start = date(y, m, 1)
        let dim = utc.range(of: .day, in: .month, for: start)!.count
        var cum = 0.0
        let points = (1...dim).map { d -> ForecastInput.Point in
            let dt = date(y, m, d, 12)
            cum += dailyCost(utc.component(.weekday, from: dt))
            return .init(at: dt, cumulative: cum)
        }
        return .init(start: start, points: points)
    }

    // Heavy weekdays (Mon–Fri = 2…6), light weekends (1, 7).
    private func heavyWeekdays(_ wd: Int) -> Double { (2...6).contains(wd) ? 100 : 10 }

    private func currentMonthInput(throughDay: Int) -> ForecastInput {
        let priors = [month(2026, 4, dailyCost: heavyWeekdays), month(2026, 5, dailyCost: heavyWeekdays)]
        var cum = 0.0
        let elapsed = (1...throughDay).map { d -> ForecastInput.Point in
            cum += heavyWeekdays(utc.component(.weekday, from: date(2026, 6, d, 12)))
            return .init(at: date(2026, 6, d, 12), cumulative: cum)
        }
        return ForecastInput(
            now: date(2026, 6, throughDay, 18), periodStart: date(2026, 6, 1), periodEnd: date(2026, 7, 1),
            calendar: utc, elapsed: elapsed, priorPeriods: priors)
    }

    @Test func weekdayWeightsProjectsAndReshapesVsPace() throws {
        let input = currentMonthInput(throughDay: 12)
        let weekday = try #require(WeekdayWeightsForecaster().projectTotal(input))
        let pace = try #require(AverageRateForecaster().projectTotal(input))

        #expect(weekday > input.soFar)        // still growing
        #expect(weekday.isFinite)
        #expect(abs(weekday - pace) > 1e-6)    // genuinely reshapes the projection
    }

    @Test func weekdayWeightsNeedsPriorMonths() {
        let input = ForecastInput(
            now: date(2026, 6, 12, 18), periodStart: date(2026, 6, 1), periodEnd: date(2026, 7, 1),
            calendar: utc, elapsed: [.init(at: date(2026, 6, 1, 12), cumulative: 100)], priorPeriods: [])
        #expect(WeekdayWeightsForecaster().projectTotal(input) == nil)
    }

    @Test func rostersExposeTheExpectedCandidates() {
        #expect(Set(ForecastRoster.endOfDay().map(\.id)) ==
                ["average-rate", "recent-rate", "recency-slope", "hour-of-day-shape"])
        #expect(Set(ForecastRoster.monthly().map(\.id)) ==
                ["average-rate", "recency-slope", "weekday-weights"])
    }
}
