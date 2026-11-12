import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The menu-bar label's data source (PACER-19). The label used to hold four
/// `@Query`s, which re-fetched on the main thread on every save of the store;
/// it now reads through `MenuBarLabelFeed`, off the main thread, when a key it
/// shows changes. These pin each trigger (a scan cycle that wrote turns, a
/// scope switch, a new day, a rate-limit write, a pinned chip) and that a save
/// on its own reads nothing.
@Suite("Menu-bar label feed")
@MainActor
struct MenuBarLabelFeedTests {

    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static var today: String { TokenSample.formatDate(now) }
    static var yesterday: String { TokenSample.formatDate(now.addingTimeInterval(-86_400)) }

    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: DailyAggregate.self, AccountDailyAggregate.self, TokenSample.self,
            RateLimitSample.self, UsageLimitSample.self, Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    static func daily(_ day: String, _ model: String, cost: Double, tokens: Int64) -> DailyAggregate {
        DailyAggregate(date: day, model: model, inputTokens: tokens, totalCostUSD: cost)
    }

    static func accountDaily(_ account: String, _ day: String, _ model: String,
                             cost: Double, tokens: Int64) -> AccountDailyAggregate {
        AccountDailyAggregate(accountId: account, date: day, model: model,
                              inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0,
                              cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                              totalCostUSD: cost)
    }

    static func turn(_ model: String, at offset: TimeInterval, account: String? = nil) -> TokenSample {
        let when = now.addingTimeInterval(offset)
        let s = TokenSample(sampledAt: when, date: TokenSample.formatDate(when), model: model,
                            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
                            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0)
        s.accountId = account
        return s
    }

    static func reading(_ account: String, _ window: String, _ pct: Double,
                        at offset: TimeInterval = 0) -> RateLimitSample {
        RateLimitSample(sampledAt: now.addingTimeInterval(offset), window: window,
                        usedPercentage: pct, resetsAt: nil, source: RateLimitSource.oauth,
                        accountId: account)
    }

    static func account(_ id: String, name: String, active: Bool) -> Account {
        Account(id: id, organizationId: id, displayName: name, isActive: active,
                firstSeenAt: now, lastSeenAt: now)
    }

    static func usageKey(day: String = today, account: String? = nil, writes: UInt64,
                         today: Bool = true, model: Bool = true) -> MenuBarLabelFeed.UsageKey {
        MenuBarLabelFeed.UsageKey(day: day, account: account, writes: writes, today: today, model: model)
    }

    // MARK: - Usage

    /// The trigger the label keys on is `SampleWriteSignal.generation`. A save
    /// the scanner did not announce, or a poll, leaves it — and so the key —
    /// alone, and the feed does not read; a cycle that wrote turns moves it,
    /// and the next read shows what that cycle wrote.
    @Test func aScanCycleThatWroteTurnsRereadsAndASaveAloneReadsNothing() async throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(Self.daily(Self.today, "claude-opus-5", cost: 1.25, tokens: 100))
        context.insert(Self.turn("claude-opus-5", at: -60))
        try context.save()

        let center = NotificationCenter()
        let signal = SampleWriteSignal(center: center)
        let feed = MenuBarLabelFeed()

        await feed.loadUsage(Self.usageKey(writes: signal.generation), from: container)
        #expect(feed.usageReads == 1)
        #expect(abs(feed.usage.costUSD - 1.25) < 1e-9)
        #expect(feed.usage.tokens == 100)
        #expect(feed.usage.latestModel == "claude-opus-5")

        // New rows saved, nothing announced: what a `@Query` would have
        // re-fetched for. The key has not moved, so nothing is read.
        context.insert(Self.daily(Self.today, "claude-sonnet-5", cost: 0.5, tokens: 40))
        context.insert(Self.turn("claude-sonnet-5", at: -10))
        try context.save()
        center.post(name: .pacerScanCycleDidComplete,
                    object: ScanCycleSummary(rateLimitsChanged: true, rateLimitAccountId: "orgA"))
        await feed.loadUsage(Self.usageKey(writes: signal.generation), from: container)
        #expect(feed.usageReads == 1)
        #expect(abs(feed.usage.costUSD - 1.25) < 1e-9)

