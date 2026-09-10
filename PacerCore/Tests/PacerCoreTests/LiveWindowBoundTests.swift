import Foundation
import SwiftData
import Testing
@testable import PacerCore

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: RateLimitSample.self, UsageLimitSample.self, ExtraUsageSample.self,
        AccountUsageArchive.self, Account.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}

private func daysAgo(_ d: Double) -> Date { Date().addingTimeInterval(-d * 86_400) }

@Suite("Live-window bound")
@MainActor
struct LiveWindowBoundTests {

    /// The live tables are a cache of the active account's recent window.
    /// Restoring an account's ENTIRE history on switch is what made the swap
    /// scale with how long the app had been installed — 177,689 rows here.
    @Test("a switch restores only the recent window, and leaves the rest archived")
    func restoreIsBounded() throws {
        let context = ModelContext(try makeContainer())
        for age in [1.0, 10.0, 34.0, 40.0, 200.0] {
            context.insert(AccountUsageArchive(
                accountId: "incoming",
                kind: AccountUsageArchive.kindRateLimit,
                sampledAt: daysAgo(age),
                window: RateLimitWindowName.fiveHour,
                usedPercentage: 50, resetsAt: nil,
                source: RateLimitSource.oauth))
        }
        try context.save()

        // Mirrors the restore predicate in `swapActiveTimeline`.
        let cutoff = daysAgo(OAuthPoller.liveWindowDays)
        let restorable = try context.fetch(FetchDescriptor<AccountUsageArchive>(
            predicate: #Predicate { $0.accountId == "incoming" && $0.sampledAt >= cutoff }))
        #expect(restorable.count == 3)          // 1d, 10d, 34d

        let all = try context.fetch(FetchDescriptor<AccountUsageArchive>())
        #expect(all.count == 5)                 // 40d and 200d stay put
    }

    @Test("the window clears every reader: engine 32d, views 8d")
    func windowCoversEveryReader() {
        // The engine's backtest is the widest read; the bound must exceed it
        // or a switch would silently truncate the forecast's inputs.
        #expect(OAuthPoller.liveWindowDays > 32)
    }

    @Test("nothing is lost: an evicted row is archived before it is removed")
    func evictionIsNotDeletion() throws {
        let context = ModelContext(try makeContainer())
        context.insert(RateLimitSample(
            sampledAt: daysAgo(100), window: RateLimitWindowName.sevenDay,
            usedPercentage: 77, resetsAt: nil,
            source: RateLimitSource.oauth, accountId: "acct"))
        context.insert(RateLimitSample(
            sampledAt: daysAgo(1), window: RateLimitWindowName.sevenDay,
            usedPercentage: 12, resetsAt: nil,
            source: RateLimitSource.oauth, accountId: "acct"))
        context.insert(UsageLimitSample(
            sampledAt: daysAgo(90), identity: "weekly_scoped|Fable|",
            kind: "weekly_scoped", group: "weekly", label: "Fable",
            percent: 40, resetsAt: nil, severity: "normal", isActive: true,
            modelId: nil, modelDisplayName: "Fable", surface: nil,
            source: RateLimitSource.oauth, accountId: "acct"))
        try context.save()

        let moved = OAuthPoller.testEvictStaleLiveRows(context: context, accountId: "acct")
        try context.save()
        #expect(moved == 2)

        let live = try context.fetch(FetchDescriptor<RateLimitSample>())
        #expect(live.count == 1)
        #expect(live.first?.usedPercentage == 12)   // the recent one stayed

        let archived = try context.fetch(FetchDescriptor<AccountUsageArchive>())
        #expect(archived.count == 2)
        #expect(archived.contains { $0.usedPercentage == 77 })   // nothing lost
        #expect(archived.contains { $0.identity == "weekly_scoped|Fable|" })
        #expect(archived.allSatisfy { $0.accountId == "acct" })
    }

    @Test("a live row with no accountId is archived under the active account")
    func legacyRowsInheritTheActiveAccount() throws {
        let context = ModelContext(try makeContainer())
        // Pre-multi-account rows have no accountId; they belong to whoever
        // was active, which is the only account that existed.
        context.insert(RateLimitSample(
            sampledAt: daysAgo(100), window: RateLimitWindowName.fiveHour,
            usedPercentage: 5, resetsAt: nil, source: RateLimitSource.oauth))
        try context.save()

        _ = OAuthPoller.testEvictStaleLiveRows(context: context, accountId: "acct")
        try context.save()

        let archived = try context.fetch(FetchDescriptor<AccountUsageArchive>())
        #expect(archived.count == 1)
        #expect(archived.first?.accountId == "acct")
    }
}
