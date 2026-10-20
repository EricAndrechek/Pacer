import Foundation
import Testing
@testable import PacerCore

/// Weekly bands from the scoreboard (#306): a refit reads 32 days, about four
/// weekly cycles, short of the 8-residual gate forever. The record keeps every
/// cycle it has scored, and since #300 its rows are displayed values, so they
/// calibrate the band directly.
@Suite("Rate-limit calibration from the record")
struct RLRecordCalibrationTests {

    static let utc = Calendar(identifier: .gregorian).with(timeZone: TimeZone(identifier: "UTC")!)
    static let now = Date(timeIntervalSince1970: 1_752_000_000)
    static let week: TimeInterval = 7 * 24 * 3600

    /// Four completed weekly cycles in the fetch, and a live one half way.
    static func features() -> EngineFeatures {
        var rate: [EngineFeatures.RateRow] = []
        let liveStart = now.addingTimeInterval(-0.5 * week)
        for c in 0...4 {
            let start = liveStart.addingTimeInterval(-Double(4 - c) * week)
            let reset = start.addingTimeInterval(week)
            var t = start, pct = 0.0
            while t <= min(reset, now) {
                rate.append(.init(window: "seven_day", at: t, usedPercentage: min(90, pct), resetsAt: reset))
                t = t.addingTimeInterval(6 * 3600); pct += 1.8
            }
        }
        return EngineFeatures.build(now: now, calendar: utc, daily: [], hourly: [], rate: rate, lastArrivalAt: nil)
    }

    /// Ten older weekly cycles the record scored for `method`, before the fetch.
    static func olderRecord(method: String) -> [EngineSelfEval.Record] {
        let firstFetched = now.addingTimeInterval(-0.5 * week - 4 * week)
        return (1...10).flatMap { k -> [EngineSelfEval.Record] in
            let reset = firstFetched.addingTimeInterval(-Double(k - 1) * week)
            let key = EngineSelfEval.periodKeyRL(reset)
            return [0.2, 0.5, 0.8].map { cf in
                .init(method: method, bucket: EngineSelfEval.rlBucket(cf), periodKey: key,
                      predicted: 70 + Double(k % 3), truth: 72)
            }
        }
    }

    @Test func tenScoredWeeksAndFourFetchedStateABand() throws {
        let f = Self.features()
        let pick = ["seven_day": "linear-recent"]
        let without = UsageIntelligenceEngine.makeFit(f, rlSelection: pick)
        let est0 = UsageIntelligenceEngine.answer(.rateLimitOutlook(.sevenDay), features: f, fit: without)
        #expect(est0.interval80 == nil)                        // four cycles: below the gate, as today

        let with = UsageIntelligenceEngine.makeFit(
            f, rlSelection: pick, rlRecords: ["seven_day": Self.olderRecord(method: "linear-recent")])
        let rf = try #require(with.rl["seven_day"])
        #expect(rf.calibrators["pooled"]?.count == 14)         // one block per cycle: 4 fetched + 10 recorded
        #expect(rf.cyclesObserved == 14)                       // the frequency facts read them too
        let est = UsageIntelligenceEngine.answer(.rateLimitOutlook(.sevenDay), features: f, fit: with)
        #expect(est.interval80 != nil)
    }

    @Test func anotherModelsRecordDoesNotCalibrateThisOne() throws {
        let f = Self.features()
        let fit = UsageIntelligenceEngine.makeFit(
            f, rlSelection: ["seven_day": "linear-recent"],
            rlRecords: ["seven_day": Self.olderRecord(method: "saturating")])
        #expect(fit.rl["seven_day"]?.calibrators["pooled"]?.count == 4)
    }

    @Test func bucketsParse() {
        #expect(EngineSelfEval.rlCutFraction("cut=0.20|v2") == 0.2)
        #expect(EngineSelfEval.rlCutFraction("cut=0.90") == 0.9)
        #expect(EngineSelfEval.rlCutFraction("eod") == nil)
        let reset = Date(timeIntervalSince1970: 1_752_000_000)
        #expect(EngineSelfEval.periodDateRL(EngineSelfEval.periodKeyRL(reset)) == reset)
    }
}

private extension Calendar {
    func with(timeZone: TimeZone) -> Calendar { var c = self; c.timeZone = timeZone; return c }
}
