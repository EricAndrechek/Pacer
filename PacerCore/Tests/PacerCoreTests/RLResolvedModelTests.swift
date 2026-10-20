import Foundation
import Testing
@testable import PacerCore

/// One resolved model per window per refit (#301): when the selected model
/// declines the live cycle, every surface shows the same stand-in.
@Suite("Rate-limit resolved model")
struct RLResolvedModelTests {

    static let utc = Calendar(identifier: .gregorian).with(timeZone: TimeZone(identifier: "UTC")!)
    static let now = Date(timeIntervalSince1970: 1_752_000_000)
    static let week: TimeInterval = 7 * 24 * 3600

    /// Four completed 7-day cycles of steady burn, then a live one three hours
    /// past its reset at 3% used: under 5% of the cycle's expected activity has
    /// happened, so the diurnal model declines (`DiurnalBurnModel.minObservedShare`)
    /// while the simpler ones fit.
    static func features() -> EngineFeatures {
        var rate: [EngineFeatures.RateRow] = []
        let liveStart = now.addingTimeInterval(-3 * 3600)
        for c in 0..<4 {
            let start = liveStart.addingTimeInterval(-Double(4 - c) * week)
            let reset = start.addingTimeInterval(week)
            var t = start, pct = 0.0
            while t <= reset {
                rate.append(.init(window: "seven_day", at: t, usedPercentage: min(70, pct), resetsAt: reset))
                t = t.addingTimeInterval(6 * 3600); pct += 2.5
            }
        }
        let liveReset = liveStart.addingTimeInterval(week)
        for k in 0...6 {
            rate.append(.init(window: "seven_day", at: liveStart.addingTimeInterval(Double(k) * 1800),
                              usedPercentage: Double(k) * 0.5, resetsAt: liveReset))
        }
        return EngineFeatures.build(now: now, calendar: utc, daily: [], hourly: [], rate: rate, lastArrivalAt: nil)
    }

    @Test func aDeclinedSelectionFallsBackTheSameWayEverywhere() throws {
        let f = Self.features()
        let fit = UsageIntelligenceEngine.makeFit(f, rlSelection: ["seven_day": "diurnal-rate"])
        let rf = try #require(fit.rl["seven_day"])
        #expect(rf.selectedId == "diurnal-rate")
        let resolved = try #require(rf.resolvedId)
        #expect(resolved != "diurnal-rate")                 // it declined this cycle
        #expect(rf.replacedId == "diurnal-rate")

        let outlook = try #require(UsageIntelligenceEngine.burnOutlook(f, fit, windowKey: "seven_day"))
        #expect(outlook.method == resolved)                  // was "none"
        let est = UsageIntelligenceEngine.answer(.rateLimitOutlook(.sevenDay), features: f, fit: fit)
        #expect(!est.isInsufficient)                         // was "too early in the cycle to project"
        #expect(est.method == "rl-\(resolved)")
        let drawn = UsageIntelligenceEngine.rateLimitTrajectories(f, fit, windowKey: "seven_day", accuracy: nil)
            .filter(\.isSelected)
        #expect(drawn.map(\.modelId) == [resolved])          // the chart draws the same one

        let trail = try #require(UsageIntelligenceEngine.snapshotDrafts(f, fit)
            .first { $0.surface == EngineSelfEval.rlSurface("seven_day") })
        #expect(trail.method == resolved)
        #expect(trail.replacedMethod == "diurnal-rate")
    }

    @Test func aFittingSelectionIsShownAsIs() throws {
        let f = Self.features()
        let fit = UsageIntelligenceEngine.makeFit(f, rlSelection: ["seven_day": "linear-recent"])
        let rf = try #require(fit.rl["seven_day"])
        #expect(rf.resolvedId == "linear-recent")
        #expect(rf.replacedId == nil)
    }

    @Test func aStandInIsTheBestRecordedModelThatFits() throws {
        let f = Self.features()
        // kalman-trend has the best record on only 3 cycles; with no separate
        // floor for newer models, the record decides.
        func stat(_ id: String, _ err: Double, _ periods: Int) -> EngineSelfEval.Accuracy.MethodStat {
            .init(method: id, medianAbsPctError: err, typicalAbsError: err, periods: periods)
        }
        let acc = EngineSelfEval.Accuracy(surface: "rl-seven_day", methods: [
            stat("kalman-trend", 0.5, 3), stat("saturating", 2, 10), stat("linear-recent", 4, 10),
        ])
        let fit = UsageIntelligenceEngine.makeFit(f, rlSelection: ["seven_day": "diurnal-rate"],
                                                  rlAccuracy: ["seven_day": acc])
        #expect(fit.rl["seven_day"]?.resolvedId == "kalman-trend")
    }
}

private extension Calendar {
    func with(timeZone: TimeZone) -> Calendar { var c = self; c.timeZone = timeZone; return c }
}
