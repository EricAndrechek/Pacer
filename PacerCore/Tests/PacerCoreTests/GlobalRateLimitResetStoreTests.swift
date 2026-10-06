import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// `detectRecent` reads the newest reading first and the full lookback only
/// when that reading is low. These pin that the shortcut never changes the
/// answer `detect` gives over the same rows.
@Suite("GlobalRateLimitReset.detectRecent")
struct GlobalRateLimitResetStoreTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var anchor: Date { now.addingTimeInterval(3 * 24 * 3600) }
    private let window = RateLimitWindowName.sevenDay
    private let lookback: TimeInterval = (7 * 24 + 1) * 3600

    private static func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: RateLimitSample.self, Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func insert(_ context: ModelContext, minutesAgo: Double, pct: Double,
                        account: String = "orgA", window: String? = nil) {
        context.insert(RateLimitSample(
            sampledAt: now.addingTimeInterval(-minutesAgo * 60),
            window: window ?? self.window, usedPercentage: pct, resetsAt: anchor,
            source: RateLimitSource.oauth, accountId: account))
    }

    private func detect(_ context: ModelContext, account: String?) -> GlobalRateLimitReset.Detection? {
        GlobalRateLimitReset.detectRecent(
            in: context, account: account, window: window, lookback: lookback,
            highWatermark: 15, minAnchorLead: 30 * 60, now: now)
    }

    @MainActor
    @Test func findsAResetInStoredReadings() throws {
        let context = try Self.makeContext()
        insert(context, minutesAgo: 15, pct: 60)
        insert(context, minutesAgo: 10, pct: 0)
        insert(context, minutesAgo: 5, pct: 0)
        insert(context, minutesAgo: 0, pct: 0)
        try context.save()

        let found = detect(context, account: "orgA")
        #expect(found?.droppedFrom == 60)
        #expect(found?.droppedTo == 0)
        #expect(found?.resetsAt == anchor)
    }

    @MainActor
    @Test func aHighNewestReadingIsNoReset() throws {
        // A low run earlier in the series, but usage has climbed again since.
        let context = try Self.makeContext()
        insert(context, minutesAgo: 20, pct: 60)
        insert(context, minutesAgo: 15, pct: 0)
        insert(context, minutesAgo: 10, pct: 0)
        insert(context, minutesAgo: 5, pct: 0)
        insert(context, minutesAgo: 0, pct: 30)
        try context.save()
        #expect(detect(context, account: "orgA") == nil)
    }

    @MainActor
    @Test func anotherAccountsHighReadingsAreNotTheDropEdge() throws {
        // orgA has only ever been low. orgB's 60% interleaved with it would
        // look like a collapse to an unscoped read.
        let context = try Self.makeContext()
        insert(context, minutesAgo: 15, pct: 60, account: "orgB")
        insert(context, minutesAgo: 10, pct: 0)
        insert(context, minutesAgo: 5, pct: 0)
        insert(context, minutesAgo: 0, pct: 0)
        try context.save()
        #expect(detect(context, account: "orgA") == nil)
        #expect(detect(context, account: nil) != nil)
    }

    @MainActor
    @Test func readingsOutsideTheLookbackOrWindowAreIgnored() throws {
        let context = try Self.makeContext()
        // The only high reading is older than the lookback.
        insert(context, minutesAgo: lookback / 60 + 10, pct: 60)
        // And another window's high reading doesn't count either.
        insert(context, minutesAgo: 15, pct: 60, window: RateLimitWindowName.fiveHour)
        insert(context, minutesAgo: 10, pct: 0)
        insert(context, minutesAgo: 5, pct: 0)
        insert(context, minutesAgo: 0, pct: 0)
        try context.save()
        #expect(detect(context, account: "orgA") == nil)
    }

    @MainActor
    @Test func anEmptyStoreIsNoReset() throws {
        #expect(detect(try Self.makeContext(), account: "orgA") == nil)
    }
}
