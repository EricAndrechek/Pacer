import Foundation
import Observation
import SwiftData
import Testing
@testable import PacerCore

/// The menu's dropdown data source (#408). The dropdown is always mounted, and
/// it held today's two `@Query`s and loaded its windows, the account list and
/// the parallelism mode on the main thread; it now reads through
/// `MenuDropdownFeed`, off the main thread, when a key it shows changes. These
/// pin each trigger (a scan cycle that wrote turns, the day, the scope, a
/// rate-limit write, the active login, the active clients, an opening), that
/// a save on its own reads nothing, and that the blocks say what the dropdown
/// said before.
@Suite("Menu dropdown feed")
@MainActor
struct MenuDropdownFeedTests {

    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static var today: String { TokenSample.formatDate(now) }
    static var yesterday: String { TokenSample.formatDate(now.addingTimeInterval(-86_400)) }

    /// Where `AccountParallelism` looks for session-mode profiles: empty, so
    /// a test never sees this Mac's own.
    static let home: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuDropdownFeedTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func makeContainer() throws -> ModelContainer {
        try PacerStore.makeInMemoryContainer()
    }

    static func account(_ id: String, name: String, active: Bool) -> Account {
        Account(id: id, organizationId: id, displayName: name, isActive: active,
                firstSeenAt: now, lastSeenAt: now)
    }

    static func reading(_ account: String, _ window: String, _ pct: Double,
                        at offset: TimeInterval = 0) -> RateLimitSample {
        RateLimitSample(sampledAt: now.addingTimeInterval(offset), window: window,
                        usedPercentage: pct, resetsAt: nil, source: RateLimitSource.oauth,
                        accountId: account)
    }

    static func todayKey(day: String = today, account: String? = nil, writes: UInt64) -> MenuBarLabelFeed.UsageKey {
        MenuBarLabelFeed.UsageKey(day: day, account: account, writes: writes, today: true, model: false)
    }

    static func limitsKey(writes: UInt64 = 0, scope: String? = nil, active: String? = nil,
                          clients: Int = 0, opening: Int = 0) -> MenuDropdownFeed.LimitsKey {
        MenuDropdownFeed.LimitsKey(writes: writes, scope: scope, active: active,
                                   clients: clients, opening: opening)
    }

    /// Two accounts, "work" signed in, each with a 5-hour reading.
    static func twoAccounts() throws -> ModelContainer {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(account("orgA", name: "work", active: true))
        context.insert(account("orgB", name: "personal", active: false))
        context.insert(reading("orgA", RateLimitWindowName.fiveHour, 40, at: -60))
        context.insert(reading("orgB", RateLimitWindowName.fiveHour, 70, at: -60))
        try context.save()
        return container
    }

    func load(_ feed: MenuDropdownFeed, _ key: MenuDropdownFeed.LimitsKey,
              clients: MenuDropdownFeed.ActiveClients = [:], _ container: ModelContainer) async {
        await feed.loadLimits(key, clients: clients, from: container, homeDirectory: Self.home)
    }

    /// Set when a tracked property is written.
    final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var fired: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    // MARK: - Today

    /// Nothing until the first read lands, so the row can say "—" rather
    /// than "$0.00". Then the trigger is `SampleWriteSignal`: a save the
    /// scanner did not announce, or a poll, reads nothing; a cycle that wrote
    /// turns reads what it wrote.
    @Test func todayFollowsTheScanCyclesThatWroteTurnsAndASaveAloneReadsNothing() async throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(DailyAggregate(date: Self.today, model: "claude-opus-5", inputTokens: 100, totalCostUSD: 1.25))
        try context.save()
        let center = NotificationCenter()
        let signal = SampleWriteSignal(center: center)
        let feed = MenuDropdownFeed()
        #expect(feed.today == nil)

        await feed.loadToday(Self.todayKey(writes: signal.generation), from: container)
        #expect(feed.todayReads == 1)
        #expect(abs((feed.today?.costUSD ?? 0) - 1.25) < 1e-9)

        // Saved, not announced: what a `@Query` re-fetched for on every save.
        context.insert(DailyAggregate(date: Self.today, model: "claude-sonnet-5", inputTokens: 40, totalCostUSD: 0.5))
        try context.save()
        center.post(name: .pacerScanCycleDidComplete,
                    object: ScanCycleSummary(rateLimitsChanged: true, rateLimitAccountId: "orgA"))
        await feed.loadToday(Self.todayKey(writes: signal.generation), from: container)
        #expect(feed.todayReads == 1)
        #expect(abs((feed.today?.costUSD ?? 0) - 1.25) < 1e-9)

