import Foundation
import Testing
@testable import PacerCore

/// Rate-limit model selection matched to the live point of the window: each
/// cut's errors weighted by its closeness to how far through the window the
/// live cycle is (`EngineSelfEval.cutWeight`), which replaced the early/late
/// halves (#305), with the relative tie band.
@Suite("Rate-limit selection at the live point of the window")
struct RLMatchedPointSelectionTests {

    /// `early` wins the cuts before half way and `late` the rest, over
    /// `periods` cycles.
    static func records(early: String, late: String, periods: Int = 4) -> [EngineSelfEval.Record] {
        var out: [EngineSelfEval.Record] = []
        for p in 0..<periods {
            let key = "2026-09-\(String(format: "%02d", p + 1))T00:00:00Z"
            for cut in EngineSelfEval.rlCutFractions {
                let bucket = EngineSelfEval.rlBucket(cut)
                let earlyWins = cut < 0.5
                out.append(.init(method: early, bucket: bucket, periodKey: key, predicted: earlyWins ? 51 : 58, truth: 50))
                out.append(.init(method: late, bucket: bucket, periodKey: key, predicted: earlyWins ? 57 : 50.5, truth: 50))
            }
        }
        return out
    }

    @Test func eachPointOfTheWindowPicksTheModelThatReadsItBest() {
        let recs = Self.records(early: "recent-rate", late: "saturating")
        let cx = UsageIntelligenceEngine.rlComplexities()
        #expect(EngineSelfEval.bestMethod(from: recs, complexity: cx, at: 0.2, tieRelative: 0.05) == "recent-rate")
        #expect(EngineSelfEval.bestMethod(from: recs, complexity: cx, at: 0.8, tieRelative: 0.05) == "saturating")
    }

    @Test func theAccuracyShownIsThePointThePickRead() throws {
        let recs = Self.records(early: "recent-rate", late: "saturating")
        let late = EngineSelfEval.accuracy(surface: "rl-five_hour", from: recs, at: 0.85)
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

    @Test func theLiveCycleSaysHowFarThroughItIs() throws {
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
        let early = try #require(UsageIntelligenceEngine.liveFraction(features(elapsed: 0.3), window: spec))
        let late = try #require(UsageIntelligenceEngine.liveFraction(features(elapsed: 0.7), window: spec))
        #expect(abs(early - 0.3) < 0.01)
        #expect(abs(late - 0.7) < 0.01)
    }
}
