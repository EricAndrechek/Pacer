import Foundation
import SwiftData
import Testing
@testable import PacerCore

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: DailyAggregate.self, AccountDailyAggregate.self,
        HourlyAggregate.self, AccountHourlyAggregate.self,
        SessionInfo.self, AccountSessionInfo.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

/// The scope switch is a change of *source*, not of meaning: a view rendering
/// the per-account table must produce the same shape it produces from the
/// global one. These assert the two normalisations agree field for field —
/// the property that lets one view body serve both.
@Suite("Scoped row normalisation")
@MainActor
struct ScopedRowTests {

    @Test("a daily row reads the same from either table")
    func dailyRowsAgree() throws {
        let global = DailyAggregate(
            date: "2026-09-03", model: "claude-opus-5",
            inputTokens: 11, outputTokens: 22, cacheReadTokens: 33,
            cacheCreation5mTokens: 44, cacheCreation1hTokens: 55,
            totalCostUSD: 6.75)
        let scoped = AccountDailyAggregate(
            accountId: "org-a", date: "2026-09-03", model: "claude-opus-5",
            inputTokens: 11, outputTokens: 22, cacheReadTokens: 33,
            cacheCreation5mTokens: 44, cacheCreation1hTokens: 55,
            totalCostUSD: 6.75)
        #expect(global.dailyRow == scoped.dailyRow)
        #expect(global.dailyRow.totalTokens == 165)
    }

    @Test("an hourly row reads the same, except the count only one table stores")
    func hourlyRowsAgree() throws {
        let global = HourlyAggregate(
            date: "2026-09-03", hour: 14, model: "claude-opus-5",
            inputTokens: 5, outputTokens: 6, cacheReadTokens: 7,
            cacheCreation5mTokens: 8, cacheCreation1hTokens: 9,
            totalCostUSD: 1.5, sampleCount: 3)
        let scoped = AccountHourlyAggregate(
            accountId: "org-a", date: "2026-09-03", hour: 14, model: "claude-opus-5",
            inputTokens: 5, outputTokens: 6, cacheReadTokens: 7,
            cacheCreation5mTokens: 8, cacheCreation1hTokens: 9,
            totalCostUSD: 1.5)
        #expect(global.hourlyRow.inputTokens == scoped.hourlyRow.inputTokens)
        #expect(global.hourlyRow.totalCostUSD == scoped.hourlyRow.totalCostUSD)
        // The documented asymmetry: only the global rollup stores a turn
        // count, so a scoped row reports 0. It feeds a "quiet hour" hint,
        // never a number the user reads.
        #expect(global.hourlyRow.sampleCount == 3)
        #expect(scoped.hourlyRow.sampleCount == 0)
    }

    @Test("a session row reads the same from either table")
    func sessionRowsAgree() throws {
        let at = Date(timeIntervalSince1970: 1_780_000_000)
        let global = SessionInfo(
            sessionId: "s1", firstSeenAt: at, lastSeenAt: at.addingTimeInterval(60),
            projectPath: "/p", ccVersion: "2.1", cumulativeCostUSD: 3.25,
            cumulativeInputTokens: 1, cumulativeOutputTokens: 2,
            cumulativeCacheReadTokens: 3, cumulativeCacheCreation5mTokens: 4,
            cumulativeCacheCreation1hTokens: 5, topModel: "claude-opus-5")
        let scoped = AccountSessionInfo(
            accountId: "org-a", sessionId: "s1",
            firstSeenAt: at, lastSeenAt: at.addingTimeInterval(60),
            projectPath: "/p", ccVersion: "2.1", cumulativeCostUSD: 3.25,
            cumulativeInputTokens: 1, cumulativeOutputTokens: 2,
            cumulativeCacheReadTokens: 3, cumulativeCacheCreation5mTokens: 4,
            cumulativeCacheCreation1hTokens: 5, topModel: "claude-opus-5")
        #expect(global.sessionRow == scoped.sessionRow)
        #expect(global.sessionRow.totalTokens == 15)
    }

    /// Both project rollups satisfy the read protocol the Projects view and
    /// `CollectionUsageRollup` consume, which is what makes the scope switch
    /// a source change rather than a second copy of the view.
    @Test("both project rollups satisfy the read protocol identically")
    func projectRowsAgree() {
        let at = Date(timeIntervalSince1970: 1_780_000_000)
        let global: any ProjectDailyReadable = ProjectDailyAggregate(
            projectPath: "/p", date: "2026-09-03",
            inputTokens: 1, outputTokens: 2, cacheReadTokens: 3,
            cacheCreation5mTokens: 4, cacheCreation1hTokens: 5,
            totalCostUSD: 9.5, sessionCount: 2, modelCount: 1,
            lastActive: at, sessionIdsJSON: Data(), modelTokensJSON: Data(),
            modelCostJSON: Data())
        let scoped: any ProjectDailyReadable = AccountProjectDailyAggregate(
            accountId: "org-a", projectPath: "/p", date: "2026-09-03",
            inputTokens: 1, outputTokens: 2, cacheReadTokens: 3,
            cacheCreation5mTokens: 4, cacheCreation1hTokens: 5,
            totalCostUSD: 9.5, sessionCount: 2, modelCount: 1,
            lastActive: at, sessionIdsJSON: Data(), modelTokensJSON: Data(),
            modelCostJSON: Data())
        #expect(global.projectPath == scoped.projectPath)
        #expect(global.totalCostUSD == scoped.totalCostUSD)
        #expect(global.sessionCount == scoped.sessionCount)
        #expect(global.lastActive == scoped.lastActive)
    }

    /// `perPathTotals` folds either table, which is the whole reason it was
    /// generalised rather than duplicated.
    @Test("collection totals fold either rollup to the same answer")
    func collectionRollupAcceptsEither() {
        let at = Date(timeIntervalSince1970: 1_780_000_000)
        func totals(_ rows: [any ProjectDailyReadable]) -> ProjectUsageTotals? {
            CollectionUsageRollup.perPathTotals(from: rows)["/p"]
        }
        let g = totals([ProjectDailyAggregate(
            projectPath: "/p", date: "d", inputTokens: 10, outputTokens: 20,
            cacheReadTokens: 30, cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
            totalCostUSD: 5, sessionCount: 1, modelCount: 1, lastActive: at,
            sessionIdsJSON: Data(), modelTokensJSON: Data(), modelCostJSON: Data())])
        let s = totals([AccountProjectDailyAggregate(
            accountId: "org-a", projectPath: "/p", date: "d",
            inputTokens: 10, outputTokens: 20, cacheReadTokens: 30,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
            totalCostUSD: 5, sessionCount: 1, modelCount: 1, lastActive: at,
            sessionIdsJSON: Data(), modelTokensJSON: Data(), modelCostJSON: Data())])
        #expect(g?.cost == s?.cost)
        #expect(g?.inputTokens == s?.inputTokens)
        #expect(g?.sessionCount == s?.sessionCount)
    }

    /// The sentinel must match nothing, or "all accounts" would silently
    /// render one arbitrary account's rows.
    @Test("the no-account sentinel matches no real account")
    func sentinelMatchesNothing() throws {
        let context = ModelContext(try makeContainer())
        context.insert(AccountDailyAggregate(
            accountId: "org-a", date: "d", model: "m",
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: 1))
        try context.save()
        let sentinel = UsageScope.noAccountSentinel
        let rows = try context.fetch(FetchDescriptor<AccountDailyAggregate>(
            predicate: #Predicate { $0.accountId == sentinel }))
        #expect(rows.isEmpty)
    }
}
