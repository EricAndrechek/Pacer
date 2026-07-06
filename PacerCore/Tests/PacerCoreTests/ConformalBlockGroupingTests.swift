import Foundation
import Testing
@testable import PacerCore

/// Per-cycle block grouping in the stratified RL calibrators: with few
/// completed cycles, each cycle contributes ONE (median) residual per bucket
/// instead of one per cut — the honest effective sample size that fixed the
/// 7d bands' 12% realized coverage on an 80% claim.
@Suite("Conformal block grouping")
struct ConformalBlockGroupingTests {

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    static let base = utc.date(from: DateComponents(year: 2026, month: 6, day: 1))!

    /// `count` completed 5h-style cycles, linear 0→80% with 15-min sampling.
    private func cycles(_ count: Int) -> [BurnTrajectory.Cycle] {
        (0..<count).map { i in
            let start = Self.base.addingTimeInterval(Double(i) * 6 * 3600)
            let reset = start.addingTimeInterval(5 * 3600)
            var samples: [BurnTrajectory.Sample] = []
            var t = 0.0
            while t <= 5 * 3600 {
                samples.append(.init(at: start.addingTimeInterval(t),
                                     usedPercentage: 80 * t / (5 * 3600)))
                t += 15 * 60
            }
            return .init(samples: samples, cycleStart: start, resetsAt: reset)
        }
    }

    @Test func fewCyclesYieldOneResidualPerCyclePerBucket() {
        let history = cycles(10)   // 10 < conformalBlockMinCycles(40) → blocks
        let cals = UsageIntelligenceEngine.stratifiedRLCalibrators(
            model: BurnTrajectory.LinearRecent(), history: history,
            duration: 5 * 3600, calendar: Self.utc)
        let pooled = cals["pooled"]
        #expect(pooled != nil)
        // Per-cut counting would give ~10 cycles × 8 cuts = ~80 residuals;
        // block grouping must give exactly one per cycle.
        #expect(pooled?.count == 10)
    }

    @Test func manyCyclesKeepPerCutResiduals() {
        let history = cycles(45)   // 45 ≥ 40 → per-cut residuals resume
        let cals = UsageIntelligenceEngine.stratifiedRLCalibrators(
            model: BurnTrajectory.LinearRecent(), history: history,
            duration: 5 * 3600, calendar: Self.utc)
        let n = cals["pooled"]?.count ?? 0
        #expect(n > 45, "expected per-cut residuals (~45×8), got \(n)")
    }
}
