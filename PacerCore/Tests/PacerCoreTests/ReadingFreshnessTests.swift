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

    @Test func aBurstOfReadingsCountsAsOnePoll() {
        // Read every 5 minutes through seven lanes at once, 7 s apart (#308):
        // the gap that matters is the 5 minutes between rounds, not the 7 s
        // inside one.
        let rounds = Self.polls(every: 300, count: 13, endingAt: Self.t0)
        let reads = rounds.flatMap { end in Self.polls(every: 7, count: 7, endingAt: end) }
        let gap = ReadingFreshness.typicalGap(readingTimes: reads)
        #expect(gap == 300)
        // An ordinary pause between rounds, as replayed from a real store:
        // about 200 s behind another account's newer reading.
        #expect(!ReadingFreshness.isStale(readingAt: Self.t0, newestAnyAccountAt: Self.t0.addingTimeInterval(228),
                                          typicalGap: gap))
        // Still caught once it stops being read.
        #expect(ReadingFreshness.isStale(readingAt: Self.t0, newestAnyAccountAt: Self.t0.addingTimeInterval(16 * 60),
                                         typicalGap: gap))
    }

    @Test func aLaneReadFasterThanABurstStillTripsAfterThreeMinutes() {
        // Every 20 s, steadily: one long run of readings, no gap to learn
        // from, so the floor applies — as it did when its gap read as 20 s.
        let reads = Self.polls(every: 20, count: 40, endingAt: Self.t0)
        #expect(ReadingFreshness.typicalGap(readingTimes: reads) == nil)
        #expect(ReadingFreshness.isStale(readingAt: Self.t0, newestAnyAccountAt: Self.t0.addingTimeInterval(200),
                                         typicalGap: nil))
    }

    @Test func withNoHistoryTheFloorApplies() {
        #expect(ReadingFreshness.typicalGap(readingTimes: [Self.t0]) == nil)
        #expect(ReadingFreshness.allowedLag(typicalGap: nil) == ReadingFreshness.minimumLag)
        #expect(!ReadingFreshness.isStale(readingAt: nil, newestAnyAccountAt: Self.t0, typicalGap: nil))
    }
}
