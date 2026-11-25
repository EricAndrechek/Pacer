import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The arena's grader skips what the engine's does (#424): a cut inside a gap
/// in the readings, the last ones of a cycle whose readings stopped early
/// among them. And it does not come back for them: a second pass finds
/// nothing to do.
@Suite("Arena runtime: no grade across a reading gap")
struct RuntimeGapGradingTests {

    static let now = RuntimeEngineTests.now
    static let account = "acct-gaps"
    static let fiveHours: TimeInterval = 5 * 3600

    /// Twelve completed five-hour cycles read every 10 minutes, then a live
    /// one. Cycle 9 has no reading from 1 h to 3 h in; cycle 10's readings
    /// stop at 4 h; cycle 11 is read only in its first ten minutes.
    static func seeded() throws -> (ModelContainer, [BurnTrajectory.Cycle]) {
        let container = try PacerStore.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Account(id: account, organizationId: account, displayName: "Test", isActive: true,
                           firstSeenAt: now.addingTimeInterval(-90 * 86400), lastSeenAt: now))
        let liveStart = now.addingTimeInterval(-2 * 3600)
        var completed: [BurnTrajectory.Cycle] = []
        for c in 0...12 {
            let start = liveStart.addingTimeInterval(-Double(12 - c) * (fiveHours + 3600))
            let reset = start.addingTimeInterval(fiveHours)
            var samples: [BurnTrajectory.Sample] = []
            var t = start.addingTimeInterval(300)
            while t < reset && t <= now {
                let h = t.timeIntervalSince(start) / 3600
                defer { t = t.addingTimeInterval(600) }
                if c == 9, h > 1, h < 3 { continue }
                if c == 10, h > 4 { continue }
                if c == 11, h > 0.2 { continue }
                let pct = (h * 8).rounded()
                samples.append(.init(at: t, usedPercentage: pct))
                ctx.insert(RateLimitSample(sampledAt: t, window: "five_hour", usedPercentage: pct,
                                           resetsAt: reset, source: "oauth", accountId: account))
            }
            if c < 12 { completed.append(.init(samples: samples, cycleStart: start, resetsAt: reset)) }
        }
        try ctx.save()
        return (container, completed)
    }

    @Test func theArenaGradesOnlyWhatTheReadingsShow() async throws {
        let (container, cycles) = try Self.seeded()
        let cuts = EngineSelfEval.rlGrading.cuts
        // The gap covers cuts 0.325–0.55 of cycle 9; cycle 10 stops before
        // cut 0.925 (4.625 h); cycle 11 has no cut with three readings.
        #expect(cycles[9].gradedCuts(cuts).count == cuts.count - 4)
        #expect(cycles[10].gradedCuts(cuts).count == cuts.count - 1)
        #expect(cycles[11].gradedCuts(cuts).isEmpty)
        let expected = cycles.reduce(0) { $0 + $1.gradedCuts(cuts).count }

        let rt = RuntimeEngineTests.runtime(container, roster: [RuntimeEngineTests.peeker])
        let first = await rt.scorer.pass(accounts: [Self.account], now: Self.now)
        let rows = try RuntimeEngineTests.arenaRows(container, method: "test-peeker")
        #expect(rows.count == expected)
        #expect(first.outcomes == expected)
        // Cycle 11 is not in the depth at all: nothing to grade.
        #expect(first.cycles == 11)
        #expect(!rows.contains { $0.periodKey == EngineSelfEval.periodKeyRL(cycles[11].resetsAt) })
        let gapBuckets = Set(rows.filter { $0.periodKey == EngineSelfEval.periodKeyRL(cycles[9].resetsAt) }.map(\.bucket))
        #expect(gapBuckets == Set(cycles[9].gradedCuts(cuts).map(EngineSelfEval.rlBucket)))

        // The cuts left ungraded are done: a second pass has nothing to do.
        let second = await rt.scorer.pass(accounts: [Self.account], now: Self.now)
        #expect(second.outcomes == 0)
        #expect(second.cycles == 0)
    }
}
