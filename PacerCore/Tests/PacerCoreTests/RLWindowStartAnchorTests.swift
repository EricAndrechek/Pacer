import Foundation
import Testing
@testable import PacerCore

/// A window opens at 0%, and that counts as a reading: an account read every
/// 5–10 minutes gets a line from its first poll of a new window, instead of
/// waiting for a second one (the owner's report on 2026-10-20).
@Suite("Window-start anchor")
struct RLWindowStartAnchorTests {

    static let utc = Calendar(identifier: .gregorian).with(timeZone: TimeZone(identifier: "UTC")!)
    static let now = Date(timeIntervalSince1970: 1_752_000_000)
    static let window: TimeInterval = 5 * 3600

    @Test func oneReadingThreeMinutesInDrawsALine() throws {
        // The window started 3 min ago; the only poll so far, at 7%.
        let start = Self.now.addingTimeInterval(-180), reset = start.addingTimeInterval(Self.window)
        let rate = [EngineFeatures.RateRow(window: "five_hour", at: Self.now, usedPercentage: 7, resetsAt: reset)]
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [], rate: rate, lastArrivalAt: nil)
        let fit = UsageIntelligenceEngine.makeFit(f)
        let list = UsageIntelligenceEngine.rateLimitTrajectories(f, fit, windowKey: "five_hour", accuracy: nil)
        let drawn = try #require(list.first { $0.isSelected })
        #expect(drawn.canProject && drawn.trajectory.points.count > 1)
        #expect(UsageIntelligenceEngine.burnOutlook(f, fit, windowKey: "five_hour")?.method != "none")
    }

    @Test func theAnchorIsTheWindowStartAtZeroAndOnlyWhenTheFirstReadingIsLater() {
        let start = Self.now.addingTimeInterval(-600), reset = start.addingTimeInterval(Self.window)
        let later = BurnTrajectory.PartialCycle(
            samples: [.init(at: Self.now, usedPercentage: 7)], now: Self.now, cycleStart: start, resetsAt: reset)
        #expect(later.samples.first == .init(at: start, usedPercentage: 0))
        #expect(later.usedNow == 7)                                   // the live value is still the reading
        let atStart = BurnTrajectory.PartialCycle(
            samples: [.init(at: start, usedPercentage: 0), .init(at: Self.now, usedPercentage: 7)],
            now: Self.now, cycleStart: start, resetsAt: reset)
        #expect(atStart.samples.count == 2)                           // no duplicate when a poll landed on the start
        let none = BurnTrajectory.PartialCycle(samples: [], now: Self.now, cycleStart: start, resetsAt: reset)
        #expect(none.samples.isEmpty)                                 // no reading, nothing to extrapolate
    }
}

private extension Calendar {
    func with(timeZone: TimeZone) -> Calendar { var c = self; c.timeZone = timeZone; return c }
}
