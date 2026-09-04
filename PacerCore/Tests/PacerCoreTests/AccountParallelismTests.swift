import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// What "all accounts" can mean for a rate limit depends on how the machine is
/// used. Costs add up; a 5-hour window does not — two accounts at 60% are not
/// 120% of anything, they are two caps on two clocks. So the global view shows
/// the one account that constrains you when they run one at a time, and all of
/// them when they run together.
@Suite("Detecting parallel accounts")
struct AccountParallelismTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: AccountDailyAggregate.self, AccountActivation.self, Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @MainActor
    private func day(_ context: ModelContext, _ account: String, _ date: String, cost: Double) {
        context.insert(AccountDailyAggregate(
            accountId: account, date: date, model: "m",
            inputTokens: 100, outputTokens: 0, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: cost))
    }

    @MainActor
    @Test func oneAccountUsedTodayIsNotParallel() throws {
        let context = ModelContext(try makeContainer())
        let now = Date()
        day(context, "work", TokenSample.formatDate(now), cost: 5)
        try context.save()
        #expect(!AccountParallelism.isParallel(context: context, now: now))
    }

    /// The case the trail cannot see: two accounts used in sequence within one
    /// day. Their windows are both open and both constraining, so showing one
    /// hides the other.
    @MainActor
    @Test func twoAccountsUsedTodayIsParallel() throws {
        let context = ModelContext(try makeContainer())
        let now = Date()
        let today = TokenSample.formatDate(now)
        day(context, "work", today, cost: 5)
        day(context, "personal", today, cost: 1)
        try context.save()
        #expect(AccountParallelism.isParallel(context: context, now: now))
        #expect(AccountParallelism.accountsActiveToday(context: context, now: now) == 2)
    }

    /// Yesterday's second account does not make today parallel — that is
    /// switching, which is exactly the setup that wants one account shown.
    @MainActor
    @Test func yesterdaysOtherAccountDoesNotCount() throws {
        let context = ModelContext(try makeContainer())
        let now = Date()
        let yesterday = TokenSample.formatDate(now.addingTimeInterval(-86_400))
        day(context, "work", TokenSample.formatDate(now), cost: 5)
        day(context, "personal", yesterday, cost: 1)
        try context.save()
        #expect(!AccountParallelism.isParallel(context: context, now: now))
    }

    /// A zero-cost row is a bucket that exists, not usage.
    @MainActor
    @Test func aRowWithNoTokensIsNotActivity() throws {
        let context = ModelContext(try makeContainer())
        let now = Date()
        let today = TokenSample.formatDate(now)
        day(context, "work", today, cost: 5)
        context.insert(AccountDailyAggregate(
            accountId: "personal", date: today, model: "m",
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: 0))
        try context.save()
        #expect(!AccountParallelism.isParallel(context: context, now: now))
    }

    /// Genuine overlap — two logins live at the same instant — counts however
    /// long ago it was. Someone who has ever run them in parallel is running a
    /// parallel setup.
    @MainActor
    @Test func everOverlappingActivationsCount() throws {
        let context = ModelContext(try makeContainer())
        let now = Date()
        day(context, "work", TokenSample.formatDate(now), cost: 5)
        let start = now.addingTimeInterval(-10 * 86_400)
        context.insert(AccountActivation(
            accountId: "work", startedAt: start,
            endedAt: start.addingTimeInterval(7_200), rootPath: nil, source: "test"))
        context.insert(AccountActivation(
            accountId: "personal", startedAt: start.addingTimeInterval(3_600),
            endedAt: start.addingTimeInterval(10_800), rootPath: nil, source: "test"))
        try context.save()
        #expect(AccountParallelism.isParallel(context: context, now: now))
    }
}
