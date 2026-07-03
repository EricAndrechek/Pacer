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

    // MARK: - Reset-aware segmentation (the 2026-06-20 global-reset shape)

    @Test func segmentTrimsCurrentCycleAtAnOffScheduleReset() throws {
        // One 7-day anchor (reset at hour 168). Usage climbs to ~17%, then an
        // off-schedule reset zeroes it WITHOUT moving the anchor, and it
        // re-climbs from 0 — the live shape Anthropic produced on 2026-06-20.
        let reset = at(168)
        var rows: [(at: Date, usedPercentage: Double, resetsAt: Date)] = []
        var h = 0.0
        while h <= 110 { rows.append((at(h), min(17, h * 0.16), reset)); h += 5 }   // → 17%
        h = 112
        while h <= 120 { rows.append((at(h), (h - 112) * 0.4, reset)); h += 1 }      // 0 → 3.2%
        let (current, history) = BurnTrajectory.segment(samples: rows, duration: 7 * 24 * 3600, now: at(120))
        #expect(history.isEmpty)                                  // single anchor → nothing completed
        let cur = try #require(current)
        // Only the post-reset tail survives, and it's monotone non-decreasing
        // (no fused 17%→0% drop left to distort the fit).
        #expect(cur.samples.first!.usedPercentage <= BurnTrajectory.resetLowMax)
        #expect(cur.usedNow <= 3.5)
        #expect(zip(cur.samples, cur.samples.dropFirst()).allSatisfy { $0.usedPercentage <= $1.usedPercentage + 1e-9 })
        // cycleStart re-anchored to the reset (~hour 110), not hour 0 (reset−7d),
        // so level/cut-fraction/slope all read "just reset", not "5 days in".
        #expect(cur.cycleStart >= at(105))
        #expect(cur.resetsAt == reset)
    }

    @Test func segmentTrimsACompletedContaminatedCycle() throws {
        // A completed cycle (anchor A) carries an off-schedule reset; a later
        // anchor B is the current cycle. The completed one must enter history
        // as its clean, monotone post-reset tail — not the fused non-monotone
        // cycle that would poison the backtest the engine learns from.
        let resetA = at(168), resetB = at(336)
        var rows: [(at: Date, usedPercentage: Double, resetsAt: Date)] = []
        var h = 0.0
        while h <= 100 { rows.append((at(h), min(20, h * 0.2), resetA)); h += 10 }   // → 20%
        h = 110
        while h <= 160 { rows.append((at(h), (h - 110) * 0.2, resetA)); h += 10 }     // 0 → 10%
        h = 170
        while h <= 320 { rows.append((at(h), (h - 170) * 0.1, resetB)); h += 10 }     // current cycle
        let (current, history) = BurnTrajectory.segment(samples: rows, duration: 7 * 24 * 3600, now: at(320))
        #expect(current != nil)
        #expect(history.count == 1)
        let completed = try #require(history.first)
        #expect(completed.samples.first!.usedPercentage <= BurnTrajectory.resetLowMax)
        #expect(zip(completed.samples, completed.samples.dropFirst()).allSatisfy { $0.usedPercentage <= $1.usedPercentage + 1e-9 })
        #expect(completed.resetsAt == resetA)
    }

    @Test func postResetStartIndexIgnoresMonotoneNoise() {
        // Small sub-threshold wobbles in an otherwise-climbing cycle never
        // count as a reset — only a real drop-to-near-zero does.
        let reset = at(5)
        let vals = [10.0, 12, 11, 30, 28, 55, 54, 80]
        let rows = vals.enumerated().map { (at(Double($0.offset) * 0.5), $0.element, reset) }
        #expect(BurnTrajectory.postResetStartIndex(rows) == 0)
    }

    // MARK: - Re-anchoring the projection onto the live tail

    /// A trajectory whose first point is the (stale) snapshot origin and which
    /// climbs linearly to `endValue` at `endHour`, `steps` samples apart.
    private func traj(originHour: Double, originValue: Double,
                      endHour: Double, endValue: Double, steps: Int = 4) -> BurnTrajectory.Trajectory {
        var pts: [BurnTrajectory.Sample] = []
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            pts.append(.init(at: at(originHour + (endHour - originHour) * f),
                             usedPercentage: originValue + (endValue - originValue) * f))
        }
        return .init(modelId: "t", points: pts, crossesFullAt: nil)
    }

    @Test func reanchorPinsOriginToLiveTailAndShiftsForward() {
        // Snapshot said 60% at hour 2; the live tail is 70% at hour 2.5.
        let t = traj(originHour: 2, originValue: 60, endHour: 5, endValue: 72)
        let r = t.reanchored(toTime: at(2.5), value: 70)
        // First rebased point IS the live tail — the join is exact.
        #expect(r.points.first!.at == at(2.5))
        #expect(abs(r.points.first!.usedPercentage - 70) < 1e-9)
        // Time shifted forward by +0.5 h; every sample stays at/after the tail.
        #expect(r.points.allSatisfy { $0.at >= at(2.5) })
        #expect(r.points.last!.at == at(5.5))
        // The slope (shape) is preserved: +12 pts overall ⇒ last ≈ 70+12, sub-cap.
        #expect(r.crossesFullAt == nil)
        #expect(abs(r.points.last!.usedPercentage - 82) < 1e-9)
    }

    @Test func reanchorRecomputesCrossingWhenLiftedOverCap() {
        // Snapshot never reached the cap (ends at 92%), but the live tail is
        // higher, so the lifted curve now crosses 100% — the marker must move
        // to the first rebased sample that reaches it.
        let t = traj(originHour: 2, originValue: 80, endHour: 5, endValue: 92)
        let r = t.reanchored(toTime: at(2), value: 88)   // +8 lift, no time shift
        #expect(r.crossesFullAt != nil)
        // Truncated at the crossing: the last point is exactly the cap.
        #expect(abs(r.points.last!.usedPercentage - 100) < 1e-9)
        #expect(r.points.last!.at == r.crossesFullAt)
        #expect(r.points.allSatisfy { $0.usedPercentage <= 100 + 1e-9 })
    }

    @Test func reanchorCollapsesAtTheCap() {
        // Live tail already at the cap ⇒ nothing to project: the trajectory
        // collapses to its origin so the chart draws no dashed line / dot.
        let t = traj(originHour: 2, originValue: 80, endHour: 5, endValue: 92)
        let r = t.reanchored(toTime: at(2.5), value: 100)
        #expect(r.points.count == 1)
        #expect(r.crossesFullAt == at(2.5))
    }

    @Test func reanchorTupleAndTrajectoryAgree() {
        // The widget path (tuple-based) and the app path (Trajectory) must
        // produce identical geometry.
        let t = traj(originHour: 1, originValue: 40, endHour: 5, endValue: 88)
        let viaTrajectory = t.reanchored(toTime: at(1.3), value: 55)
        let viaTuple = BurnTrajectory.reanchor(
            points: t.points.map { ($0.at, $0.usedPercentage) },
            toTime: at(1.3), value: 55)
        #expect(viaTrajectory.points.count == viaTuple.points.count)
        for (a, b) in zip(viaTrajectory.points, viaTuple.points) {
            #expect(a.at == b.at)
            #expect(abs(a.usedPercentage - b.value) < 1e-9)
        }
        #expect(viaTrajectory.crossesFullAt == viaTuple.crossesFullAt)
    }
}
