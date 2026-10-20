import Foundation
import Testing
@testable import PacerCore

/// Newer roster members (Kalman, recent-rate) compete on their record like
/// every other model: there is no separate promotion floor any more, because
/// the record backfill gives a new model the same depth of record on install.
@Suite("Model candidates")
struct ModelCandidateTests {

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

    @Test func aNewModelThatWinsItsRecordIsSelectedAtTheCommonFloor() {
        // Two scored periods is the floor for every model; Kalman wins both.
        let recs = records(method: "kalman-trend", rival: "recency-weighted", periods: 2)
        #expect(EngineSelfEval.bestMethod(from: recs) == "kalman-trend")
    }

    @Test func belowTheCommonFloorNothingIsSelected() {
        let recs = records(method: "kalman-trend", rival: "recency-weighted", periods: 1)
        #expect(EngineSelfEval.bestMethod(from: recs) == nil)
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
