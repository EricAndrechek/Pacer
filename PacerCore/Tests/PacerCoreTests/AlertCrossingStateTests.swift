import Foundation
import Testing
@testable import PacerCore

// The threshold alerts judge each reading against the previous one. These pin
// the rules that make that correct whatever is on screen (#143): a first
// reading never fires, each reading is judged once, and the memory survives a
// relaunch, so a crossing that happened while Pacer was closed still fires.

@Suite("Alert crossing state")
struct AlertCrossingStateTests {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private let reset = Date(timeIntervalSince1970: 1_790_018_000)

    /// Thresholds a sequence of readings fires, run through the real policy.
    private func fired(_ readings: [Double], thresholds: [Int],
                       state: inout AlertCrossingState, key: String = "a|five_hour",
                       startMinute: Double = 0) -> [[Int]] {
        readings.enumerated().map { i, pct in
            guard let step = state.advance(key, percent: pct, resetsAt: reset,
                                           sampledAt: at(startMinute + Double(i))) else { return [] }
            return RateLimitThresholdPolicy.crossedThresholds(
                previous: step.previousPercent, current: pct, thresholds: thresholds)
        }
    }

    @Test func aFirstReadingIsRecordedWithoutFiring() {
        var state = AlertCrossingState()
        // Already past 75% and 90% the first time Pacer sees the window.
        #expect(fired([95], thresholds: [75, 90], state: &state) == [[]])
    }

    @Test func eachThresholdFiresOnceAsItIsCrossed() {
        var state = AlertCrossingState()
        #expect(fired([50, 85, 92, 95, 80, 91], thresholds: [75, 90], state: &state)
                == [[], [75], [90], [], [], [90]])
    }

    @Test func aReadingIsJudgedOnce() {
        var state = AlertCrossingState()
        _ = state.advance("a|five_hour", percent: 50, resetsAt: reset, sampledAt: at(0))
        #expect(state.advance("a|five_hour", percent: 95, resetsAt: reset, sampledAt: at(1))
                == .init(previousPercent: 50, previousResetsAt: reset))
        // The same reading again, and an older one folded back from the
        // archive: neither is new, so neither is judged.
        #expect(state.advance("a|five_hour", percent: 95, resetsAt: reset, sampledAt: at(1)) == nil)
        #expect(state.advance("a|five_hour", percent: 10, resetsAt: reset, sampledAt: at(0.5)) == nil)
    }

    @Test func accountsAndWindowsAreIndependent() {
        var state = AlertCrossingState()
        _ = state.advance("a|five_hour", percent: 80, resetsAt: reset, sampledAt: at(0))
        // Account b's first reading is its own first, whatever a's was.
        #expect(state.advance("b|five_hour", percent: 95, resetsAt: reset, sampledAt: at(1)) == nil)
        #expect(state.advance("a|seven_day", percent: 95, resetsAt: reset, sampledAt: at(1)) == nil)
        #expect(state.advance("a|five_hour", percent: 95, resetsAt: reset, sampledAt: at(2))?
                .previousPercent == 80)
    }

    /// The case #143 is about: the window crosses 90% while nothing is
    /// evaluating. With the memory persisted, the next evaluation, in a new
    /// process, judges the new reading against the one from before.
    @Test func aCrossingWhileClosedFiresOnTheNextEvaluation() {
        var before = AlertCrossingState()
        #expect(fired([60, 80], thresholds: [90], state: &before) == [[], []])

        var after = AlertCrossingState(data: before.encoded())
        #expect(after == before)
        #expect(fired([94], thresholds: [90], state: &after, startMinute: 30) == [[90]])
    }

    @Test func unreadableMemoryStartsFresh() {
        #expect(AlertCrossingState(data: nil) == AlertCrossingState())
        #expect(AlertCrossingState(data: Data("not json".utf8)) == AlertCrossingState())
    }

    @Test func dailyCostRisesAreReportedAndANewDayStartsFromZero() {
        var state = AlertCrossingState()
        #expect(state.advanceDailyCost(120, date: "2026-09-25") == false)  // first ever: silent
        #expect(state.advanceDailyCost(130, date: "2026-09-25") == true)
        #expect(state.advanceDailyCost(130, date: "2026-09-25") == false)
        // Yesterday's $130 is not today's baseline: the first spend counts.
        #expect(state.advanceDailyCost(4, date: "2026-09-26") == true)
        // And it survives a relaunch.
        var after = AlertCrossingState(data: state.encoded())
        #expect(after.advanceDailyCost(4, date: "2026-09-26") == false)
        #expect(after.advanceDailyCost(9, date: "2026-09-26") == true)
    }
}
