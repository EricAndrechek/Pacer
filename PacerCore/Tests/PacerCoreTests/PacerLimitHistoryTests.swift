import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// `/v1/limits/history` — the shape of a window over time, which is what lets
/// a consumer fit its own slope instead of trusting ours.
@Suite("Limit history")
struct PacerLimitHistoryTests {

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: RateLimitSample.self, UsageLimitSample.self, ExtraUsageSample.self, Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static func build(_ container: ModelContainer, hours: Int = 24,
                              bucket: Int = 900, account: String? = nil,
                              now: Date) throws -> PacerLimitHistory {
        try PacerLimitHistoryBuilder.history(
            container: container, hours: hours, bucketSeconds: bucket,
            account: account, activeAccountId: "org-work", now: now)
    }

    /// Utilization is a level, so a bucket keeps its *latest* reading. A mean
    /// would smear a step across a reset; a max would hide one.
    @MainActor
    @Test func aBucketKeepsItsLatestReading() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        // Three samples inside one 15-minute bucket.
        for (offset, pct) in [(-800.0, 10.0), (-600.0, 20.0), (-500.0, 30.0)] {
            context.insert(RateLimitSample(
                sampledAt: now.addingTimeInterval(offset), window: RateLimitWindowName.fiveHour,
                usedPercentage: pct, resetsAt: reset,
                source: RateLimitSource.oauth, accountId: "org-work"))
        }
        try context.save()

