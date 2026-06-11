import Foundation
import Testing
@testable import PacerCore

@Suite("BurnTrajectory")
struct BurnTrajectoryTests {

    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private func at(_ hours: Double) -> Date { start.addingTimeInterval(hours * 3600) }

    /// A cycle of `duration` hours, sampled every `stepMin`, pct = f(hours).
    private func cycle(durationHours: Double, stepMin: Double = 15, _ f: (Double) -> Double) -> BurnTrajectory.Cycle {
        var samples: [BurnTrajectory.Sample] = []
        var h = 0.0
        while h <= durationHours + 1e-6 {
            samples.append(.init(at: at(h), usedPercentage: max(0, min(100, f(h)))))
            h += stepMin / 60
        }
        return .init(samples: samples, cycleStart: start, resetsAt: at(durationHours))
    }

    private func partial(_ c: BurnTrajectory.Cycle, throughHours: Double) -> BurnTrajectory.PartialCycle {
        .init(samples: c.samples, now: at(throughHours), cycleStart: c.cycleStart, resetsAt: c.resetsAt)
    }

    @Test func linearRecentRecoversTheSlope() throws {
        let c = cycle(durationHours: 5) { 10 + 15 * $0 }   // +15%/hr
        let p = partial(c, throughHours: 2.5)
        let project = try #require(BurnTrajectory.LinearRecent().fit(p))
        // 1 hour ahead → ~15% higher.
        let nowVal = project(at(2.5))
        let aheadVal = project(at(3.5))
        #expect(abs((aheadVal - nowVal) - 15) < 1.0)
    }

    @Test func saturatingFitsADeceleratingCurveBelowTheCap() throws {
        // Genuine saturation toward 80%: never reaches 100.
        let L = 80.0, k = 0.6
        let c = cycle(durationHours: 7 * 24, stepMin: 120) { L * (1 - exp(-k * $0 / 24)) }
        let p = partial(c, throughHours: 7 * 24 * 0.6)
        let project = try #require(BurnTrajectory.Saturating().fit(p))
        let atReset = project(c.resetsAt)
        #expect(atReset < 100)                 // saturating, not blowing past the cap
        #expect(atReset > 60)                  // but near its ceiling
    }

    @Test func bestTrajectorySpansNowToResetAndFlagsCrossing() throws {
        // Steep riser that crosses 100 before reset.
        let c = cycle(durationHours: 5) { 25 * $0 }     // hits 100 at h=4
        let history = (0..<4).map { _ in cycle(durationHours: 5) { 25 * $0 } }
        let p = partial(c, throughHours: 2.5)
        let traj = try #require(BurnTrajectory.bestTrajectory(current: p, history: history))

        #expect(traj.points.first?.at == at(2.5))
        #expect(abs(traj.points.last!.at.timeIntervalSince(c.resetsAt)) < 1)
        #expect(traj.points.allSatisfy { $0.usedPercentage >= 0 && $0.usedPercentage <= 100 })
        let crossing = try #require(traj.crossesFullAt)
        #expect(abs(crossing.timeIntervalSince(at(4))) < 3600)   // ~h=4
    }

    @Test func flatCycleProjectsNoCrossing() throws {
        let c = cycle(durationHours: 5) { _ in 40 }      // dead flat at 40%
        let history = (0..<4).map { _ in cycle(durationHours: 5) { _ in 40 } }
        let traj = try #require(BurnTrajectory.bestTrajectory(
            current: partial(c, throughHours: 3), history: history))
        #expect(traj.crossesFullAt == nil)
    }

    @Test func backtestSelectsTheModelThatTracksTheData() {
        // Linear cycles → a linear/recency fit should win (low error); the
        // selector should return a non-nil pick with enough cycles.
        let cycles = (0..<5).map { i in cycle(durationHours: 5) { 10 + (12 + Double(i)) * $0 } }
        let scores = BurnTrajectory.score(models: BurnTrajectory.defaultModels, cycles: cycles)
        let pick = ForecastSelector.select(scores: scores, policy: .init(minScoredCases: 6, minCoverage: 0.5))
        #expect(pick.id != nil)
        // The linear-family fits should score well under (low error) on linear data.
        let linear = scores.first { $0.id == "linear-recent" }!
        #expect(linear.medianAbsPctError < 10)
    }
}
