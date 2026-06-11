import Foundation
import Testing
@testable import PacerCore

@Suite("Regime-gated EOD")
struct RegimeGatedEODTests {

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func day(_ ymd: String, _ h: Int = 0) -> Date {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        var dc = DateComponents(); dc.year = p[0]; dc.month = p[1]; dc.day = p[2]; dc.hour = h
        return utc.date(from: dc)!
    }

    /// A day's cumulative points from per-hour costs (cumulative at end of hour).
    private func dayPeriod(_ ymd: String, hourly: [Double]) -> ForecastInput.PriorPeriod {
        var cum = 0.0
        let pts = (0..<24).map { h -> ForecastInput.Point in
            cum += hourly[h]
            return .init(at: day(ymd, h).addingTimeInterval(3599), cumulative: cum)
        }
        return .init(start: day(ymd), points: pts)
    }

    private let frontLoaded = (0..<24).map { (6...11).contains($0) ? 15.0 : 0.0 }   // done by noon
    private let backLoaded  = (0..<24).map { (17...22).contains($0) ? 15.0 : 0.0 }   // starts after noon

    /// Build May 1–20, assigning a front-loaded shape to weekdays and a
    /// back-loaded shape to weekends (cost magnitudes equal; only the *shape*
    /// differs by regime).
    private func mixedMonth() -> [ForecastInput.PriorPeriod] {
        (1...20).map { d -> ForecastInput.PriorPeriod in
            let ymd = String(format: "2026-05-%02d", d)
            let regime = DayRegime.of(day(ymd), calendar: utc)
            return dayPeriod(ymd, hourly: regime == .weekday ? frontLoaded : backLoaded)
        }
    }

    @Test func profilesAreRegimeSplit() throws {
        let prof = try #require(RegimeGatedEOD().profiles(from: mixedMonth(), calendar: utc))
        // By noon, weekdays are ~done (front-loaded) while weekends have barely
        // started (back-loaded) — the profiles must capture that.
        let wd = prof.fraction[.weekday]![12]
        let we = prof.fraction[.weekend]![12]
        #expect(wd > 0.8)
        #expect(we < 0.2)
        #expect(wd - we > 0.5)
        // Both curves are monotone and end at 1.
        #expect(prof.fraction[.weekday]! == prof.fraction[.weekday]!.sorted())
        #expect(prof.fraction[.weekend]![23] == 1)
    }

    @Test func projectionGatesOnTodaysRegime() throws {
        let model = RegimeGatedEOD()
        let priors = mixedMonth()
        // Probe at hour 18, where both regime profiles are past minShapeFraction
        // (a noon weekend correctly declines — back-loaded weekends are ~0% done
        // by noon, too small a denominator to trust).
        let thu = "2026-05-21"   // Thursday — front-loaded, essentially done by 18.
        #expect(DayRegime.of(day(thu), calendar: utc) == .weekday)
        let wdInput = ForecastInput(now: day(thu, 18), periodStart: day(thu), periodEnd: day("2026-05-22"),
            calendar: utc, elapsed: [.init(at: day(thu, 18), cumulative: 90)], priorPeriods: priors)
        let wd = try #require(model.projection(wdInput))
        #expect(wd.regime == .weekday)
        #expect(wd.fraction > 0.8)
        #expect(abs(wd.point - 90) < 15)           // ≈ soFar — a front-loaded day is done

        // Saturday at 18, SAME $90 so far — a back-loaded weekend is only ~a third
        // done by then, so the same spend implies a much bigger day.
        let sat = "2026-05-23"
        #expect(DayRegime.of(day(sat), calendar: utc) == .weekend)
        let weInput = ForecastInput(now: day(sat, 18), periodStart: day(sat), periodEnd: day("2026-05-24"),
            calendar: utc, elapsed: [.init(at: day(sat, 18), cumulative: 90)], priorPeriods: priors)
        let we = try #require(model.projection(weInput))
        #expect(we.regime == .weekend)
        #expect(we.fraction < wd.fraction)
        #expect(we.point > wd.point)               // weekend projects higher from the same soFar
    }

    @Test func declinesWhenTooEarlyOrNoSpend() {
        let model = RegimeGatedEOD()
        let priors = mixedMonth()
        // soFar 0 → cannot multiplicatively scale.
        let zero = ForecastInput(now: day("2026-05-21", 12), periodStart: day("2026-05-21"), periodEnd: day("2026-05-22"),
            calendar: utc, elapsed: [.init(at: day("2026-05-21", 12), cumulative: 0)], priorPeriods: priors)
        #expect(model.projectTotal(zero) == nil)
        // No priors → no profile.
        let noHistory = ForecastInput(now: day("2026-05-21", 12), periodStart: day("2026-05-21"), periodEnd: day("2026-05-22"),
            calendar: utc, elapsed: [.init(at: day("2026-05-21", 12), cumulative: 30)], priorPeriods: [])
        #expect(model.projectTotal(noHistory) == nil)
    }

    @Test func estimateProducesCalibratedBand() throws {
        // Front-loaded weekdays with mild per-day noise so residuals aren't degenerate.
        let priors = (1...20).map { d -> ForecastInput.PriorPeriod in
            let ymd = String(format: "2026-05-%02d", d)
            let scale = 1.0 + Double((d % 3)) * 0.15
            let hourly = (0..<24).map { (6...11).contains($0) ? 15.0 * scale : 0.0 }
            return dayPeriod(ymd, hourly: hourly)
        }
        let cal = RegimeGatedEOD.calibrate(periods: priors, calendar: utc)
        #expect(cal.count > 10)

        let thu = "2026-05-21"
        let input = ForecastInput(now: day(thu, 11), periodStart: day(thu), periodEnd: day("2026-05-22"),
            calendar: utc, elapsed: [.init(at: day(thu, 11), cumulative: 60)], priorPeriods: priors)
        let est = RegimeGatedEOD().estimate(input, calibrator: cal)
        #expect(!est.isInsufficient)
        let band = try #require(est.interval80)
        #expect(band.lowerBound < band.upperBound)
        #expect(est.method == "regime-gated-eod")
        #expect(est.support == 20)
    }

    @Test func scoresLeakFreeThroughTheHarness() {
        // Plugs into the unified harness as a plain Forecaster; the harness builds
        // cases that only ever expose earlier days, so this is leak-free.
        let periods = mixedMonth()
        let cases = WalkForward.cases(
            periods: periods,
            periodEnd: { $0.start.addingTimeInterval(86400) },
            cutFractions: [0.5, 0.75],
            calendar: utc,
            regime: { DayRegime.of($0.periodStart, calendar: self.utc).rawValue })
        let scores = WalkForward.score(
            models: [RegimeGatedEOD(), AverageRateForecaster()], cases: cases)
        let mine = scores.filter { $0.modelId == "regime-gated-eod" }
        #expect(!mine.isEmpty)
        #expect(mine.contains { $0.n > 0 })        // it actually produced projections
        // Buckets are regime-tagged.
        #expect(scores.contains { $0.bucket.contains("weekday") })
    }
}
