import Foundation
import Testing
@testable import PacerCore

/// A reading is stale when its account falls behind the freshest reading by
/// several of its OWN poll gaps (#302), not by a fixed three minutes.
@Suite("Reading freshness")
struct ReadingFreshnessTests {

    static let t0 = Date(timeIntervalSince1970: 1_752_000_000)
    static func polls(every gap: TimeInterval, count: Int, endingAt end: Date) -> [Date] {
        (0..<count).map { end.addingTimeInterval(-Double($0) * gap) }
    }

    @Test func aBackgroundAccountBetweenOrdinaryPollsIsNotStale() {
        // Polled every 6 minutes; its last reading is 5 minutes behind the
        // active lane's. The old 3-minute rule called this stale.
        let reads = Self.polls(every: 360, count: 13, endingAt: Self.t0)
        let gap = ReadingFreshness.typicalGap(readingTimes: reads)
        #expect(gap == 360)
        #expect(!ReadingFreshness.isStale(readingAt: Self.t0, newestAnyAccountAt: Self.t0.addingTimeInterval(300),
                                          typicalGap: gap))
        // A slow poll (its p90 is 10 minutes) is still ordinary.
        #expect(!ReadingFreshness.isStale(readingAt: Self.t0, newestAnyAccountAt: Self.t0.addingTimeInterval(600),
                                          typicalGap: gap))
    }

    @Test func anAccountThatStoppedBeingReadIsStaleWithinAFewPolls() {
        let reads = Self.polls(every: 360, count: 13, endingAt: Self.t0)
        let gap = ReadingFreshness.typicalGap(readingTimes: reads)
        #expect(ReadingFreshness.isStale(readingAt: Self.t0, newestAnyAccountAt: Self.t0.addingTimeInterval(16 * 60),
                                         typicalGap: gap))
    }

    @Test func theActiveLaneStillTripsAfterThreeMinutes() {
        let reads = Self.polls(every: 60, count: 13, endingAt: Self.t0)
        let gap = ReadingFreshness.typicalGap(readingTimes: reads)
        #expect(ReadingFreshness.allowedLag(typicalGap: gap) == ReadingFreshness.minimumLag)
        #expect(ReadingFreshness.isStale(readingAt: Self.t0, newestAnyAccountAt: Self.t0.addingTimeInterval(200),
                                         typicalGap: gap))
    }

    @Test func oneRowPerWindowPerPollCountsAsOnePoll() {
        // A poll stores a 5-hour and a 7-day row at the same instant.
        let reads = Self.polls(every: 360, count: 5, endingAt: Self.t0)
        #expect(ReadingFreshness.typicalGap(readingTimes: reads + reads) == 360)
    }

    @Test func withNoHistoryTheFloorApplies() {
        #expect(ReadingFreshness.typicalGap(readingTimes: [Self.t0]) == nil)
        #expect(ReadingFreshness.allowedLag(typicalGap: nil) == ReadingFreshness.minimumLag)
        #expect(!ReadingFreshness.isStale(readingAt: nil, newestAnyAccountAt: Self.t0, typicalGap: nil))
    }
}
