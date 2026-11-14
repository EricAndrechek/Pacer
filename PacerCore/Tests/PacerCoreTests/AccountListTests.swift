import Foundation
import Observation
import SwiftData
import Testing
@testable import PacerCore

// #413: the window shell's title and the toolbar's account menu read
// `AccountList`, which reads `Account` off the main thread when a writer says
// it saved (`AccountWriteSignal`), instead of a `@Query` that re-fetched on
// every save. Fictional ids throughout.

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(for: Schema(PacerStore.allModelTypes),
                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

@MainActor
private func insert(_ container: ModelContainer, _ accounts: [Account]) throws {
    let context = ModelContext(container)
    for a in accounts { context.insert(a) }
    try context.save()
}

@MainActor
private func account(_ id: String, active: Bool = false, slot: Int? = nil,
                     email: String? = nil, five: Double? = nil) -> Account {
    let a = Account(id: id, organizationId: id, displayName: "Claude account (max)",
                    isActive: active, firstSeenAt: t0, lastSeenAt: t0,
                    emailAddress: email, latestFiveHourPct: five,
                    latestPolledAt: five == nil ? nil : t0)
    a.switcherSlot = slot
    return a
}

/// Change one row and save, on a context of its own, as a writer would.
@MainActor
private func write(_ container: ModelContainer, _ id: String, _ change: (Account) -> Void) throws {
    let context = ModelContext(container)
    let row = try #require(try context.fetch(FetchDescriptor<Account>(
        predicate: #Predicate { $0.id == id })).first)
    change(row)
    try context.save()
}

/// Whether `read` was assigned after this was made. An `@Observable` property
/// notifies on assignment, equal value or not, so this is what "published"
/// means to a view.
private final class Fired: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    var value: Bool { lock.withLock { fired } }
    func set() { lock.withLock { fired = true } }

    @MainActor
    static func watching(_ read: @escaping @MainActor () -> Void) -> Fired {
        let flag = Fired()
        withObservationTracking { read() } onChange: { flag.set() }
        return flag
    }
}

