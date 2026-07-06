import Foundation
import Testing
@testable import PacerCore

/// Shadow candidates: they score into the record from day one, but the
/// promotion floor keeps a thin (lucky) record off the screen.
@Suite("Shadow model candidates")
struct ShadowModelTests {

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    static let now = utc.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 14))!

    /// `periods` distinct scored periods where `method` beats `rival` (1pp vs 5pp error).
    private func records(method: String, rival: String, periods: Int) -> [EngineSelfEval.Record] {
        (0..<periods).flatMap { i -> [EngineSelfEval.Record] in
            let key = "2026-06-\(String(format: "%02d", i + 1))"
            return [
                .init(method: method, bucket: "cut=0.50", periodKey: key, predicted: 51, truth: 50),
                .init(method: rival, bucket: "cut=0.50", periodKey: key, predicted: 55, truth: 50),
            ]
        }
    }

    @Test func shadowCannotBePromotedBelowItsFloor() {
        // Kalman wins every period, but with only 10 < 15 scored periods the
        // gate holds and the established rival is selected.
        let recs = records(method: "kalman-trend", rival: "recency-weighted", periods: 10)
        let pick = EngineSelfEval.bestMethod(
            from: recs, provisionalMinPeriods: ["kalman-trend": 15])
        #expect(pick == "recency-weighted")
    }

    @Test func shadowPromotesOnceFloorIsMetAndItWins() {
        let recs = records(method: "kalman-trend", rival: "recency-weighted", periods: 15)
        let pick = EngineSelfEval.bestMethod(
            from: recs, provisionalMinPeriods: ["kalman-trend": 15])
        #expect(pick == "kalman-trend")
    }

    @Test func shadowFloorsCoverKalmanEverywhereAndDiurnalOnFiveHourOnly() {
        let fiveH = UsageIntelligenceEngine.rlShadowFloors(.fiveHour)
        let sevenD = UsageIntelligenceEngine.rlShadowFloors(.sevenDay)
        #expect(fiveH["kalman-trend"] == EngineParams.current.shadowPromotionMinPeriods)
        #expect(fiveH["diurnal-rate"] == EngineParams.current.shadowPromotionMinPeriods)
        #expect(sevenD["kalman-trend"] == EngineParams.current.shadowPromotionMinPeriods)
        #expect(sevenD["diurnal-rate"] == nil)   // established on 7d, not a shadow
    }

    @Test func kalmanIsInTheDefaultRosterSoItAccumulatesRecord() {
        #expect(BurnTrajectory.defaultModels.contains { $0.id == "kalman-trend" })
    }

    // MARK: - KalmanTrend fit sanity

    private func cycle(slopePerHour: Double, hours: Double, noise: [Double] = []) -> BurnTrajectory.PartialCycle {
        let start = Self.now.addingTimeInterval(-hours * 3600)
        var samples: [BurnTrajectory.Sample] = []
        var i = 0
        var t = 0.0
        while t <= hours {
            let jitter = noise.isEmpty ? 0 : noise[i % noise.count]
            samples.append(.init(at: start.addingTimeInterval(t * 3600),
                                 usedPercentage: 10 + slopePerHour * t + jitter))
            t += 0.25
            i += 1
        }
        return .init(samples: samples, now: Self.now, cycleStart: start,
                     resetsAt: Self.now.addingTimeInterval(2 * 3600))
    }

    @Test func kalmanRecoversACleanLinearSlope() throws {
        let c = cycle(slopePerHour: 8, hours: 3)
        let projection = try #require(BurnTrajectory.KalmanTrend().fit(c))
        // One hour ahead of the last sample the projection should climb ≈8pp.
        let atNow = projection(Self.now)
        let inOneHour = projection(Self.now.addingTimeInterval(3600))
        #expect(abs((inOneHour - atNow) - 8) < 1.0)
    }

    @Test func kalmanSmoothsZeroMeanNoiseInsteadOfChasingIt() throws {
        let c = cycle(slopePerHour: 4, hours: 3, noise: [0.6, -0.6, 0.3, -0.3])
        let projection = try #require(BurnTrajectory.KalmanTrend().fit(c))
        let atNow = projection(Self.now)
        let inOneHour = projection(Self.now.addingTimeInterval(3600))
        #expect(abs((inOneHour - atNow) - 4) < 1.5)
    }

    @Test func kalmanDeclinesTinyCycles() {
        var c = cycle(slopePerHour: 5, hours: 3)
        c = .init(samples: Array(c.samples.prefix(2)), now: c.now,
                  cycleStart: c.cycleStart, resetsAt: c.resetsAt)
        #expect(BurnTrajectory.KalmanTrend().fit(c) == nil)
    }
}
