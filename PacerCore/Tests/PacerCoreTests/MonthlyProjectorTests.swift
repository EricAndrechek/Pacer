import Foundation
import Testing
@testable import PacerCore

@Suite("Monthly projector")
struct MonthlyProjectorTests {

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var dc = DateComponents(); dc.year = y; dc.month = m; dc.day = d; dc.hour = h
        return utc.date(from: dc)!
    }
    private func key(_ d: Date) -> String { TokenSample.formatDate(d, timeZone: utc.timeZone) }

    /// Daily costs from 2026-04-01 through the day before `now`, cost per day from
    /// `cost(weekday)` (1=Sun…7=Sat). Includes "today" partial up to `now`.
    private func series(through now: Date, cost: @escaping (Int) -> Double) -> [String: Double] {
        var out: [String: Double] = [:]
        var d = date(2026, 4, 1)
        while d <= now {
            out[key(d)] = cost(utc.component(.weekday, from: d))
            d = utc.date(byAdding: .day, value: 1, to: d)!
        }
        return out
    }

    @Test func fallsBackToFlatWhenIneligible() {
        // Only the current month, no prior months → seasonal model ineligible.
        let now = date(2026, 6, 10)
        var costs: [String: Double] = [:]
        for d in 1...9 { costs[key(date(2026, 6, d))] = 100 }
        let est = MonthlyProjector.project(dailyCosts: costs, now: now, calendar: utc)
        #expect(est.method == "monthly-flat")
        #expect(est.confidence == .low)
        #expect(est.value > 0)
    }

    @Test func eligibleUsesDailySumAndProjectsForward() {
        let now = date(2026, 6, 15)
        // Heavy weekdays ($200), light weekends ($40) — plenty of history.
        let costs = series(through: now) { ($0 == 1 || $0 == 7) ? 40 : 200 }
        let est = MonthlyProjector.project(dailyCosts: costs, now: now, calendar: utc)
        #expect(est.method == "monthly-daily-sum")
        #expect(est.support >= 20)
        // Projected month exceeds month-so-far and is finite, with a band.
        let observed = (1...15).reduce(0.0) { $0 + (costs[key(date(2026, 6, $1))] ?? 0) }
        #expect(est.value > observed)
        #expect(est.interval80 != nil)
        #expect(est.value.isFinite)
    }

    @Test func weakWeekdaySignalCollapsesTowardFlat() {
        // Uniform daily cost → no weekday signal → EB shrinks weekday means to the
        // global mean, so the projection ≈ the flat-average projection.
        let now = date(2026, 6, 15)
        let costs = series(through: now) { _ in 100 }
        let est = MonthlyProjector.project(dailyCosts: costs, now: now, calendar: utc)
        let flat = MonthlyForecast.compute(dailyCosts: costs, now: now, calendar: utc)!
        #expect(est.method == "monthly-daily-sum")
        #expect(abs(est.value - flat.projectedMonthTotal) / flat.projectedMonthTotal < 0.05)
    }

    @Test func projectionStaysAtLeastMonthSoFar() {
        let now = date(2026, 6, 28)   // late in the month
        // Per-day jitter so the within-weekday variance (and thus the band) is real.
        var costs: [String: Double] = [:]
        var d = date(2026, 4, 1)
        var i = 0
        while d <= now {
            let wd = utc.component(.weekday, from: d)
            let base = (wd == 1 || wd == 7) ? 40.0 : 200.0
            costs[key(d)] = base * (1 + Double(i % 5) * 0.1)
            d = utc.date(byAdding: .day, value: 1, to: d)!; i += 1
        }
        let est = MonthlyProjector.project(dailyCosts: costs, now: now, calendar: utc)
        let observed = (1...28).reduce(0.0) { $0 + (costs[key(date(2026, 6, $1))] ?? 0) }
        #expect(est.value >= observed - 1e-6)
        let band = try! #require(est.interval80)
        #expect(band.lowerBound >= observed - 1e-6)   // band floored at spent
    }
}