        center.post(name: .pacerScanCycleDidComplete, object: ScanCycleSummary(samplesChanged: true))
        await feed.loadToday(Self.todayKey(writes: signal.generation), from: container)
        #expect(feed.todayReads == 2)
        #expect(abs((feed.today?.costUSD ?? 0) - 1.75) < 1e-9)
        // The dropdown shows no model: none is read.
        #expect(feed.today?.latestModel == nil)
    }

    /// A scope switch reads that account's own rows, with nothing written;
    /// "all accounts" reads the global rollup. Midnight reads the new day's.
    @Test func todayFollowsTheScopeAndTheDay() async throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(DailyAggregate(date: Self.yesterday, model: "claude-opus-5", inputTokens: 900, totalCostUSD: 9))
        context.insert(DailyAggregate(date: Self.today, model: "claude-opus-5", inputTokens: 30, totalCostUSD: 3))
        context.insert(AccountDailyAggregate(accountId: "orgA", date: Self.today, model: "claude-opus-5",
                                             inputTokens: 10, outputTokens: 0, cacheReadTokens: 0,
                                             cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                                             totalCostUSD: 1))
        try context.save()
        let feed = MenuDropdownFeed()

        await feed.loadToday(Self.todayKey(day: Self.yesterday, writes: 0), from: container)
        #expect(abs((feed.today?.costUSD ?? 0) - 9) < 1e-9)
        await feed.loadToday(Self.todayKey(writes: 0), from: container)
        #expect(abs((feed.today?.costUSD ?? 0) - 3) < 1e-9)
        await feed.loadToday(Self.todayKey(account: "orgA", writes: 0), from: container)
        #expect(abs((feed.today?.costUSD ?? 0) - 1) < 1e-9)
        #expect(feed.todayReads == 3)
    }

    // MARK: - Limits

    /// A rate-limit write is a new key; the same key with a new row saved
    /// reads nothing. The scope picks whose windows, and with two accounts the
    /// block is named and says whether it is the signed-in login.
    @Test func limitsFollowTheWriteSignalAndTheScope() async throws {
        let container = try Self.twoAccounts()
        let context = ModelContext(container)
        let feed = MenuDropdownFeed()
        #expect(feed.limits == nil)

        // "All accounts" with no login known yet: the store's active row.
        await load(feed, Self.limitsKey(writes: 1), container)
        var block = try #require(feed.limits?.blocks.first)
        #expect(feed.limits?.grouped == false)
        #expect(feed.limits?.blocks.count == 1)
        #expect(block.account == "orgA")
        #expect(block.name == "work")
        #expect(block.signedIn == true)
        #expect(block.readings.fixed.first?.usedPercentage == 40)

        await load(feed, Self.limitsKey(writes: 1, scope: "orgB", active: "orgA"), container)
        block = try #require(feed.limits?.blocks.first)
        #expect(block.account == "orgB")
        #expect(block.name == "personal")
        // Scoped to a login Claude Code is not using: "not signed in".
        #expect(block.signedIn == false)
        #expect(block.readings.fixed.first?.usedPercentage == 70)

        // The same key with a new row saved: nothing read.
        context.insert(Self.reading("orgB", RateLimitWindowName.fiveHour, 75))
        try context.save()
        let reads = feed.limitsReads
        await load(feed, Self.limitsKey(writes: 1, scope: "orgB", active: "orgA"), container)
        #expect(feed.limitsReads == reads)
        #expect(feed.limits?.blocks.first?.readings.fixed.first?.usedPercentage == 70)

        // The poll that wrote it bumps the signal.
        await load(feed, Self.limitsKey(writes: 2, scope: "orgB", active: "orgA"), container)
        #expect(feed.limitsReads == reads + 1)
        #expect(feed.limits?.blocks.first?.readings.fixed.first?.usedPercentage == 75)
    }

    /// A login switch under "all accounts" is a new key (`active`), and the
    /// block follows it with nothing written to the rate-limit table.
    @Test func limitsFollowTheActiveLogin() async throws {
        let container = try Self.twoAccounts()
        let context = ModelContext(container)
        let feed = MenuDropdownFeed()
        await load(feed, Self.limitsKey(active: "orgA"), container)
        #expect(feed.limits?.blocks.first?.account == "orgA")

        // The poller flips the store's row and the observable together.
        let accounts = try context.fetch(FetchDescriptor<Account>())
        for account in accounts { account.isActive = account.id == "orgB" }
        try context.save()
        await load(feed, Self.limitsKey(active: "orgB"), container)
        let block = try #require(feed.limits?.blocks.first)
        #expect(block.account == "orgB")
        #expect(block.name == "personal")
        #expect(block.signedIn == true)
        #expect(block.readings.fixed.first?.usedPercentage == 70)
    }

    /// Every opening re-reads (the names and grouping were fetched on every
    /// `body`, the opening's included), and a re-read that found nothing new
    /// assigns nothing, so it redraws nothing.
    @Test func everyOpeningRereadsAndOneThatFoundNothingNewRedrawsNothing() async throws {
        let container = try Self.twoAccounts()
        let feed = MenuDropdownFeed()
        await load(feed, Self.limitsKey(active: "orgA", opening: 0), container)
        #expect(feed.limitsReads == 1)

        let fired = Fired()
        withObservationTracking { _ = feed.limits } onChange: { fired.set() }
        await load(feed, Self.limitsKey(active: "orgA", opening: 1), container)
        #expect(feed.limitsReads == 2)
        #expect(!fired.fired)

        // An unsignalled change (a rename) shows at the next opening.
        let context = ModelContext(container)
        let work = try #require(try context.fetch(FetchDescriptor<Account>()).first { $0.id == "orgA" })
        work.displayName = "office"
        try context.save()
        await load(feed, Self.limitsKey(active: "orgA", opening: 2), container)
        #expect(fired.fired)
        #expect(feed.limits?.blocks.first?.name == "office")
    }

    /// Clients active on two accounts at once group the menu (#245): a block
    /// per active account, in list order, each named, the CLI's said as
    /// "signed in" and the others' listed. The clients generation is the key.
    @Test func clientsOnTwoAccountsGroupTheMenu() async throws {
        let container = try Self.twoAccounts()
        let feed = MenuDropdownFeed()
        await load(feed, Self.limitsKey(active: "orgA", clients: 0), clients: ["orgA": []], container)
        #expect(feed.limits?.grouped == false)

        await load(feed, Self.limitsKey(active: "orgA", clients: 1),
                   clients: ["orgA": [], "orgB": ["Desktop"]], container)
        let limits = try #require(feed.limits)
        #expect(limits.grouped)
        #expect(limits.blocks.map(\.account) == ["orgA", "orgB"])
        #expect(limits.blocks.map(\.name) == ["work", "personal"])
        #expect(limits.blocks.map(\.signedIn) == [true, nil])
        #expect(limits.blocks.map(\.clients) == [[], ["Desktop"]])
        #expect(limits.blocks.map { $0.readings.fixed.first?.usedPercentage } == [40, 70])
    }

    /// Accounts observed live at the same instant group every account,
    /// whatever is active now (`AccountParallelism`, read with the windows).
    @Test func concurrentAccountsGroupEveryAccount() async throws {
        let container = try Self.twoAccounts()
        let context = ModelContext(container)
        for (id, root) in [("orgA", "/profiles/a"), ("orgB", "/profiles/b")] {
            context.insert(AccountActivation(accountId: id, startedAt: Self.now.addingTimeInterval(-3_600),
                                             rootPath: root, source: AccountActivation.sourceObserved))
        }
        try context.save()
        let feed = MenuDropdownFeed()
        await load(feed, Self.limitsKey(active: "orgA"), container)
        #expect(feed.limits?.grouped == true)
        #expect(feed.limits?.blocks.map(\.account) == ["orgA", "orgB"])
    }

    /// One account: one unnamed block, nothing said about signing in.
    @Test func oneAccountIsOneUnnamedBlock() async throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(Self.account("orgA", name: "work", active: true))
        context.insert(Self.reading("orgA", RateLimitWindowName.sevenDay, 12))
        try context.save()
        let feed = MenuDropdownFeed()
        await load(feed, Self.limitsKey(), clients: ["orgA": []], container)
        let limits = try #require(feed.limits)
        #expect(!limits.grouped)
        #expect(limits.blocks.count == 1)
        #expect(limits.blocks.first?.account == "orgA")
        #expect(limits.blocks.first?.name == nil)
        #expect(limits.blocks.first?.signedIn == nil)
        #expect(limits.blocks.first?.readings.fixed.first?.usedPercentage == 12)
    }
}
