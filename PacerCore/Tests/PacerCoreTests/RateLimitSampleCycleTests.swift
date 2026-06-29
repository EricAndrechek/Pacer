import Foundation
import Testing
@testable import PacerCore

/// Cross-cycle straggler filtering for the pace charts. Reproduces the
/// real boundary leak captured on 2026-06-29: the 7-day window reset at
/// ~10:00:00 UTC while still reading 82% used, the new cycle anchored its
/// reset exactly one window later, and the previous cycle's final 82%
/// sample — taken 34ms *after* the new `cycleStart` — slipped past the
/// pure `sampledAt >= cycleStart` filter and drew a near-vertical red line
/// at the chart's left edge.
@Suite struct RateLimitSampleCycleTests {

    private static let sevenDays: TimeInterval = 7 * 86400

    private func sample(_ sampledAt: Date, used: Double, resets: Date?) -> RateLimitSample {
        RateLimitSample(
            sampledAt: sampledAt, window: "seven_day",
            usedPercentage: used, resetsAt: resets, source: "oauth"
        )
    }

    /// The exact production geometry: previous reset == new `cycleStart`,
    /// last old-cycle sample lands 34ms after it. `inCycle` must drop it.
    @Test func dropsBoundaryStragglerFromPreviousCycle() {
        let prevReset = Date(timeIntervalSince1970: 1_000_000)
        let curReset = prevReset.addingTimeInterval(Self.sevenDays) // exactly one window later
        // cycleStart of the current cycle is curReset - duration == prevReset.

        let straggler = sample(prevReset.addingTimeInterval(0.034), used: 82, resets: prevReset)
        let postResetIdle = sample(prevReset.addingTimeInterval(300), used: 0, resets: nil)
        let fresh = sample(prevReset.addingTimeInterval(3600), used: 5, resets: curReset)

        let kept = [straggler, postResetIdle, fresh]
            .inCycle(resetting: curReset, duration: Self.sevenDays)

        #expect(!kept.contains { $0.usedPercentage == 82 })   // straggler gone
        #expect(kept.contains { $0.resetsAt == nil })          // post-reset 0% kept
        #expect(kept.contains { $0.usedPercentage == 5 })      // current sample kept
        #expect(kept.count == 2)
    }

    /// Sub-second `resets_at` jitter within the *same* cycle must never
    /// drop a legitimately in-cycle sample.
    @Test func keepsSameCycleDespiteJitter() {
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let jittered = sample(reset.addingTimeInterval(-3600), used: 40, resets: reset.addingTimeInterval(-0.8))
        let exact = sample(reset.addingTimeInterval(-1800), used: 45, resets: reset)

        let kept = [jittered, exact].inCycle(resetting: reset, duration: Self.sevenDays)
        #expect(kept.count == 2)
    }

    /// A neighbouring cycle that reset more than one window earlier (an
    /// idle gap) is excluded just the same.
    @Test func dropsDistantNeighbourCycle() {
        let curReset = Date(timeIntervalSince1970: 3_000_000)
        let old = sample(curReset.addingTimeInterval(-9 * 86400), used: 90,
                         resets: curReset.addingTimeInterval(-8 * 86400))
        let cur = sample(curReset.addingTimeInterval(-3600), used: 30, resets: curReset)

        let kept = [old, cur].inCycle(resetting: curReset, duration: Self.sevenDays)
        #expect(kept.count == 1)
        #expect(kept.first?.usedPercentage == 30)
    }
}
