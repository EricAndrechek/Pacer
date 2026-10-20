import Foundation
import Testing
@testable import PacerCore

/// Rate-limit model selection by half of the window, with a relative tie band
/// (#305). Adopted on full history: the 5-hour median miss 3.82 → 3.57 pp.
@Suite("Rate-limit selection by half of the window")
struct RLPhaseSelectionTests {

    /// `early` wins the 20–40% cuts and `late` wins the 50–90% cuts, over
    /// `periods` cycles.
    static func records(early: String, late: String, periods: Int = 4) -> [EngineSelfEval.Record] {
        var out: [EngineSelfEval.Record] = []
        for p in 0..<periods {
            let key = "2026-09-\(String(format: "%02d", p + 1))T00:00:00Z"
            for cut in [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9] {
                let bucket = EngineSelfEval.rlBucket(cut)
                let earlyWins = cut < 0.5
                out.append(.init(method: early, bucket: bucket, periodKey: key, predicted: earlyWins ? 51 : 58, truth: 50))
                out.append(.init(method: late, bucket: bucket, periodKey: key, predicted: earlyWins ? 57 : 50.5, truth: 50))
            }
        }
        return out
    }

    @Test func eachHalfPicksTheModelThatReadsItBest() {
        let recs = Self.records(early: "recent-rate", late: "saturating")
        let cx = UsageIntelligenceEngine.rlComplexities()
        #expect(EngineSelfEval.bestMethod(from: recs, complexity: cx, phase: .early, tieRelative: 0.05) == "recent-rate")
        #expect(EngineSelfEval.bestMethod(from: recs, complexity: cx, phase: .late, tieRelative: 0.05) == "saturating")
    }

    @Test func theAccuracyShownIsTheHalfThePickRead() throws {
        let recs = Self.records(early: "recent-rate", late: "saturating")
        let late = EngineSelfEval.accuracy(surface: "rl-five_hour", from: recs, phase: .late)
        let stat = try #require(late.methods.first { $0.method == "saturating" })
        #expect(stat.typicalAbsError == 0.5)       // its late-cut miss, not the all-cuts median
        #expect(stat.periods == 4)
        #expect(stat.byStage.count == 3)           // the popover still shows every stage
    }

    /// At a ~3 pp miss the absolute 1.5-point band tied a model 10% worse with
    /// the best, and the simpler one won. 5% of the best is 0.15 points.
    @Test func aRelativeTieNoLongerHandsAClearlyWorsePickToTheSimplerModel() {
        func recs(_ id: String, miss: Double) -> [EngineSelfEval.Record] {
            (0..<4).map { .init(method: id, bucket: EngineSelfEval.rlBucket(0.5), periodKey: "p\($0)",
                                predicted: 50 + miss, truth: 50) }
        }
        let all = recs("recent-rate", miss: 3.3) + recs("saturating", miss: 3.0)   // recent-rate is simpler
        let cx = UsageIntelligenceEngine.rlComplexities()
        #expect(EngineSelfEval.bestMethod(from: all, complexity: cx) == "recent-rate")
        #expect(EngineSelfEval.bestMethod(from: all, complexity: cx, tieRelative: 0.05) == "saturating")
    }

    @Test func theLiveCycleSaysWhichHalfItIsIn() {
        let now = Date(timeIntervalSince1970: 1_752_000_000)
        let window: TimeInterval = 5 * 3600
        func features(elapsed: Double) -> EngineFeatures {
            let start = now.addingTimeInterval(-elapsed * window)
            let rows = stride(from: 0.0, through: elapsed * window, by: 600).map {
                EngineFeatures.RateRow(window: "five_hour", at: start.addingTimeInterval($0),
                                       usedPercentage: $0 / 360, resetsAt: start.addingTimeInterval(window))
            }
            return EngineFeatures.build(now: now, calendar: Calendar(identifier: .gregorian),
                                        daily: [], hourly: [], rate: rows, lastArrivalAt: nil)
        }
        let spec = WindowSpec.fixed(.fiveHour)
        #expect(UsageIntelligenceEngine.livePhase(features(elapsed: 0.3), window: spec) == .early)
        #expect(UsageIntelligenceEngine.livePhase(features(elapsed: 0.7), window: spec) == .late)
    }
}