/// Wait for the list to have read every write it was told of, and for `ready`.
/// A post from off the main thread reaches the list a hop later, so settling
/// once is not enough.
@MainActor
private func until(_ list: AccountList, _ ready: () -> Bool) async {
    for _ in 0..<200 {
        await list.settled()
        if ready() && list.loadedGeneration == list.generation { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("the list never caught up")
}

@Suite("Account list")
@MainActor
struct AccountListTests {

    @Test("reads every account on start, in store order, off the main thread")
    func readsOnStart() async throws {
        let container = try makeContainer()
        try insert(container, [account("org-b", active: true, five: 40), account("org-a", slot: 1)])
        let list = AccountList(center: NotificationCenter())
        list.start(container: container)
        await list.settled()

        let rows = try ModelContext(container).fetch(FetchDescriptor<Account>())
        #expect(list.accounts.map(\.id) == rows.map(\.id))
        #expect(list.accounts.map(\.label) == rows.map(\.label))
        #expect(list.readings["org-b"]?.fiveHourPct == 40)
        #expect(list.readings["org-b"]?.polledAt == t0)
        #expect(list.readings["org-a"]?.fiveHourPct == nil)
        #expect(AccountList.read(container)
                == AccountList.Snapshot(accounts: list.accounts, readings: list.readings))
    }

    /// The toolbar lists `accounts.sorted(by: Account.listOrder)` and marks
    /// `isActive`, exactly as it did from the `@Query`'s rows.
    @Test("same order and signed-in marker as the rows themselves")
    func sameOrderAndMarker() async throws {
        let container = try makeContainer()
        try insert(container, [
            account("org-c"), account("org-a", active: true),
            account("org-b", slot: 2), account("org-d", slot: 1),
        ])
        let list = AccountList(center: NotificationCenter())
        list.start(container: container)
        await list.settled()

        let rows = try ModelContext(container).fetch(FetchDescriptor<Account>())
        #expect(list.accounts.sorted(by: Account.listOrder).map(\.id)
                == rows.sorted(by: Account.listOrder).map(\.id))
        #expect(list.accounts.sorted(by: Account.listOrder).map(\.id) == ["org-d", "org-b", "org-a", "org-c"])
        #expect(list.accounts.filter(\.isActive).map(\.id) == ["org-a"])
    }

    @Test("every signal bumps the generation, one at a time, and reads again")
    func generationIsMonotonic() async throws {
        let center = NotificationCenter()
        let container = try makeContainer()
        try insert(container, [account("org-a", active: true)])
        let list = AccountList(center: center)
        list.start(container: container)
        await list.settled()
        #expect(list.generation == 0)

        var seen: [UInt64] = []
        for _ in 0..<5 {
            AccountWriteSignal.post(center: center)
            seen.append(list.generation)
        }
        #expect(seen == [1, 2, 3, 4, 5])
        // Five posts while a read runs coalesce; what is published is read
        // after the last of them.
        await list.settled()
        #expect(list.loadedGeneration == 5)
    }

    @Test("a signalled write is read: a rename reaches the menu, a poll the title")
    func aSignalReadsAgain() async throws {
        let center = NotificationCenter()
        let container = try makeContainer()
        try insert(container, [account("org-a", active: true, five: 10), account("org-b")])
        let list = AccountList(center: center)
        list.start(container: container)
        await list.settled()

        try write(container, "org-b") { $0.displayName = "Side project" }
        AccountWriteSignal.post(center: center)
        await list.settled()
        #expect(list.entry(id: "org-b")?.label == "Side project")

        let later = t0.addingTimeInterval(60)
        try write(container, "org-a") { $0.latestFiveHourPct = 11; $0.latestPolledAt = later }
        AccountWriteSignal.post(center: center)
        await list.settled()
        #expect(list.readings["org-a"]?.fiveHourPct == 11)
        #expect(list.readings["org-a"]?.polledAt == later)
    }

    @Test("no signal, no read: a save alone changes nothing")
    func noSignalNoRead() async throws {
        let container = try makeContainer()
        try insert(container, [account("org-a", active: true)])
        let list = AccountList(center: NotificationCenter())
        list.start(container: container)
        await list.settled()

        try write(container, "org-a") { $0.displayName = "Renamed" }
        await list.settled()
        #expect(list.entry(id: "org-a")?.label == "Claude account (max)")
    }

    /// `lastSeenAt` moves on every poll; the plan, the extra-usage cents and
    /// the first-seen date are not shown either. None of them may redraw the
    /// shell or the toolbar.
    @Test("a write of nothing shown publishes nothing")
    func anUnshownWriteDoesNotRepublish() async throws {
        let center = NotificationCenter()
        let container = try makeContainer()
        try insert(container, [account("org-a", active: true, five: 10)])
        let list = AccountList(center: center)
        list.start(container: container)
        await list.settled()

        let accountsFired = Fired.watching { _ = list.accounts }
        let readingsFired = Fired.watching { _ = list.readings }
        try write(container, "org-a") {
            $0.lastSeenAt = t0.addingTimeInterval(3_600)
            $0.firstSeenAt = t0.addingTimeInterval(-3_600)
            $0.subscriptionType = "max"
            $0.rateLimitTier = "default_claude_max_20x"
            $0.latestExtraUsageCents = 1_250
        }
        AccountWriteSignal.post(center: center)
        await list.settled()

        #expect(list.loadedGeneration == 1, "it did read")
        #expect(!accountsFired.value)
        #expect(!readingsFired.value)
    }

    /// The toolbar shows no readings, so a poll must leave it alone; the title
    /// shows no labels beyond the scope's account.
    @Test("a new reading publishes the readings alone, a rename the accounts alone")
    func eachHalfPublishesAlone() async throws {
        let center = NotificationCenter()
        let container = try makeContainer()
        try insert(container, [account("org-a", active: true, five: 10)])
        let list = AccountList(center: center)
        list.start(container: container)
        await list.settled()

        var accountsFired = Fired.watching { _ = list.accounts }
        var readingsFired = Fired.watching { _ = list.readings }
        try write(container, "org-a") { $0.latestFiveHourPct = 12; $0.latestPolledAt = t0 + 60 }
        AccountWriteSignal.post(center: center)
        await list.settled()
        #expect(!accountsFired.value)
        #expect(readingsFired.value)

        accountsFired = Fired.watching { _ = list.accounts }
        readingsFired = Fired.watching { _ = list.readings }
        try write(container, "org-a") { $0.emailAddress = "work@example.com" }
        AccountWriteSignal.post(center: center)
        await list.settled()
        #expect(accountsFired.value)
        #expect(!readingsFired.value)
        #expect(list.entry(id: "org-a")?.label == "work@example.com")

        accountsFired = Fired.watching { _ = list.accounts }
        try write(container, "org-a") { $0.isActive = false }
        AccountWriteSignal.post(center: center)
        await list.settled()
        #expect(accountsFired.value, "the signed-in marker is shown")
    }

    /// The shell's title follows `UsageScope.limitAccountId`: the picked
    /// account, else the signed-in one, else the first.
    @Test("scope switching picks the same account the shell always did")
    func scopeSwitching() async throws {
        let container = try makeContainer()
        try insert(container, [account("org-a"), account("org-b", active: true), account("org-c")])
        let list = AccountList(center: NotificationCenter())
        list.start(container: container)
        await list.settled()

        #expect(list.limitAccount("org-c")?.id == "org-c")
        #expect(list.limitAccount("org-a")?.id == "org-a")
        #expect(list.limitAccount(nil)?.id == "org-b")
        #expect(list.limitAccount("org-gone")?.id == "org-b")
        #expect(list.entry(id: nil) == nil)
        #expect(list.entry(id: "org-gone") == nil)

        let none = try makeContainer()
        try insert(none, [account("org-x"), account("org-y")])
        list.start(container: none)
        await list.settled()
        let first = try ModelContext(none).fetch(FetchDescriptor<Account>()).first?.id
        #expect(list.limitAccount(nil)?.id == first)
    }

    @Test("a restart reads the new store and forgets the old one")
    func restartReadsTheNewStore() async throws {
        let a = try makeContainer(), b = try makeContainer()
        try insert(a, [account("org-a", active: true)])
        try insert(b, [account("org-b", active: true)])
        let list = AccountList(center: NotificationCenter())
        list.start(container: a)
        list.start(container: b)
        await list.settled()
        #expect(list.accounts.map(\.id) == ["org-b"])

        // The same store again is not a restart.
        let fired = Fired.watching { _ = list.accounts }
        list.start(container: b)
        await list.settled()
        #expect(!fired.value)
    }
}

