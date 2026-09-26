import Foundation
import Testing
@testable import PacerCore

/// The live pass used to rebuild every open day-long bucket together, every
/// ten minutes, re-reading the whole day's samples each time (#151). These pin
/// the rationing that replaced it: bounded per pass, yet every open bucket
/// comes round, and a day that closes is still rebuilt after it closes.
@Suite("Live rebuild planner")
struct LiveRebuildPlannerTests {

    private let dayStart = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ minutes: Double) -> Date { dayStart.addingTimeInterval(minutes * 60) }
    private func planner(limit: Int = 3) -> LiveRebuildPlanner<String> {
        LiveRebuildPlanner(limit: limit) { $0 }
    }

    @Test func aPassRebuildsAtMostTheLimitAndEveryOpenBucketComesRound() {
        var p = planner()
        let open: Set = ["a", "b", "c", "d", "e", "f", "g"]
        #expect(p.pick(open: open, justClosed: [], now: at(10), dayStart: dayStart) == ["a", "b", "c"])
        #expect(p.pick(open: open, justClosed: [], now: at(20), dayStart: dayStart) == ["d", "e", "f"])
        // Then the longest-waiting: g was never rebuilt, a and b the earliest.
        #expect(p.pick(open: open, justClosed: [], now: at(30), dayStart: dayStart) == ["g", "a", "b"])
    }

    @Test func aNewBucketWaitsLessThanOnesAlreadyRebuilt() {
        var p = planner(limit: 1)
        _ = p.pick(open: ["a"], justClosed: [], now: at(10), dayStart: dayStart)
        // "b" appears (a project's first turn today): never rebuilt, so first.
        #expect(p.pick(open: ["a", "b"], justClosed: [], now: at(20), dayStart: dayStart) == ["b"])
    }

    /// Just after midnight: yesterday's buckets are about to freeze, so they
    /// go before today's, and stay queued past the first hour until done.
    @Test func aClosedDayGoesFirstAndStaysQueuedUntilEachIsRebuilt() {
        var p = planner()
        let yesterday: Set = ["y1", "y2", "y3", "y4", "y5"]
        let today: Set = ["t1", "t2"]
        #expect(p.pick(open: today, justClosed: yesterday, now: at(5), dayStart: dayStart)
                == ["y1", "y2", "y3"])
        #expect(p.closing == ["y4", "y5"])
        // An hour later `now - 1h` is today, so nothing is newly closed, but
        // y4 and y5 have not been rebuilt since the close.
        #expect(p.pick(open: today, justClosed: [], now: at(65), dayStart: dayStart)
                == ["y4", "y5", "t1"])
        #expect(p.closing.isEmpty)
    }

    /// A rebuild while the day was still open does not count: samples can
    /// land after it, and the rebuild that settles the bucket is the one after
    /// the close.
    @Test func aBucketRebuiltBeforeTheCloseIsRebuiltAgainAfterIt() {
        var p = planner()
        let yesterdayStart = dayStart.addingTimeInterval(-86_400)
        _ = p.pick(open: ["y1"], justClosed: [], now: at(-5), dayStart: yesterdayStart)
        #expect(p.pick(open: [], justClosed: ["y1"], now: at(5), dayStart: dayStart) == ["y1"])
        // And once rebuilt after the close, not again for the rest of the hour.
        #expect(p.pick(open: [], justClosed: ["y1"], now: at(15), dayStart: dayStart).isEmpty)
    }

    @Test func itForgetsBucketsThatAreNoLongerOpen() {
        var p = planner()
        _ = p.pick(open: ["a", "b"], justClosed: [], now: at(10), dayStart: dayStart)
        _ = p.pick(open: ["c"], justClosed: [], now: at(20), dayStart: dayStart)
        #expect(Set(p.lastRebuilt.keys) == ["c"])
    }
}
