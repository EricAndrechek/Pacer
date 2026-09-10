import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// How the machine's accounts are used decides how much of a cramped surface
/// to spend on them. Costs add up; a 5-hour window does not — two accounts at
/// 60% are not 120% of anything, they are two caps on two clocks.
///
/// The distinction that matters is **sequential vs concurrent**, and it used to
/// be conflated: "more than one account had usage today" was treated as
/// parallel, which is true of anyone who simply *switched* accounts — the
/// commonest case there is, and the opposite of parallel. Measured on a real
/// machine: 37 activation spans, zero overlapping, zero pinned to a session
/// root, and the old test still said parallel.
///
/// Only two things now count, both definitive: a session-mode profile root (a
/// switcher handing a session its own `CLAUDE_CONFIG_DIR` exists precisely so
/// two accounts can run at once) and genuinely overlapping activation spans.
@Suite("Detecting parallel accounts")
struct AccountParallelismTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: AccountDailyAggregate.self, AccountActivation.self, Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// `mode` asks the store how many accounts exist before anything else, so
    /// the fixtures need real rows — the aggregates alone never implied one.
    @MainActor
    private func accounts(_ context: ModelContext, _ ids: [String]) {
        for id in ids {
            context.insert(Account(id: id, organizationId: id, displayName: id,
                                   isActive: id == ids.first,
                                   firstSeenAt: .distantPast, lastSeenAt: Date()))
        }
    }

    /// An empty directory, so the session-mode probe finds nothing and the
    /// tests are not at the mercy of whatever the developer has installed.
    private func emptyHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func day(_ context: ModelContext, _ account: String, _ date: String, cost: Double) {
        context.insert(AccountDailyAggregate(
            accountId: account, date: date, model: "m",
            inputTokens: 100, outputTokens: 0, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: cost))
    }

    @MainActor
    @Test func oneAccountIsSingle() throws {
        let context = ModelContext(try makeContainer())
        let now = Date()
        accounts(context, ["work"])
        day(context, "work", TokenSample.formatDate(now), cost: 5)
        try context.save()
        #expect(AccountParallelism.mode(context: context, homeDirectory: try emptyHome())
                == .single)
    }

    /// The correction. Two accounts both used today, with no overlap and no
    /// session root, is **switching** — and this used to report parallel.
    @MainActor
    @Test func twoAccountsUsedTodayIsSequentialNotConcurrent() throws {
        let context = ModelContext(try makeContainer())
        let now = Date()
        let today = TokenSample.formatDate(now)
        accounts(context, ["work", "personal"])
        day(context, "work", today, cost: 5)
        day(context, "personal", today, cost: 1)
        try context.save()
        #expect(AccountParallelism.mode(context: context, homeDirectory: try emptyHome())
                == .sequential)
        // Still a true fact, still worth reporting — just not parallelism.
        #expect(AccountParallelism.accountsActiveToday(context: context, now: now) == 2)
    }

    /// Yesterday's second account does not make today parallel — that is
    /// switching, which is exactly the setup that wants one account shown.
    @MainActor
    @Test func yesterdaysOtherAccountIsStillSequential() throws {
        let context = ModelContext(try makeContainer())
        let now = Date()
        let yesterday = TokenSample.formatDate(now.addingTimeInterval(-86_400))
        accounts(context, ["work", "personal"])
        day(context, "work", TokenSample.formatDate(now), cost: 5)
        day(context, "personal", yesterday, cost: 1)
        try context.save()
        #expect(AccountParallelism.mode(context: context, homeDirectory: try emptyHome())
                == .sequential)
    }

    /// A zero-cost row is a bucket that exists, not usage.
    @MainActor
    @Test func aRowWithNoTokensIsNotActivity() throws {
        let context = ModelContext(try makeContainer())
        let now = Date()
        let today = TokenSample.formatDate(now)
        accounts(context, ["work", "personal"])
        day(context, "work", today, cost: 5)
        context.insert(AccountDailyAggregate(
            accountId: "personal", date: today, model: "m",
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: 0))
        try context.save()
        #expect(AccountParallelism.accountsActiveToday(context: context, now: now) == 1)
    }

    /// Genuine overlap — two logins live at the same instant — counts however
    /// long ago it was. Someone who has ever run them in parallel is running a
    /// parallel setup.
    @MainActor
    @Test func everOverlappingActivationsAreConcurrent() throws {
        let context = ModelContext(try makeContainer())
        let now = Date()
        accounts(context, ["work", "personal"])
        day(context, "work", TokenSample.formatDate(now), cost: 5)
        let start = now.addingTimeInterval(-10 * 86_400)
        context.insert(AccountActivation(
            accountId: "work", startedAt: start,
            endedAt: start.addingTimeInterval(7_200), rootPath: nil, source: "test"))
        context.insert(AccountActivation(
            accountId: "personal", startedAt: start.addingTimeInterval(3_600),
            endedAt: start.addingTimeInterval(10_800), rootPath: nil, source: "test"))
        try context.save()
        #expect(AccountParallelism.mode(context: context, homeDirectory: try emptyHome())
                == .concurrent)
    }

    /// The definitive signal, and the one that needs no inference: a switcher
    /// has handed a session its own `CLAUDE_CONFIG_DIR`. That directory exists
    /// only so two accounts can run at once.
    @MainActor
    @Test func aSessionProfileRootMeansConcurrent() throws {
        let context = ModelContext(try makeContainer())
        accounts(context, ["work", "personal"])
        try context.save()

        let home = try emptyHome()
        let profile = home.appendingPathComponent(".claude-swap-backup/sessions/2-personal")
        try FileManager.default.createDirectory(
            at: profile.appendingPathComponent("projects"), withIntermediateDirectories: true)
        #expect(AccountParallelism.usesSessionProfiles(homeDirectory: home))
        #expect(AccountParallelism.mode(context: context, homeDirectory: home) == .concurrent)
    }
}