// MARK: - Every writer says so, after its save

/// What a fresh context read at the moment `sender` posted the signal.
private final class AtPost<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    private var observer: (any NSObjectProtocol)?

    init(sender: AnyObject, read: @escaping @Sendable () -> Value) {
        observer = NotificationCenter.default.addObserver(
            forName: AccountWriteSignal.name, object: sender, queue: nil
        ) { [weak self] _ in
            let value = read()
            self?.lock.withLock { self?.values.append(value) }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var seen: [Value] { lock.withLock { values } }
}

private func row(_ container: ModelContainer, _ id: String) -> (label: String, active: Bool, five: Double?)? {
    let rows = (try? ModelContext(container).fetch(FetchDescriptor<Account>(
        predicate: #Predicate { $0.id == id }))) ?? []
    return rows.first.map { ($0.label, $0.isActive, $0.latestFiveHourPct) }
}

private func keychainBlob() throws -> Data {
    try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
        "accessToken": "tok-413",
        "expiresAt": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000,
    ]])
}

private func poller(_ container: ModelContainer,
                    switcher: SwitcherUsageCache.Contents = .empty) throws -> OAuthPoller {
    let blob = try keychainBlob()
    let client = OAuthClient(
        keychain: KeychainOAuth(rawReader: { .success(blob) }),
        transport: { _ in
            try HTTPOutcome.success(
                jsonBody: #"{"five_hour":{"utilization":42,"resets_at":"2026-05-06T17:00:00Z"}}"#,
                headers: ["anthropic-organization-id": "org-413"]).materialize()
        },
        desktopEnabled: { false })
    return OAuthPoller(client: client, container: container, clock: TestClock(),
                       switcherCache: { switcher })
}

/// Each writer posts after its save, so a reader that hears it finds the write;
/// and a list listening on the default center catches up from that post alone.
@Suite("Account writers signal after their save")
@MainActor
struct AccountWriterSignalTests {

    @Test("a poll")
    func poll() async throws {
        let container = try makeContainer()
        let poller = try poller(container)
        let probe = AtPost(sender: poller) { row(container, "org-413")?.five }
        let list = AccountList(center: .default)
        list.start(container: container)

        _ = await poller.runOnce()
        #expect(probe.seen.contains(42))
        await until(list) { list.readings["org-413"]?.fiveHourPct == 42 }
    }

    @Test("a rename")
    func rename() async throws {
        let container = try makeContainer()
        try insert(container, [account("org-413", active: true)])
        let poller = try poller(container)
        let probe = AtPost(sender: poller) { row(container, "org-413")?.label }
        let list = AccountList(center: .default)
        list.start(container: container)

        await poller.renameAccount(id: "org-413", to: "Work")
        #expect(probe.seen == ["Work"])
        await until(list) { list.entry(id: "org-413")?.label == "Work" }
    }

    @Test("the active-account switch")
    func activeSwitch() async throws {
        let container = try makeContainer()
        try insert(container, [account("org-a", active: true), account("org-b")])
        let poller = try poller(container)
        await poller.stopPublishingScopeForTesting()
        let probe = AtPost(sender: poller) { row(container, "org-b")?.active }
        let list = AccountList(center: .default)
        list.start(container: container)

        await poller.setActiveAccount(id: "org-b")
        #expect(probe.seen.contains(true))
        #expect(!probe.seen.contains(false))
        await until(list) { list.accounts.first(where: \.isActive)?.id == "org-b" }
    }

    @Test("an account created from the switcher's roster")
    func switcherRoster() async throws {
        let container = try makeContainer()
        let roster = SwitcherUsageCache.Contents(
            accounts: [.init(organizationId: "org-roster", emailAddress: "side@example.com", slot: 2)],
            readings: [])
        let poller = try poller(container, switcher: roster)
        let probe = AtPost(sender: poller) { row(container, "org-roster")?.label }
        let list = AccountList(center: .default)
        list.start(container: container)

        await poller.ingestSwitcherCacheNow()
        #expect(probe.seen == ["side@example.com"])
        await until(list) { list.entry(id: "org-roster")?.switcherSlot == 2 }
    }
}

@Suite("The trail recorder signals its labels")
@ScanActor
struct AccountTrailRecorderSignalTests {

    @Test("the live login's email, after the save")
    func labels() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Account(id: "org-413", organizationId: "org-413", displayName: "Claude account (max)",
                               isActive: true, firstSeenAt: t0, lastSeenAt: t0))
        try context.save()
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"oauthAccount":{"organizationUuid":"org-413","emailAddress":"me@example.com"}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let recorder = AccountTrailRecorder(context: context, homeDirectory: home)
        let probe = AtPost(sender: recorder) { row(container, "org-413")?.label }
        let list = await MainActor.run { AccountList(center: .default) }
        await list.start(container: container)

        _ = recorder.poll()
        #expect(probe.seen == ["me@example.com"])
        await Self.waitForLabel(list, "org-413", "me@example.com")
    }

    @MainActor
    private static func waitForLabel(_ list: AccountList, _ id: String, _ label: String) async {
        await until(list) { list.entry(id: id)?.label == label }
    }
}