        // The cycle that wrote them is announced.
        center.post(name: .pacerScanCycleDidComplete, object: ScanCycleSummary(samplesChanged: true))
        await feed.loadUsage(Self.usageKey(writes: signal.generation), from: container)
        #expect(feed.usageReads == 2)
        #expect(abs(feed.usage.costUSD - 1.75) < 1e-9)
        #expect(feed.usage.tokens == 140)
        #expect(feed.usage.latestModel == "claude-sonnet-5")
    }

    /// A scope switch is a new key, read from that account's own rows, with
    /// Claude Code quiet and nothing written. "All accounts" reads the global
    /// rollup and the newest turn of any account.
    @Test func aScopeSwitchReadsThatAccountsRows() async throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(Self.daily(Self.today, "claude-opus-5", cost: 3, tokens: 30))
        context.insert(Self.accountDaily("orgA", Self.today, "claude-opus-5", cost: 1, tokens: 10))
        context.insert(Self.accountDaily("orgB", Self.today, "claude-opus-5", cost: 2, tokens: 20))
        context.insert(Self.turn("claude-opus-5", at: -120, account: "orgA"))
        context.insert(Self.turn("claude-haiku-5", at: -30, account: "orgB"))
        try context.save()
        let feed = MenuBarLabelFeed()

        await feed.loadUsage(Self.usageKey(account: "orgA", writes: 0), from: container)
        #expect(abs(feed.usage.costUSD - 1) < 1e-9)
        #expect(feed.usage.latestModel == "claude-opus-5")

        await feed.loadUsage(Self.usageKey(account: "orgB", writes: 0), from: container)
        #expect(abs(feed.usage.costUSD - 2) < 1e-9)
        #expect(feed.usage.latestModel == "claude-haiku-5")

        await feed.loadUsage(Self.usageKey(account: nil, writes: 0), from: container)
        #expect(abs(feed.usage.costUSD - 3) < 1e-9)
        #expect(feed.usage.tokens == 30)
        #expect(feed.usage.latestModel == "claude-haiku-5")
        #expect(feed.usageReads == 3)
    }

    /// Midnight is a new key: the label stops reading yesterday's rows without
    /// anything being written or the view being rebuilt.
    @Test func aNewDayReadsThatDaysRows() async throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(Self.daily(Self.yesterday, "claude-opus-5", cost: 9, tokens: 900))
        context.insert(Self.daily(Self.today, "claude-opus-5", cost: 0.1, tokens: 1))
        try context.save()
        let feed = MenuBarLabelFeed()

        await feed.loadUsage(Self.usageKey(day: Self.yesterday, writes: 0, model: false), from: container)
        #expect(abs(feed.usage.costUSD - 9) < 1e-9)
        await feed.loadUsage(Self.usageKey(day: Self.today, writes: 0, model: false), from: container)
        #expect(abs(feed.usage.costUSD - 0.1) < 1e-9)
        #expect(feed.usage.tokens == 1)
    }

    /// Each part is read only when a chip shows it.
    @Test func onlyWhatAChipShowsIsRead() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(Self.daily(Self.today, "claude-opus-5", cost: 1, tokens: 10))
        context.insert(Self.turn("claude-opus-5", at: -60))
        try context.save()

        let modelOnly = MenuBarLabelFeed.readUsage(
            Self.usageKey(writes: 0, today: false, model: true), in: ModelContext(container))
        #expect(modelOnly.today.isEmpty)
        #expect(modelOnly.latestModel == "claude-opus-5")
        let todayOnly = MenuBarLabelFeed.readUsage(
            Self.usageKey(writes: 0, today: true, model: false), in: ModelContext(container))
        #expect(todayOnly.today.count == 1)
        #expect(todayOnly.latestModel == nil)
    }

    /// Through the feed, end to end: a scope switch while the previous scope's
    /// read is running ends on the new scope's numbers, and asking again for
    /// what is showing reads nothing. The ordering itself is pinned
    /// deterministically on the lane, below.
    @Test func aSwitchDuringAReadEndsOnTheNewScope() async throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(Self.accountDaily("orgA", Self.today, "claude-opus-5", cost: 1, tokens: 10))
        context.insert(Self.accountDaily("orgB", Self.today, "claude-opus-5", cost: 2, tokens: 20))
        try context.save()
        let feed = MenuBarLabelFeed()

        // Created first, so it runs once the call below suspends on its read.
        let later = Task { @MainActor in
            await feed.loadUsage(Self.usageKey(account: "orgB", writes: 0, model: false), from: container)
        }
        await feed.loadUsage(Self.usageKey(account: "orgA", writes: 0, model: false), from: container)
        await later.value
        #expect(feed.usageReads == 2)
        #expect(abs(feed.usage.costUSD - 2) < 1e-9)

        await feed.loadUsage(Self.usageKey(account: "orgB", writes: 0, model: false), from: container)
        #expect(feed.usageReads == 2)
    }

    // MARK: - The lane's ordering

    /// A read that waits until the test lets it finish, and says when it has
    /// started, so a test can ask for keys while it is in flight.
    final class HeldRead: @unchecked Sendable {
        private let release = DispatchSemaphore(value: 0)
        private let held: String
        let started: AsyncStream<String>
        private let startedContinuation: AsyncStream<String>.Continuation

        init(holding key: String) {
            held = key
            let (stream, continuation) = AsyncStream<String>.makeStream()
            started = stream
            startedContinuation = continuation
        }

        func read(_ key: String) -> String {
            startedContinuation.yield(key)
            // Blocks a detached task's thread, never the main actor's. Bounded,
            // so a lane that reads the held key twice fails the test rather
            // than hanging it.
            if key == held { _ = release.wait(timeout: .now() + 2) }
            return key
        }

        func finish() { release.signal() }
    }

    @MainActor
    final class Applied {
        var values: [String] = []
    }

    /// Keys asked for while a read runs are read after it, and only the latest
    /// of them: a detached read is not cancelled with the `.task` that started
    /// it, so without this an old scope's answer could land after the new
    /// one's and stay.
    @Test func keysAskedForDuringAReadAreReadAfterItLatestOnly() async {
        let held = HeldRead(holding: "A")
        let lane = KeyedReadLane<String, String>()
        let applied = Applied()
        let read: @Sendable (String) -> String = { held.read($0) }

        let first = Task { @MainActor in
            await lane.load("A", read: read, apply: { applied.values.append($0) })
        }
        var starts = held.started.makeAsyncIterator()
        #expect(await starts.next() == "A")
        // Both return at once; C replaces B in the queue.
        await lane.load("B", read: read, apply: { applied.values.append($0) })
        await lane.load("C", read: read, apply: { applied.values.append($0) })
        held.finish()
        await first.value

        #expect(applied.values == ["A", "C"])
        #expect(lane.reads == 2)
        #expect(lane.shown == "C")
        // What is showing is not read again.
        await lane.load("C", read: read, apply: { applied.values.append($0) })
        #expect(lane.reads == 2)
    }

    /// Asking again for the key in flight is the latest wish: whatever was
    /// queued in between is dropped rather than read after it and left showing.
    @Test func askingAgainForTheKeyInFlightDropsTheQueue() async {
        let held = HeldRead(holding: "A")
        let lane = KeyedReadLane<String, String>()
        let applied = Applied()
        let read: @Sendable (String) -> String = { held.read($0) }

        let first = Task { @MainActor in
            await lane.load("A", read: read, apply: { applied.values.append($0) })
        }
        var starts = held.started.makeAsyncIterator()
        #expect(await starts.next() == "A")
        await lane.load("B", read: read, apply: { applied.values.append($0) })
        await lane.load("A", read: read, apply: { applied.values.append($0) })
        held.finish()
        await first.value

        #expect(applied.values == ["A"])
        #expect(lane.reads == 1)
    }

    // MARK: - Limits

    /// A rate-limit write is a new key; the scope picks whose windows; "all
    /// accounts" with no known login falls back to the store's active row.
    @Test func limitsFollowTheWriteSignalAndTheScope() async throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(Self.account("orgA", name: "work", active: true))
        context.insert(Self.account("orgB", name: "personal", active: false))
        context.insert(Self.reading("orgA", RateLimitWindowName.fiveHour, 40, at: -60))
        context.insert(Self.reading("orgB", RateLimitWindowName.fiveHour, 70, at: -60))
        try context.save()
        let feed = MenuBarLabelFeed()

        await feed.loadLimits(.init(writes: 1, scope: nil, active: nil, pinned: []), from: container)
        #expect(feed.limits.account == "orgA")
        #expect(feed.limits.windows.fixed.first?.usedPercentage == 40)
        // Nothing pinned, no names read.
        #expect(feed.limits.accountLabels.isEmpty)

        await feed.loadLimits(.init(writes: 1, scope: "orgB", active: "orgA", pinned: []), from: container)
        #expect(feed.limits.account == "orgB")
        #expect(feed.limits.windows.fixed.first?.usedPercentage == 70)

        // The same key again: nothing read, even with a new row saved.
        context.insert(Self.reading("orgB", RateLimitWindowName.fiveHour, 75))
        try context.save()
        let reads = feed.limitsReads
        await feed.loadLimits(.init(writes: 1, scope: "orgB", active: "orgA", pinned: []), from: container)
        #expect(feed.limitsReads == reads)
        #expect(feed.limits.windows.fixed.first?.usedPercentage == 70)

        // The poll that wrote it bumps the signal.
        await feed.loadLimits(.init(writes: 2, scope: "orgB", active: "orgA", pinned: []), from: container)
        #expect(feed.limitsReads == reads + 1)
        #expect(feed.limits.windows.fixed.first?.usedPercentage == 75)
    }

    /// A chip pinned to an account reads that account's windows and name,
    /// whatever the scope.
    @Test func aPinnedChipReadsItsAccountsWindowsAndName() async throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        context.insert(Self.account("orgA", name: "work", active: true))
        context.insert(Self.account("orgB", name: "personal", active: false))
        context.insert(Self.reading("orgA", RateLimitWindowName.sevenDay, 12))
        context.insert(Self.reading("orgB", RateLimitWindowName.sevenDay, 88))
        try context.save()
        let feed = MenuBarLabelFeed()

        await feed.loadLimits(.init(writes: 0, scope: nil, active: "orgA", pinned: ["orgB"]), from: container)
        #expect(feed.limits.windows.fixed.first?.usedPercentage == 12)
        #expect(feed.limits.pinned["orgB"]?.fixed.first?.usedPercentage == 88)
        #expect(feed.limits.accountLabels["orgB"] == "personal")
    }
}
