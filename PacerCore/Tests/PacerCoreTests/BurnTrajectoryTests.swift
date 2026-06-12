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

    @Test func segmentSplitsCurrentCycleFromHistory() throws {
        // Three back-to-back 5h cycles resetting at 5h, 10h, 15h.
        var rows: [(at: Date, usedPercentage: Double, resetsAt: Date)] = []
        for c in 0..<3 {
            let reset = at(Double((c + 1) * 5))
            var h = Double(c * 5)
            while h < Double((c + 1) * 5) {
                rows.append((at(h), 10 + (h - Double(c * 5)) * 15, reset))
                h += 0.5
            }
        }
        let (current, history) = BurnTrajectory.segment(samples: rows, duration: 5 * 3600, now: at(13))
        #expect(history.count == 2)                           // first two cycles
        let cur = try #require(current)
        #expect(abs(cur.resetsAt.timeIntervalSince(at(15))) < 1) // latest reset is current
        #expect(cur.samples.allSatisfy { $0.at <= at(13) })   // only up to now
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
