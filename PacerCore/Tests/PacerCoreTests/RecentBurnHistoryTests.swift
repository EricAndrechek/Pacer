import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// `RecentBurnHistory`: the weekly burn's 16.8 hours of readings, kept
/// between snapshot builds so each build reads only the last half hour.
@Suite("Recent burn history")
struct RecentBurnHistoryTests {

    private static let week: TimeInterval = 7 * 86400
    private static let account = "org-work"

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: RateLimitSample.self, UsageLimitSample.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static func insert(_ context: ModelContext, at: Date, percent: Double, reset: Date) {
        context.insert(RateLimitSample(sampledAt: at, window: RateLimitWindowName.sevenDay,
                                       usedPercentage: percent, resetsAt: reset,
                                       source: RateLimitSource.oauth, accountId: account))
    }

    private static func direct(_ context: ModelContext, now: Date) throws -> [RecentBurn.Reading] {
        try context.fetch(LimitScope.rateLimits(
            account: account, window: RateLimitWindowName.sevenDay,
            since: now.addingTimeInterval(-RecentBurn.lookbackLimit(duration: week))))
            .reversed()
            .map { .init(at: $0.sampledAt, percent: $0.usedPercentage, resetsAt: $0.resetsAt) }
    }

    /// Build after build, with new readings landing between them, what it
    /// hands over is what a whole read would have.
    @MainActor
    @Test func eachBuildMatchesAWholeRead() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = t0.addingTimeInterval(3 * 86400)
        for minute in stride(from: 20 * 60, through: 0, by: -5) {
            Self.insert(context, at: t0.addingTimeInterval(-Double(minute) * 60),
                        percent: 40 + Double((20 * 60 - minute) / 50), reset: reset)
        }
        try context.save()
        let history = RecentBurnHistory()
        for step in 0..<12 {
            let now = t0.addingTimeInterval(Double(step) * 75)
            if step > 0 {
                Self.insert(context, at: now.addingTimeInterval(-3), percent: 64 + Double(step / 4), reset: reset)
                try context.save()
            }
            let held = history.fixed(context: ModelContext(container), account: Self.account,
                                     window: RateLimitWindowName.sevenDay, duration: Self.week, now: now)
            #expect(held == (try Self.direct(context, now: now)), "step \(step)")
        }
    }

    /// A row written late with an older time (an archive fold) is missed by
    /// the half-hour reads and arrives with the next whole read.
    @MainActor
    @Test func aLateOlderRowArrivesWithTheNextWholeRead() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(86400)
        Self.insert(context, at: now.addingTimeInterval(-5 * 3600), percent: 30, reset: reset)
        Self.insert(context, at: now, percent: 33, reset: reset)
        try context.save()
        let history = RecentBurnHistory()
        func read(_ at: Date) -> [RecentBurn.Reading] {
            history.fixed(context: ModelContext(container), account: Self.account,
                          window: RateLimitWindowName.sevenDay, duration: Self.week, now: at)
        }
        #expect(read(now).count == 2)
        Self.insert(context, at: now.addingTimeInterval(-2 * 3600), percent: 31, reset: reset)
        try context.save()
        #expect(read(now.addingTimeInterval(60)).count == 2)
        #expect(read(now.addingTimeInterval(RecentBurnHistory.rereadEvery + 60)).count == 3)
    }

    /// Another store's rows never answer for this one, under the same account
    /// and window.
    @MainActor
    @Test func eachContainerHasItsOwnRows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(86400)
        let history = RecentBurnHistory()
        for percent in [10.0, 70.0] {
            let container = try Self.makeContainer()
            let context = ModelContext(container)
            Self.insert(context, at: now.addingTimeInterval(-3600), percent: percent, reset: reset)
            Self.insert(context, at: now, percent: percent + 1, reset: reset)
            try context.save()
            let held = history.fixed(context: context, account: Self.account,
                                     window: RateLimitWindowName.sevenDay, duration: Self.week, now: now)
            #expect(held.map(\.percent) == [percent, percent + 1])
        }
    }

    /// A gap longer than the fresh half hour can bridge (the app asleep, no
    /// builds) is a whole read: the readings in between are not lost.
    @MainActor
    @Test func aLongGapIsAWholeRead() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(86400)
        Self.insert(context, at: now, percent: 20, reset: reset)
        try context.save()
        let history = RecentBurnHistory()
        _ = history.fixed(context: context, account: Self.account, window: RateLimitWindowName.sevenDay,
                          duration: Self.week, now: now)
        let later = now.addingTimeInterval(45 * 60)
        Self.insert(context, at: now.addingTimeInterval(5 * 60), percent: 21, reset: reset)
        Self.insert(context, at: later, percent: 22, reset: reset)
        try context.save()
        let held = history.fixed(context: context, account: Self.account, window: RateLimitWindowName.sevenDay,
                                 duration: Self.week, now: later)
        #expect(held.map(\.percent) == [20, 21, 22])
    }
}
