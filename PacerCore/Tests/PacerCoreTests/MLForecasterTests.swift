import Foundation
import Testing
@testable import PacerCore

@Suite("ML forecast candidate")
struct MLForecasterTests {

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func day(_ ymd: String, _ h: Int = 0) -> Date {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        var dc = DateComponents(); dc.year = p[0]; dc.month = p[1]; dc.day = p[2]; dc.hour = h
        return utc.date(from: dc)!
    }
    private func cumulativePoints(_ ymd: String, hourly: [Double]) -> [ForecastInput.Point] {
        var cum = 0.0
        return (0..<24).map { h in cum += hourly[h]; return .init(at: day(ymd, h).addingTimeInterval(3599), cumulative: cum) }
    }
    private func daytime(_ ymd: String) -> ForecastInput.PriorPeriod {
        .init(start: day(ymd), points: cumulativePoints(ymd, hourly: (0..<24).map { (9...17).contains($0) ? 10 : 0 }))
    }

    // MARK: - Featurization (pure)

    @Test func featuresCoverTheNamedKeys() {
        let input = ForecastInput(
            now: day("2026-05-15", 12), periodStart: day("2026-05-15"), periodEnd: day("2026-05-16"),
            calendar: utc, elapsed: cumulativePoints("2026-05-15", hourly: (0..<24).map { $0 < 12 ? 5 : 0 }).filter { $0.at <= day("2026-05-15", 12) },
            priorPeriods: [])
        let f = MLFeatures.features(for: input)
        for key in MLFeatures.featureKeys { #expect(f[key] != nil) }
        #expect(f["hourOfDay"] == 12)
        #expect(abs(f["elapsedFraction"]! - 0.5) < 0.01)
        #expect(f["soFar"]! > 0)
    }

    @Test func trainingRowsReplayEachPriorAtCutPoints() {
        let priors = (1...4).map { daytime(String(format: "2026-05-%02d", $0)) }
        let rows = MLFeatures.trainingRows(from: priors, periodLength: 86400, cutFractions: [0.3, 0.6, 0.9], calendar: utc)
        #expect(rows.count == 12)                 // 4 priors × 3 cuts
        for r in rows { #expect(abs(r.target - 90) < 0.01) }  // each daytime day totals $90
    }

    // MARK: - RegressorForecaster (pure, stubbed predictor)

    @Test func regressorForecasterCallsPredictorAndClampsToSoFar() throws {
        let elapsed = cumulativePoints("2026-05-15", hourly: (0..<24).map { (9...17).contains($0) ? 10 : 0 })
            .filter { $0.at <= day("2026-05-15", 15) }
        let input = ForecastInput(
            now: day("2026-05-15", 15), periodStart: day("2026-05-15"), periodEnd: day("2026-05-16"),
            calendar: utc, elapsed: elapsed, priorPeriods: [])

        // Stub returns the soFar feature × 1.1.
        let f = RegressorForecaster { feats in (feats["soFar"] ?? 0) * 1.1 }
        let p = try #require(f.projectTotal(input))
        #expect(abs(p - input.soFar * 1.1) < 1e-6)

        // A predictor that lowballs below soFar gets clamped up to soFar.
        let low = RegressorForecaster { _ in 1.0 }
        #expect(low.projectTotal(input) == input.soFar)

        // nil predictor → nil projection.
        let none = RegressorForecaster { _ in nil }
        #expect(none.projectTotal(input) == nil)
    }

    // MARK: - End-to-end on-device training (Create ML)

    #if canImport(CreateML)
    @Test func createMLTrainerLearnsAndPredicts() throws {
        // Learnable signal: total = soFar / elapsedFraction (pure pace). The
        // tree should recover roughly that from enough replayed rows.
        var priors: [ForecastInput.PriorPeriod] = []
        for d in 1...20 {
            let perHour = Double(d)   // varies the daily total across days
            let hourly = (0..<24).map { (9...17).contains($0) ? perHour : 0 }
            priors.append(.init(start: day(String(format: "2026-05-%02d", d)),
                                points: cumulativePoints(String(format: "2026-05-%02d", d), hourly: hourly)))
        }
        let rows = MLFeatures.trainingRows(from: priors, periodLength: 86400, calendar: utc)
        let predictor = try #require(CreateMLTrainer.trainedPredictor(rows: rows))

        // New day at $X by 6pm of a daytime pattern → should predict near the
        // day's true total, comfortably above soFar.
        let testHourly = (0..<24).map { (9...17).contains($0) ? 12.0 : 0.0 }  // $108/day
        let elapsed = cumulativePoints("2026-06-01", hourly: testHourly).filter { $0.at <= day("2026-06-01", 18) }
        let input = ForecastInput(
            now: day("2026-06-01", 18), periodStart: day("2026-06-01"), periodEnd: day("2026-06-02"),
            calendar: utc, elapsed: elapsed, priorPeriods: priors)
        let forecaster = RegressorForecaster(predict: predictor)
        let projection = try #require(forecaster.projectTotal(input))
        #expect(projection >= input.soFar)        // never below spend-so-far
        #expect(projection > 80 && projection < 140) // in the neighbourhood of $108
    }
    #endif
}
