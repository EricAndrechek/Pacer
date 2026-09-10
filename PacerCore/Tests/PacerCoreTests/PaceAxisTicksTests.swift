import Foundation
import Testing
@testable import PacerUI

/// The 5-hour column read `9|` instead of `9p` in every render of the pace
/// card — reported twice before it was fixed, because nothing but looking at
/// the chart can see it.
@Suite("Pace chart axis ticks")
struct PaceAxisTicksTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func ticks(cycleStart: Date, duration: TimeInterval) -> [Date] {
        PaceChartView.axisTicks(cycleStart: cycleStart,
                                resetsAt: cycleStart.addingTimeInterval(duration),
                                durationSeconds: duration, calendar: calendar)
    }

    /// A cycle resetting at 21:09 puts an hourly tick at 21:00, nine minutes
    /// from the right edge — and the label is leading-aligned, so it runs off
    /// the plot.
    @Test func aTickMinutesFromTheResetIsDropped() {
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 4, hour: 16, minute: 9))!
        let duration: TimeInterval = 5 * 3600          // resets 21:09
        let kept = ticks(cycleStart: start, duration: duration)
        #expect(!kept.contains { calendar.component(.hour, from: $0) == 21 })
        #expect(kept.map { calendar.component(.hour, from: $0) } == [17, 18, 19, 20])
    }

    /// The interior ticks are untouched — this drops one label, it does not
    /// thin the axis.
    @Test func interiorTicksAreKept() {
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 4, hour: 16, minute: 0))!
        let kept = ticks(cycleStart: start, duration: 5 * 3600)
        // 17:00, 18:00, 19:00, 20:00 — 21:00 is the reset itself.
        #expect(kept.count == 4)
    }

    /// The 7-day axis marks midnights and is centred, so the rule is a no-op
    /// there unless a midnight lands right against the reset.
    @Test func theLongCycleKeepsItsMidnights() {
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 1, hour: 6, minute: 0))!
        let kept = ticks(cycleStart: start, duration: 7 * 86_400)
        #expect(kept.count == 6)   // Sep 2…7; Sep 8's midnight is past the reset
    }
}
