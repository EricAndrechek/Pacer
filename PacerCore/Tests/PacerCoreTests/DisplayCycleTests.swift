import Foundation
import Testing
@testable import PacerCore

@Suite struct DisplayCycleTests {

    /// A reset 2h ahead inside a 5h window → not awaiting, 3h elapsed,
    /// paceFraction = 0.6.
    @Test func activeMidCycle() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetsAt = now.addingTimeInterval(2 * 3600)
        let cycle = DisplayCycle.resolve(resetsAt: resetsAt, duration: 5 * 3600, now: now)
        #expect(!cycle.isAwaiting)
        #expect(cycle.resetsAt == resetsAt)
        #expect(cycle.cycleStart == resetsAt.addingTimeInterval(-5 * 3600))
        #expect(abs(cycle.paceFraction - 0.6) < 0.0001)
    }

    /// At cycle start (now == cycleStart) → paceFraction = 0.
    @Test func activeAtCycleStart() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetsAt = now.addingTimeInterval(5 * 3600)
        let cycle = DisplayCycle.resolve(resetsAt: resetsAt, duration: 5 * 3600, now: now)
        #expect(!cycle.isAwaiting)
        #expect(cycle.paceFraction == 0)
    }

    /// 1 minute before reset → paceFraction just under 1.
    @Test func activeNearCycleEnd() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetsAt = now.addingTimeInterval(60)
        let cycle = DisplayCycle.resolve(resetsAt: resetsAt, duration: 5 * 3600, now: now)
        #expect(!cycle.isAwaiting)
        #expect(cycle.paceFraction > 0.99)
        #expect(cycle.paceFraction < 1)
    }

    /// 1 minute past reset → awaiting, cycle rolled forward by one
    /// duration. paceFraction = 0 (the new cycle hasn't started
    /// accumulating from Pacer's perspective).
    @Test func awaitingJustAfterReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetsAt = now.addingTimeInterval(-60)
        let cycle = DisplayCycle.resolve(resetsAt: resetsAt, duration: 5 * 3600, now: now)
        #expect(cycle.isAwaiting)
        #expect(cycle.cycleStart == resetsAt)
        #expect(cycle.resetsAt == resetsAt.addingTimeInterval(5 * 3600))
        #expect(cycle.paceFraction == 0)
    }

    /// 16h past reset (the real-world scenario from #2/#3) → still
    /// awaiting; rollforward shape unchanged.
    @Test func awaitingHoursAfterReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetsAt = now.addingTimeInterval(-16 * 3600)
        let cycle = DisplayCycle.resolve(resetsAt: resetsAt, duration: 5 * 3600, now: now)
        #expect(cycle.isAwaiting)
        #expect(cycle.cycleStart == resetsAt)
        #expect(cycle.resetsAt == resetsAt.addingTimeInterval(5 * 3600))
    }

    /// Exact boundary (now == resetsAt) → awaiting. The prior cycle is
    /// done; the next instant belongs to the new cycle.
    @Test func boundaryExactlyAtReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cycle = DisplayCycle.resolve(resetsAt: now, duration: 5 * 3600, now: now)
        #expect(cycle.isAwaiting)
        #expect(cycle.cycleStart == now)
    }

    /// 7-day window, mid-cycle. Same math, different scale.
    @Test func sevenDayWindowActiveMidCycle() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetsAt = now.addingTimeInterval(4 * 86400)  // 4 days ahead, so 3 days elapsed
        let cycle = DisplayCycle.resolve(resetsAt: resetsAt, duration: 7 * 86400, now: now)
        #expect(!cycle.isAwaiting)
        #expect(abs(cycle.paceFraction - 3.0 / 7.0) < 0.0001)
    }
}
