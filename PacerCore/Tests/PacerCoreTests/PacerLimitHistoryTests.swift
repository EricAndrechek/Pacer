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
