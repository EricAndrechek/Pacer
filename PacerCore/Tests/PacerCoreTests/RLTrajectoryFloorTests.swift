import Foundation
import Testing
@testable import PacerCore

/// A drawn line never falls below the live reading (#312): a meter does not
/// fall inside a window, and the value a model shows is already floored there
/// (`displayedAtReset`), so the line now ends where that value is.
@Suite("Rate-limit lines are floored at the reading")
struct RLTrajectoryFloorTests {

    /// Projects a steady fall, as the Kalman filter's slope can after a jump
    /// then a flat stretch.
    struct Falling: BurnTrajectory.Model {
        let id = "kalman-trend"
        let complexity = 5
        func fit(_ cycle: BurnTrajectory.PartialCycle) -> (@Sendable (Date) -> Double)? {
            let now = cycle.now, level = cycle.usedNow
            return { date in level - 10 * date.timeIntervalSince(now) / 3600 }
        }
    }

    @Test func aFallingFitDrawsAFlatLineAtTheReadingAndEndsAtItsShownValue() throws {
        let now = Date(timeIntervalSince1970: 1_752_000_000)
        let window: TimeInterval = 7 * 86400
        let start = now.addingTimeInterval(-2 * 86400)
        let rows = stride(from: 0.0, through: 2 * 86400, by: 6 * 3600).map {
            EngineFeatures.RateRow(window: "seven_day", at: start.addingTimeInterval($0),
                                   usedPercentage: min(60, $0 / 2880), resetsAt: start.addingTimeInterval(window))
        }
        let f = EngineFeatures.build(now: now, calendar: Calendar(identifier: .gregorian),
                                     daily: [], hourly: [], rate: rows, lastArrivalAt: nil)
        var fit = UsageIntelligenceEngine.Fit()
        fit.rl["seven_day"] = .init(roster: [Falling()], selectedId: "kalman-trend", resolvedId: "kalman-trend",
                                    duration: window, historyCount: 0)
        let line = try #require(UsageIntelligenceEngine.rateLimitTrajectories(f, fit, windowKey: "seven_day", accuracy: nil)
            .first { $0.modelId == "kalman-trend" })
        let used = try #require(rows.last?.usedPercentage)
        #expect(!line.trajectory.points.isEmpty)
        #expect(line.trajectory.points.allSatisfy { $0.usedPercentage >= used - 1e-9 })
        #expect(abs((line.trajectory.points.last?.usedPercentage ?? 0) - used) < 1e-9)
    }
}
