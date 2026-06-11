import Foundation
import Testing
@testable import PacerCore

@Suite("Forecast ensemble")
struct ForecastEnsembleTests {

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func day(_ ymd: String, _ h: Int = 0) -> Date {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        var dc = DateComponents(); dc.year = p[0]; dc.month = p[1]; dc.day = p[2]; dc.hour = h
        return utc.date(from: dc)!
    }

    /// Build a day's cumulative points from per-hour costs (cumulative at the
    /// end of each hour 0…23).
    private func cumulativePoints(dayStr: String, hourlyCosts: [Double]) -> [ForecastInput.Point] {
        var cum = 0.0
        return (0..<24).map { h in
            cum += hourlyCosts[h]
            return .init(at: day(dayStr, h).addingTimeInterval(3599), cumulative: cum)
        }
    }

    // A "daytime worker": all spend in hours 9–17, $10/hr → $90/day.
    private func daytimeDay(_ ymd: String) -> ForecastInput.PriorPeriod {
        let costs = (0..<24).map { (9...17).contains($0) ? 10.0 : 0.0 }
        return .init(start: day(ymd), points: cumulativePoints(dayStr: ymd, hourlyCosts: costs))
    }

    // MARK: - Forecasters

    @Test func averageRateIsClockLinearPace() throws {
        // Half the day elapsed, $30 so far → pace projects $60.
        let elapsed = cumulativePoints(dayStr: "2026-05-10", hourlyCosts: (0..<24).map { $0 < 12 ? 2.5 : 0 })
            .filter { $0.at <= day("2026-05-10", 12) }
        let input = ForecastInput(
            now: day("2026-05-10", 12), periodStart: day("2026-05-10"), periodEnd: day("2026-05-11"),
            calendar: utc, elapsed: elapsed, priorPeriods: [])
        let p = try #require(AverageRateForecaster().projectTotal(input))
        #expect(abs(p - 60) < 1.0)
    }

    @Test func hourOfDayShapeBeatsPaceOnATaperingDay() throws {
        // Prior history: daytime workers. Today mirrors it — $80 done by 6pm
        // of a ~$90 day. Pace (clock-linear) badly under/over-projects; the
        // shape knows the evening is quiet.
        let priors = (1...10).map { daytimeDay(String(format: "2026-05-%02d", $0)) }
        let todayCosts = (0..<24).map { (9...17).contains($0) ? 10.0 : 0.0 }
        let elapsed = cumulativePoints(dayStr: "2026-05-15", hourlyCosts: todayCosts)
            .filter { $0.at <= day("2026-05-15", 18) }
        let input = ForecastInput(
            now: day("2026-05-15", 18), periodStart: day("2026-05-15"), periodEnd: day("2026-05-16"),
            calendar: utc, elapsed: elapsed, priorPeriods: priors)

        let shape = try #require(HourOfDayShapeForecaster().projectTotal(input))
        let truth = 90.0
        #expect(abs(shape - truth) < 15)  // shape lands near the real total
    }

    @Test func forecasterReturnsNilWithoutEnoughSignal() {
        let input = ForecastInput(
            now: day("2026-05-10"), periodStart: day("2026-05-10"), periodEnd: day("2026-05-11"),
            calendar: utc, elapsed: [], priorPeriods: [])
        #expect(AverageRateForecaster().projectTotal(input) == nil)       // 0% elapsed
        #expect(RecencyWeightedSlopeForecaster().projectTotal(input) == nil) // no samples
        #expect(HourOfDayShapeForecaster().projectTotal(input) == nil)     // no priors
    }

    // MARK: - Backtester

    @Test func backtesterScoresOutOfSampleError() {
        // Two synthetic forecasters: one always exactly right, one always 50% high.
        struct Perfect: Forecaster { let id = "perfect"; let complexity = 0
            func projectTotal(_ i: ForecastInput) -> Double? { i.priorPeriods.first?.total } }
        struct Over: Forecaster { let id = "over"; let complexity = 0
            func projectTotal(_ i: ForecastInput) -> Double? { (i.priorPeriods.first?.total ?? 0) * 1.5 } }

        let prior = daytimeDay("2026-05-01")  // total 90
        let cases = (0..<10).map { _ in
            Backtester.Case(input: ForecastInput(
                now: day("2026-05-10", 12), periodStart: day("2026-05-10"), periodEnd: day("2026-05-11"),
                calendar: utc, elapsed: [], priorPeriods: [prior]), truth: 90)
        }
        let scores = Backtester.score(forecasters: [Perfect(), Over()], cases: cases)
        let perfect = scores.first { $0.id == "perfect" }!
        let over = scores.first { $0.id == "over" }!
        #expect(perfect.medianAbsPctError < 0.01)
        #expect(abs(over.medianAbsPctError - 50) < 0.01)
        #expect(perfect.coverage == 1.0)
    }

    // MARK: - Selector

    private func score(_ id: String, _ complexity: Int, _ err: Double, coverage: Double = 1, n: Int = 30) -> Backtester.Score {
        .init(id: id, complexity: complexity, medianAbsPctError: err, meanAbsPctError: err, coverage: coverage, scoredCount: n)
    }

    @Test func selectorPicksLowestErrorEligible() {
        let pick = ForecastSelector.select(scores: [
            score("a", 0, 30), score("b", 2, 18), score("c", 1, 25),
        ])
        #expect(pick.id == "b")
    }

    @Test func selectorPrefersSimplerWithinMargin() {
        // "simple" (complexity 0) is only 1 pt worse than "complex" → prefer simple.
        let pick = ForecastSelector.select(scores: [
            score("simple", 0, 19), score("complex", 3, 18),
        ])
        #expect(pick.id == "simple")
    }

    @Test func selectorHysteresisKeepsIncumbent() {
        // Challenger only 1 pt better than the incumbent (< 2-pt switch margin).
        let pick = ForecastSelector.select(
            scores: [score("incumbent", 1, 20), score("challenger", 1, 19)],
            incumbentId: "incumbent")
        #expect(pick.id == "incumbent")
        // But a decisive challenger does switch.
        let pick2 = ForecastSelector.select(
            scores: [score("incumbent", 1, 20), score("challenger", 1, 12)],
            incumbentId: "incumbent")
        #expect(pick2.id == "challenger")
    }

    @Test func selectorReturnsNilWithoutEnoughData() {
        let pick = ForecastSelector.select(scores: [score("a", 0, 10, coverage: 1, n: 3)])  // < minScoredCases
        #expect(pick.id == nil)
    }
}