        let history = try Self.build(container, hours: 2, now: now)
        let points = history.windows.first { $0.identity == "five_hour" }?.points ?? []
        #expect(points.count == 1)
        #expect(points.first?.usedPercent == 30)
        #expect(history.bucketSeconds == 900)
    }

    /// The reason `cycle` exists. The server's `resets_at` drifts by
    /// milliseconds between polls, so grouping by it exactly splits one cycle
    /// into as many groups as there were polls — and a consumer fitting a slope
    /// per group gets nothing.
    @MainActor
    @Test func millisecondDriftInResetsAtIsNotAReset() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        for i in 0..<6 {
            context.insert(RateLimitSample(
                sampledAt: now.addingTimeInterval(Double(-i) * 1200),
                window: RateLimitWindowName.fiveHour,
                usedPercentage: Double(60 - i * 5),
                resetsAt: reset.addingTimeInterval(Double(i) * 0.3),   // jitter
                source: RateLimitSource.oauth, accountId: "org-work"))
        }
        try context.save()

        let points = try Self.build(container, hours: 4, now: now)
            .windows.first { $0.identity == "five_hour" }?.points ?? []
        #expect(points.count > 1)
        #expect(Set(points.map(\.cycle)) == [0])
        // The drifting values are still reported verbatim; they are just not
        // what a consumer segments on.
        #expect(Set(points.compactMap(\.resetsAt)).count > 1)
    }

    /// A genuine rollover *is* a new cycle, and the drop from 90% to 0% between
    /// two adjacent points is a real event rather than a gap to interpolate.
    @MainActor
    @Test func aRolloverIncrementsTheCycle() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldReset = now.addingTimeInterval(-3600)
        let newReset = now.addingTimeInterval(5 * 3600 - 3600)
        context.insert(RateLimitSample(
            sampledAt: now.addingTimeInterval(-4800), window: RateLimitWindowName.fiveHour,
            usedPercentage: 90, resetsAt: oldReset,
            source: RateLimitSource.oauth, accountId: "org-work"))
        context.insert(RateLimitSample(
            sampledAt: now.addingTimeInterval(-1200), window: RateLimitWindowName.fiveHour,
            usedPercentage: 4, resetsAt: newReset,
            source: RateLimitSource.oauth, accountId: "org-work"))
        try context.save()

        let points = try Self.build(container, hours: 4, now: now)
            .windows.first { $0.identity == "five_hour" }?.points ?? []
        #expect(points.map(\.cycle) == [0, 1])
        #expect(points.map(\.usedPercent) == [90, 4])
    }

    /// The 0%-used reading right after a rollover carries no `resets_at` at
    /// all — real server behaviour, and not a third cycle.
    @MainActor
    @Test func aNilResetDoesNotStartACycle() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        context.insert(RateLimitSample(
            sampledAt: now.addingTimeInterval(-2400), window: RateLimitWindowName.fiveHour,
            usedPercentage: 40, resetsAt: reset,
            source: RateLimitSource.oauth, accountId: "org-work"))
        context.insert(RateLimitSample(
            sampledAt: now.addingTimeInterval(-1200), window: RateLimitWindowName.fiveHour,
            usedPercentage: 0, resetsAt: nil,
            source: RateLimitSource.oauth, accountId: "org-work"))
        try context.save()

        let points = try Self.build(container, hours: 4, now: now)
            .windows.first { $0.identity == "five_hour" }?.points ?? []
        #expect(Set(points.map(\.cycle)) == [0])
    }

    @MainActor
    @Test func scopedWindowsGetTheirOwnSeries() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<3 {
            context.insert(UsageLimitSample(
                sampledAt: now.addingTimeInterval(Double(-i) * 1200),
                identity: "weekly_scoped|Fable|", kind: "weekly_scoped", group: "weekly",
                label: "Fable", percent: Double(50 - i * 5),
                resetsAt: now.addingTimeInterval(86_400), severity: "normal", isActive: false,
                modelDisplayName: "Fable", source: RateLimitSource.oauth, accountId: "org-work"))
        }
        try context.save()

        let history = try Self.build(container, hours: 4, now: now)
        let fable = history.windows.first { $0.identity == "weekly_scoped|Fable|" }
        #expect(fable?.label == "Fable")
        #expect(fable?.group == "weekly")
        #expect((fable?.points.count ?? 0) == 3)
    }

    /// One login's curve, never two interleaved into a single line.
    @MainActor
    @Test func historyIsScopedToOneAccount() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (account, pct) in [("org-work", 60.0), ("org-home", 5.0)] {
            context.insert(RateLimitSample(
                sampledAt: now.addingTimeInterval(-600), window: RateLimitWindowName.fiveHour,
                usedPercentage: pct, resetsAt: now.addingTimeInterval(3600),
                source: RateLimitSource.oauth, accountId: account))
        }
        try context.save()

        // Unscoped falls back to the active login, like every other limit read.
        let active = try Self.build(container, hours: 2, now: now)
        #expect(active.windows.first?.points.first?.usedPercent == 60)

        let home = try Self.build(container, hours: 2, account: "org-home", now: now)
        #expect(home.account == "org-home")
        #expect(home.windows.first?.points.first?.usedPercent == 5)
    }

    @Test func bucketParsingTakesUnitsAndClamps() {
        #expect(PacerLimitHistoryBuilder.parseBucket("15m") == 900)
        #expect(PacerLimitHistoryBuilder.parseBucket("2h") == 7200)
        #expect(PacerLimitHistoryBuilder.parseBucket("30s") == 30)
        #expect(PacerLimitHistoryBuilder.parseBucket("600") == 600)
        #expect(PacerLimitHistoryBuilder.parseBucket(nil) == 900)
        #expect(PacerLimitHistoryBuilder.parseBucket("nonsense") == 900)
    }

    @MainActor
    @Test func rangeAndBucketAreClamped() throws {
        let container = try Self.makeContainer()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try Self.build(container, bucket: 1, now: now).bucketSeconds
            == PacerLimitHistoryBuilder.minBucketSeconds)
        #expect(try Self.build(container, bucket: 999_999, now: now).bucketSeconds
            == PacerLimitHistoryBuilder.maxBucketSeconds)
    }
}


/// The measured short-horizon burn — the number you look at when deciding
/// whether to launch a wave *now*, as opposed to the engine's smoothed slope.
@Suite("Recent burn")
struct RecentBurnTests {

    private func reading(_ minutesAgo: Double, _ percent: Double,
                         reset: Date? = nil, now: Date) -> RecentBurn.Reading {
        RecentBurn.Reading(at: now.addingTimeInterval(-minutesAgo * 60),
                           percent: percent, resetsAt: reset)
    }

