import Foundation
import Testing
@testable import PacerCore

/// The compare sheet explains each model: a name that says what the line does,
/// a one-line hover, a popover with how it works (numbers read from the
/// constants the model fits with), and its record split by stage of window.
@Suite("Rate-limit model info")
struct RLModelInfoTests {

    static let fiveHour: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86400
    static let rosterIds = BurnTrajectory.defaultModels.map(\.id) + ["diurnal-rate"]

    @Test func everyModelIsNamedSummarisedAndExplained() {
        for id in Self.rosterIds {
            #expect(BurnTrajectory.displayName(id) != id, "\(id) has no display name")
            #expect(BurnTrajectory.summary(id) != nil, "\(id) has no summary")
            #expect(BurnTrajectory.howItWorks(id, windowDuration: Self.fiveHour) != nil, "\(id) has no explanation")
        }
    }

    @Test func theExplanationQuotesTheSpanTheModelActuallyUses() throws {
        let linear5h = try #require(BurnTrajectory.howItWorks("linear-recent", windowDuration: Self.fiveHour))
        let linear7d = try #require(BurnTrajectory.howItWorks("linear-recent", windowDuration: Self.week))
        #expect(linear5h.contains("last 90 minutes"))          // 30% of 5 hours
        #expect(linear7d.contains("last 2 days"))              // 30% of 7 days
        let weighted5h = try #require(BurnTrajectory.howItWorks("recency-weighted", windowDuration: Self.fiveHour))
        #expect(weighted5h.contains("halves every 45 minutes")) // 15% of 5 hours
        let recent5h = try #require(BurnTrajectory.howItWorks("recent-rate", windowDuration: Self.fiveHour))
        let recent7d = try #require(BurnTrajectory.howItWorks("recent-rate", windowDuration: Self.week))
        #expect(recent5h.contains("last hour"))
        #expect(recent7d.contains("last day"))
    }

    @Test func accuracySplitsTheRecordByStageOfWindow() throws {
        func rec(_ cut: Double, _ err: Double, _ period: String) -> EngineSelfEval.Record {
            .init(method: "linear-recent", bucket: EngineSelfEval.rlBucket(cut),
                  periodKey: period, predicted: 50 + err, truth: 50)
        }
        let records = [rec(0.2, 9, "a"), rec(0.4, 7, "a"), rec(0.6, 3, "a"), rec(0.9, 1, "a"),
                       rec(0.2, 11, "b"), rec(0.6, 5, "b"), rec(0.8, 1, "b")]
        let acc = EngineSelfEval.accuracy(surface: "rl-five_hour", from: records)
        let stat = try #require(acc.methods.first)
        #expect(stat.byStage.map(\.stage) == [.early, .middle, .late])
        #expect(stat.byStage.map(\.scores) == [3, 2, 2])
        #expect(stat.byStage.map(\.typicalAbsError) == [9, 4, 1])   // medians on a session window
    }

    @Test func aSurfaceWithoutCutsHasNoStages() throws {
        let records = [EngineSelfEval.Record(method: "pooled", bucket: "all", periodKey: "a", predicted: 2, truth: 1)]
        let stat = try #require(EngineSelfEval.accuracy(from: records).methods.first)
        #expect(stat.byStage.isEmpty)
    }
}
