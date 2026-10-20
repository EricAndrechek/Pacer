import Foundation
import Testing
@testable import PacerCore

/// The compare sheet lists every model the window knows, each without a line
/// flagged with why (#307).
@Suite("Rate-limit model list")
struct RLModelListTests {

    static let utc = Calendar(identifier: .gregorian).with(timeZone: TimeZone(identifier: "UTC")!)
    static let now = Date(timeIntervalSince1970: 1_752_000_000)
    static let window: TimeInterval = 5 * 3600

    /// Three completed cycles (so the diurnal model is in the roster), then a
    /// live one an hour in at 0% used.
    static func zeroUsedFeatures() -> EngineFeatures {
        var rate: [EngineFeatures.RateRow] = []
        let liveStart = now.addingTimeInterval(-3600)
        for c in 0..<3 {
            let start = liveStart.addingTimeInterval(-Double(3 - c) * window)
            let reset = start.addingTimeInterval(window)
            for k in 0...20 {
                rate.append(.init(window: "five_hour", at: start.addingTimeInterval(Double(k) * window / 20),
                                  usedPercentage: Double(k) * 3, resetsAt: reset))
            }
        }
        let liveReset = liveStart.addingTimeInterval(window)
        for k in 0...6 {
            rate.append(.init(window: "five_hour", at: liveStart.addingTimeInterval(Double(k) * 600),
                              usedPercentage: 0, resetsAt: liveReset))
        }
        return EngineFeatures.build(now: now, calendar: utc, daily: [], hourly: [], rate: rate, lastArrivalAt: nil)
    }

    @Test func atZeroUsedEveryModelIsListedAndTheDecliningOnesSayWhy() throws {
        let f = Self.zeroUsedFeatures()
        let fit = UsageIntelligenceEngine.makeFit(f)
        let list = UsageIntelligenceEngine.rateLimitTrajectories(f, fit, windowKey: "five_hour", accuracy: nil)
        let roster = try #require(fit.rl["five_hour"]).roster.map(\.id)
        #expect(Set(list.map(\.modelId)) == Set(roster))           // every model, not only those that fit
        let flagged = list.filter { !$0.canProject }
        #expect(Set(flagged.map(\.modelId)).isSuperset(of: ["saturating", "diurnal-rate"]))  // both decline at 0%
        #expect(flagged.allSatisfy { $0.unavailableReason == "nothing used yet this cycle" })
        #expect(flagged.allSatisfy { $0.trajectory.points.isEmpty && !$0.isSelected })
        #expect(list.filter(\.canProject).allSatisfy { !$0.trajectory.points.isEmpty })
    }

    @Test func aRecordedModelOutsideTheRosterIsListedToo() throws {
        // No completed cycle in the window: the diurnal model isn't in the
        // roster, but its record is shown with why it has no line.
        var rate: [EngineFeatures.RateRow] = []
        let start = Self.now.addingTimeInterval(-3600), reset = start.addingTimeInterval(Self.window)
        for k in 0...6 {
            rate.append(.init(window: "five_hour", at: start.addingTimeInterval(Double(k) * 600),
                              usedPercentage: Double(k) * 2, resetsAt: reset))
        }
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [], rate: rate, lastArrivalAt: nil)
        let acc = EngineSelfEval.Accuracy(surface: "rl-five_hour", methods: [
            .init(method: "diurnal-rate", medianAbsPctError: 4, typicalAbsError: 4, periods: 6)])
        let list = UsageIntelligenceEngine.rateLimitTrajectories(f, UsageIntelligenceEngine.makeFit(f),
                                                                 windowKey: "five_hour", accuracy: acc)
        let diurnal = try #require(list.first { $0.modelId == "diurnal-rate" })
        #expect(diurnal.unavailableReason == "needs a completed cycle")
        #expect(diurnal.typicalAbsError == 4)
    }
}

private extension Calendar {
    func with(timeZone: TimeZone) -> Calendar { var c = self; c.timeZone = timeZone; return c }
}