    @Test func measuresFirstToLastAcrossTheLookback() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        // 20 points over 30 minutes = 40 points per hour.
        let readings = [reading(30, 20, reset: reset, now: now),
                        reading(15, 30, reset: reset, now: now),
                        reading(0, 40, reset: reset, now: now)]
        let burn = RecentBurn.percentPerHour(readings: readings, now: now, duration: 5 * 3600)
        #expect(burn != nil)
        #expect(abs((burn ?? 0) - 40) < 0.001)
    }

    /// A rollover inside the lookback makes first-to-last a large negative
    /// number describing nothing. Only the newest cycle counts.
    @Test func aResetInsideTheLookbackIsNotANegativeSlope() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldCycle = now.addingTimeInterval(-600)
        let newCycle = now.addingTimeInterval(5 * 3600 - 600)
        let readings = [reading(28, 95, reset: oldCycle, now: now),
                        reading(20, 98, reset: oldCycle, now: now),
                        reading(10, 3, reset: newCycle, now: now),
                        reading(0, 9, reset: newCycle, now: now)]
        let burn = RecentBurn.percentPerHour(readings: readings, now: now, duration: 5 * 3600)
        // 3% → 9% over ten minutes = 36 points per hour, not a plunge.
        #expect(abs((burn ?? 0) - 36) < 0.001)
    }

    /// Sub-second drift in the server's reset time is not a rollover.
    @Test func resetDriftDoesNotSplitTheCycle() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        let readings = [reading(20, 10, reset: reset, now: now),
                        reading(0, 20, reset: reset.addingTimeInterval(0.4), now: now)]
        #expect(RecentBurn.percentPerHour(readings: readings, now: now, duration: 5 * 3600) != nil)
    }

    /// An account with one token is polled every five minutes, so a lookback
    /// can legitimately hold a single reading. There is no slope in one point
    /// and a confident zero would be a lie.
    @Test func oneReadingIsNoSlope() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RecentBurn.percentPerHour(
            readings: [reading(2, 40, reset: now.addingTimeInterval(3600), now: now)],
            now: now, duration: 5 * 3600) == nil)
        #expect(RecentBurn.percentPerHour(readings: [], now: now, duration: 5 * 3600) == nil)
    }

    /// Two poller lanes landing in the same instant are one reading.
    @Test func twoSimultaneousReadingsAreNotAnInfiniteRate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        let readings = [reading(0, 40, reset: reset, now: now),
                        reading(0, 41, reset: reset, now: now)]
        #expect(RecentBurn.percentPerHour(readings: readings, now: now, duration: 5 * 3600) == nil)
    }

    // MARK: - Cycles (#339)

    /// The live case: a 5-hour window reset at 9% and the server's next
    /// reading said 0% with `resets_at: null`. With nothing to anchor on,
    /// every older reading counted and the rate read −19%/h for the half hour.
    @Test func aNullAnchoredReadingAfterAResetIsNotANegativeSlope() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ended = now.addingTimeInterval(-5 * 60)
        let readings = [reading(26, 9, reset: ended, now: now),
                        reading(16, 9, reset: ended, now: now),
                        reading(7, 9, reset: ended, now: now),
                        reading(3, 0, now: now)]
        // One reading of the new cycle: no rate, and above all not −19.
        #expect(RecentBurn.percentPerHour(readings: readings, now: now, duration: 5 * 3600) == nil)
        // Polled again at 0%, still null: idle, which is 0.
        let later = now.addingTimeInterval(10 * 60)
        let held = readings + [reading(0, 0, now: later)]
        #expect(RecentBurn.percentPerHour(readings: held, now: later, duration: 5 * 3600) == 0)
    }

    /// The next message opens the new window: 0% (null) → 3% with the new
    /// reset is that window's own climb, counted from its start.
    @Test func theNewWindowCountsFromItsFirstNullReading() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ended = now.addingTimeInterval(-25 * 60)
        let opened = now.addingTimeInterval(5 * 3600 - 10 * 60)
        let readings = [reading(28, 40, reset: ended, now: now),
                        reading(20, 0, now: now),
                        reading(10, 0, now: now),
                        reading(0, 3, reset: opened, now: now)]
        let burn = RecentBurn.percentPerHour(readings: readings, now: now, duration: 5 * 3600)
        #expect(abs((burn ?? -1) - 9) < 0.001)   // 3 points in 20 minutes
    }

    /// A null reset in the middle of a cycle (the server sends one now and
    /// then above 0%) borrows the run's anchor instead of letting another
    /// cycle in: here an earlier window that closed below today's level, so
    /// no fall marks the boundary, and a reading carrying a reset a whole
    /// window away from the run's.
    @Test func aNullNewestReadingKeepsOtherCyclesOut() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cycle = now.addingTimeInterval(3600)
        let closed = now.addingTimeInterval(-4 * 3600)
        let elsewhere = cycle.addingTimeInterval(5 * 3600)
        for other in [closed, elsewhere] {
            let readings = [reading(29, 30, reset: other, now: now),
                            reading(20, 40, reset: cycle, now: now),
                            reading(10, 44, reset: cycle, now: now),
                            reading(0, 48, now: now)]
            let burn = RecentBurn.percentPerHour(readings: readings, now: now, duration: 5 * 3600)
            #expect(abs((burn ?? -1) - 24) < 0.001)  // 40% → 48% in 20 minutes
        }
    }

    /// An off-schedule reset can zero a window and keep its anchor (seen on
    /// 2026-06-20). Usage never falls inside a cycle, so the fall is the
    /// boundary, whatever `resets_at` says.
    @Test func aFallUnderTheSameAnchorIsAReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(2 * 3600)
        let readings = [reading(25, 60, reset: reset, now: now),
                        reading(15, 64, reset: reset, now: now),
                        reading(10, 1, reset: reset, now: now),
                        reading(0, 3, reset: reset, now: now)]
        let burn = RecentBurn.percentPerHour(readings: readings, now: now, duration: 5 * 3600)
        #expect(abs((burn ?? -1) - 12) < 0.001)  // 1% → 3% in 10 minutes
    }

    /// The newest reading's window has closed by `now`: its burn was the old
    /// cycle's, and the next reading is a new one's.
    @Test func aWindowThatHasClosedHasNoBurn() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ended = now.addingTimeInterval(-60)
        let readings = [reading(20, 80, reset: ended, now: now),
                        reading(2, 90, reset: ended, now: now)]
        #expect(RecentBurn.percentPerHour(readings: readings, now: now, duration: 5 * 3600) == nil)
        #expect(RecentBurn.percentPerHour(readings: readings, now: now.addingTimeInterval(-90),
                                          duration: 5 * 3600) != nil)
    }

    /// Walked minute by minute across two resets, with null anchors at 0%
    /// and a stale anchor after them, no moment reads a negative burn.
    @Test func noMomentAcrossResetsIsNegative() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = t0.addingTimeInterval(3600)
        let second = t0.addingTimeInterval(3 * 3600)
        var readings: [RecentBurn.Reading] = []
        for minute in stride(from: 0, through: 240, by: 3) {
            let at = t0.addingTimeInterval(Double(minute) * 60)
            switch minute {
            case ..<60: readings.append(.init(at: at, percent: 50 + Double(minute) / 2, resetsAt: first))
            case 60..<90: readings.append(.init(at: at, percent: 0, resetsAt: nil))
            case 90..<180: readings.append(.init(at: at, percent: Double(minute - 90) / 4,
                                                 resetsAt: second.addingTimeInterval(Double(minute % 2) * 0.3)))
            default: readings.append(.init(at: at, percent: minute < 200 ? 0 : 5, resetsAt: nil))
            }
        }
        for minute in 0...240 {
            let now = t0.addingTimeInterval(Double(minute) * 60 + 30)
            let seen = readings.filter { $0.at <= now }
            if let burn = RecentBurn.percentPerHour(readings: seen, now: now, duration: 5 * 3600) {
                #expect(burn >= 0, "minute \(minute): \(burn)")
            }
        }
    }

    @Test func readingsOlderThanTheLookbackAreIgnored() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        let readings = [reading(600, 0, reset: reset, now: now),     // 10 h ago
                        reading(20, 30, reset: reset, now: now),
                        reading(0, 40, reset: reset, now: now)]
        let burn = RecentBurn.percentPerHour(readings: readings, now: now, duration: 5 * 3600)
        #expect(abs((burn ?? 0) - 30) < 0.001)   // 10 points in 20 minutes
    }
}
