import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// #352: plan and tier history. `Account` keeps only the current values;
/// `Account.observePlan` appends a dated `AccountPlanEvent` on the first
/// observation and on every change, and nothing on an unchanged poll.
@Suite("Account plan history")
struct AccountPlanEventTests {

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let minute: TimeInterval = 60
    static let day: TimeInterval = 86_400
    static let max5 = "default_claude_max_5x", max20 = "default_claude_max_20x"

    static func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema(PacerStore.allModelTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    static func account(_ context: ModelContext, sub: String? = nil, tier: String? = nil) -> Account {
        let a = Account(id: "acct-a", organizationId: "acct-a", displayName: "A", isActive: true,
                        firstSeenAt: t0, lastSeenAt: t0, subscriptionType: sub, rateLimitTier: tier)
        context.insert(a)
        return a
    }

    static func events(_ context: ModelContext) throws -> [AccountPlanEvent] {
        try AccountPlanEvent.history(for: "acct-a", in: context)
    }

    @Test func theFirstObservationIsRecorded() throws {
        let context = try Self.context()
        let a = Self.account(context)
        a.observePlan(subscriptionType: "max", rateLimitTier: Self.max5, at: Self.t0,
                      reportedBy: "keychain", in: context)
        let e = try Self.events(context)
        #expect(e.count == 1)
        #expect(e.first?.kind == AccountPlanEvent.kindFirst)
        #expect(e.first?.subscriptionType == "max" && e.first?.rateLimitTier == Self.max5)
        #expect(e.first?.previousSubscriptionType == nil && e.first?.previousRateLimitTier == nil)
        #expect(e.first?.observedAt == Self.t0)
        #expect(e.first?.reportedBy == "keychain")
        #expect(a.rateLimitTier == Self.max5)
    }

    /// An account a build without the table already knew: its values are on
    /// the row, and the first poll after the upgrade records them once.
    @Test func anAccountKnownBeforeTheTableGetsOneFirstObservation() throws {
        let context = try Self.context()
        let a = Self.account(context, sub: "max", tier: Self.max20)
        a.observePlan(subscriptionType: "max", rateLimitTier: Self.max20, at: Self.t0, in: context)
        a.observePlan(subscriptionType: "max", rateLimitTier: Self.max20, at: Self.t0 + Self.day, in: context)
        let e = try Self.events(context)
        #expect(e.map(\.kind) == [AccountPlanEvent.kindFirst])
    }

    @Test func unchangedPollsWriteNothing() throws {
        let context = try Self.context()
        let a = Self.account(context)
        for i in 0..<500 {
            a.observePlan(subscriptionType: "max", rateLimitTier: Self.max5,
                          at: Self.t0 + Double(i) * Self.minute, in: context)
        }
        #expect(try Self.events(context).count == 1)
    }

    @Test func aChangeAppendsAnEventCarryingWhatItReplaced() throws {
        let context = try Self.context()
        let a = Self.account(context)
        a.observePlan(subscriptionType: "pro", rateLimitTier: "default_claude_ai", at: Self.t0, in: context)
        let upgrade = Self.t0 + 10 * Self.day
        a.observePlan(subscriptionType: "max", rateLimitTier: Self.max20, at: upgrade, in: context)
        let e = try Self.events(context)
        #expect(e.count == 2)
        let change = try #require(e.last)
        #expect(change.kind == AccountPlanEvent.kindChange)
        #expect(change.observedAt == upgrade)
        #expect(change.subscriptionType == "max" && change.rateLimitTier == Self.max20)
        #expect(change.previousSubscriptionType == "pro" && change.previousRateLimitTier == "default_claude_ai")
        #expect(a.subscriptionType == "max" && a.rateLimitTier == Self.max20)
    }

    /// A field the login omits has not changed: the row keeps it, and the
    /// event carries the pair in effect.
    @Test func anOmittedFieldKeepsItsValue() throws {
        let context = try Self.context()
        let a = Self.account(context)
        a.observePlan(subscriptionType: "max", rateLimitTier: Self.max5, at: Self.t0, in: context)
        a.observePlan(subscriptionType: nil, rateLimitTier: Self.max20, at: Self.t0 + Self.day, in: context)
        let e = try Self.events(context)
        #expect(e.count == 2)
        #expect(e.last?.subscriptionType == "max" && e.last?.rateLimitTier == Self.max20)
        #expect(a.subscriptionType == "max")
    }

    /// A switcher-cache reading reports no plan: nothing is observed.
    @Test func aReadingWithNoPlanRecordsNothing() throws {
        let context = try Self.context()
        let a = Self.account(context, sub: "max", tier: Self.max20)
        a.observePlan(subscriptionType: nil, rateLimitTier: nil, at: Self.t0, in: context)
        #expect(try Self.events(context).isEmpty)
        #expect(a.rateLimitTier == Self.max20)
    }

    /// After a real change, an older login keeps reporting the old pair, so
    /// polls alternate. The change is written once, and a disagreement that
    /// lasts writes about one row a day, not one per poll.
    @Test func twoLoginsDisagreeingDoNotWriteARowPerPoll() throws {
        let context = try Self.context()
        let a = Self.account(context)
        a.observePlan(subscriptionType: "max", rateLimitTier: Self.max5, at: Self.t0, in: context)
        let change = Self.t0 + 30 * Self.day
        // Three days of polls a minute apart, the new and the old login taking turns.
        for i in 0..<(3 * 24 * 60) {
            let new = i % 2 == 0
            a.observePlan(subscriptionType: "max", rateLimitTier: new ? Self.max20 : Self.max5,
                          at: change + Double(i) * Self.minute,
                          reportedBy: new ? "keychain" : "desktop", in: context)
        }
        let e = try Self.events(context)
        #expect(e[1].rateLimitTier == Self.max20 && e[1].observedAt == change)
        #expect(e.count <= 1 + 1 + 3, "\(e.count) events for three days of alternating polls")
    }

    /// A genuine revert inside the window is recorded once the window ends.
    @Test func aRevertIsRecordedOnceTheWindowHasPassed() throws {
        let context = try Self.context()
        let a = Self.account(context)
        a.observePlan(subscriptionType: "max", rateLimitTier: Self.max5, at: Self.t0, in: context)
        a.observePlan(subscriptionType: "max", rateLimitTier: Self.max20, at: Self.t0 + Self.day, in: context)
        a.observePlan(subscriptionType: "max", rateLimitTier: Self.max5, at: Self.t0 + Self.day + 3600, in: context)
        #expect(try Self.events(context).count == 2)
        let later = Self.t0 + 2 * Self.day + 3600
        a.observePlan(subscriptionType: "max", rateLimitTier: Self.max5, at: later, in: context)
        let e = try Self.events(context)
        #expect(e.count == 3)
        #expect(e.last?.rateLimitTier == Self.max5 && e.last?.previousRateLimitTier == Self.max20)
        #expect(e.last?.observedAt == later)
    }

    @Test func accountsKeepSeparateHistories() throws {
        let context = try Self.context()
        let a = Self.account(context)
        let b = Account(id: "acct-b", organizationId: "acct-b", displayName: "B", isActive: false,
                        firstSeenAt: Self.t0, lastSeenAt: Self.t0)
        context.insert(b)
        a.observePlan(subscriptionType: "max", rateLimitTier: Self.max5, at: Self.t0, in: context)
        b.observePlan(subscriptionType: "max", rateLimitTier: Self.max20, at: Self.t0, in: context)
        #expect(try AccountPlanEvent.history(for: "acct-a", in: context).count == 1)
        #expect(try AccountPlanEvent.history(for: "acct-b", in: context).first?.kind == AccountPlanEvent.kindFirst)
    }

    /// End to end: the poller records the plan its login reports, once.
    @Test func aPollRecordsThePlanItsLoginReportsOnce() async throws {
        let container = try ModelContainer(
            for: Schema(PacerStore.allModelTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let blob = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
            "accessToken": "tok",
            "expiresAt": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000,
            "subscriptionType": "max",
            "rateLimitTier": Self.max20,
        ]])
        let keychain = KeychainOAuth(rawReader: { .success(blob) })
        let transport: OAuthClient.Transport = { _ in
            try HTTPOutcome.success(jsonBody: #"{"seven_day":{"utilization":10}}"#,
                                    headers: ["anthropic-organization-id": "orgA"]).materialize()
        }
        let client = OAuthClient(keychain: keychain, transport: transport, desktopEnabled: { false })
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())
        _ = await poller.runOnce()
        _ = await poller.runOnce()

        let summary = try await MainActor.run { () -> [(String, String?, String?, String?)] in
            try AccountPlanEvent.history(for: "orgA", in: ModelContext(container))
                .map { ($0.kind, $0.subscriptionType, $0.rateLimitTier, $0.reportedBy) }
        }
        #expect(summary.count == 1)
        #expect(summary.first?.0 == AccountPlanEvent.kindFirst)
        #expect(summary.first?.1 == "max" && summary.first?.2 == Self.max20)
        #expect(summary.first?.3 == "keychain")
    }

    /// A container that never registered the table (many test suites build
    /// their own) must not crash a poll: the row still updates, no event.
    @Test func aSchemaWithoutTheTableStillUpdatesTheRow() throws {
        let context = ModelContext(try ModelContainer(
            for: Account.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let a = Self.account(context)
        a.observePlan(subscriptionType: "max", rateLimitTier: Self.max20, at: Self.t0, in: context)
        try context.save()
        #expect(a.rateLimitTier == Self.max20)
    }
}

// MARK: - Decided on the poller (#413)

/// The poller used to read an account's plan events inside `MainActor.run` on
/// every poll. It now decides in memory (`AccountPlanState`), loaded once per
/// account on its own actor. Same rule, so the same history.
@Suite("Account plan state")
struct AccountPlanStateTests {

    typealias T = AccountPlanEventTests
    struct Report { let sub: String?; let tier: String?; let at: Date; let by: String? }

    /// The rule's hard cases, as sequences of reports.
    static let scenarios: [[Report]] = {
        let m5 = T.max5, m20 = T.max20, t0 = T.t0, day = T.day, minute = T.minute
        var flap: [Report] = [Report(sub: "max", tier: m5, at: t0, by: "keychain")]
        for i in 0..<(3 * 24 * 60) {
            flap.append(Report(sub: "max", tier: i % 2 == 0 ? m20 : m5,
                               at: t0 + 30 * day + Double(i) * minute, by: i % 2 == 0 ? "keychain" : "desktop"))
        }
        return [
            [Report(sub: "max", tier: m5, at: t0, by: "keychain")],
            (0..<50).map { Report(sub: "max", tier: m5, at: t0 + Double($0) * minute, by: nil) },
            [Report(sub: "pro", tier: "default_claude_ai", at: t0, by: nil),
             Report(sub: "max", tier: m20, at: t0 + 10 * day, by: nil)],
            [Report(sub: "max", tier: m5, at: t0, by: nil),
             Report(sub: nil, tier: m20, at: t0 + day, by: nil),
             Report(sub: nil, tier: nil, at: t0 + 2 * day, by: nil)],
            [Report(sub: "max", tier: m5, at: t0, by: nil),
             Report(sub: "max", tier: m20, at: t0 + day, by: nil),
             Report(sub: "max", tier: m5, at: t0 + day + 3600, by: nil),
             Report(sub: "max", tier: m5, at: t0 + 2 * day + 3600, by: nil)],
            flap,
        ]
    }()

    private static func rows(_ events: [AccountPlanEvent]) -> [AccountPlanState.Event] {
        events.map(AccountPlanState.Event.init)
    }

    @Test("in memory, the same events as the rule against the store")
    func sameHistoryAsTheStore() throws {
        for (n, reports) in Self.scenarios.enumerated() {
            let context = try T.context()
            let a = T.account(context)
            for r in reports {
                a.observePlan(subscriptionType: r.sub, rateLimitTier: r.tier, at: r.at, reportedBy: r.by, in: context)
            }
            let stored = try Self.rows(T.events(context))

            var state = AccountPlanState(subscriptionType: nil, rateLimitTier: nil, events: [])
            var decided: [AccountPlanState.Event] = []
            for r in reports {
                if let event = state.observe(subscriptionType: r.sub, rateLimitTier: r.tier,
                                             at: r.at, reportedBy: r.by)?.event {
                    decided.append(event)
                }
            }
            #expect(decided == stored, "scenario \(n)")
            #expect(state.subscriptionType == a.subscriptionType && state.rateLimitTier == a.rateLimitTier,
                    "scenario \(n)")
            #expect(state.events == Array(stored.reversed().prefix(AccountPlanState.kept)), "scenario \(n)")
        }
    }

    @Test("a change says whether the plan moved, an omitted field keeps its value")
    func changeReportsThePlanMoving() {
        var state = AccountPlanState(subscriptionType: "max", rateLimitTier: T.max5, events: [])
        let first = state.observe(subscriptionType: "max", rateLimitTier: T.max5, at: T.t0)
        #expect(first?.planChanged == false)
        #expect(first?.event?.kind == AccountPlanEvent.kindFirst)
        let same = state.observe(subscriptionType: nil, rateLimitTier: T.max5, at: T.t0 + T.day)
        #expect(same?.planChanged == false && same?.event == nil)
        let moved = state.observe(subscriptionType: nil, rateLimitTier: T.max20, at: T.t0 + 2 * T.day)
        #expect(moved?.planChanged == true)
        #expect(moved?.subscriptionType == "max" && moved?.rateLimitTier == T.max20)
        #expect(state.observe(subscriptionType: nil, rateLimitTier: nil, at: T.t0 + 3 * T.day) == nil)
    }

    @Test("loads the row's pair and its newest events, newest first")
    func loadsFromTheStore() throws {
        let context = try T.context()
        _ = T.account(context, sub: "max", tier: T.max20)
        for i in 0..<12 {
            context.insert(AccountPlanEvent(accountId: "acct-a", observedAt: T.t0 + Double(i) * T.day,
                                            kind: AccountPlanEvent.kindChange, subscriptionType: "max",
                                            rateLimitTier: i % 2 == 0 ? T.max5 : T.max20))
        }
        context.insert(AccountPlanEvent(accountId: "acct-b", observedAt: T.t0 + 99 * T.day,
                                        kind: AccountPlanEvent.kindFirst, subscriptionType: "pro",
                                        rateLimitTier: nil))
        try context.save()

        let state = AccountPlanState.load(accountId: "acct-a", in: context)
        #expect(state.subscriptionType == "max" && state.rateLimitTier == T.max20)
        #expect(state.recordsEvents)
        #expect(state.events.count == AccountPlanState.kept)
        #expect(state.events.map(\.observedAt) == (4..<12).reversed().map { T.t0 + Double($0) * T.day })

        let unknown = AccountPlanState.load(accountId: "acct-new", in: context)
        #expect(unknown == AccountPlanState(subscriptionType: nil, rateLimitTier: nil, events: []))
    }

    @Test("a store without the event table moves the pair and records nothing")
    func noTableNoEvents() throws {
        let context = ModelContext(try ModelContainer(
            for: Account.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        _ = T.account(context, sub: "pro", tier: nil)
        try context.save()
        var state = AccountPlanState.load(accountId: "acct-a", in: context)
        #expect(!state.recordsEvents)
        let change = state.observe(subscriptionType: "max", rateLimitTier: T.max20, at: T.t0)
        #expect(change?.event == nil && change?.planChanged == true)
    }

    /// End to end: the first poll loads the state on the poller, the second
    /// decides in memory, and the event lands in the save the poll signals.
    @Test("the poller decides the plan itself and signals the save that holds it")
    func thePollerDecides() async throws {
        let container = try ModelContainer(
            for: Schema(PacerStore.allModelTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let blob = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
            "accessToken": "tok",
            "expiresAt": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000,
            "subscriptionType": "max",
            "rateLimitTier": T.max20,
        ]])
        let client = OAuthClient(
            keychain: KeychainOAuth(rawReader: { .success(blob) }),
            transport: { _ in
                try HTTPOutcome.success(jsonBody: #"{"seven_day":{"utilization":10}}"#,
                                        headers: ["anthropic-organization-id": "orgP"]).materialize()
            },
            desktopEnabled: { false })
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())
        let atPost = PlanAtPost(sender: poller) {
            let context = ModelContext(container)
            let events = (try? AccountPlanEvent.history(for: "orgP", in: context)) ?? []
            let tier = (try? context.fetch(FetchDescriptor<Account>(
                predicate: #Predicate { $0.id == "orgP" })))?.first?.rateLimitTier
            return "\(events.count) \(tier ?? "-")"
        }

        #expect(await poller.planStateForTesting("orgP") == nil)
        _ = await poller.runOnce()
        let loaded = try #require(await poller.planStateForTesting("orgP"))
        #expect(loaded.rateLimitTier == T.max20 && loaded.events.map(\.kind) == [AccountPlanEvent.kindFirst])
        _ = await poller.runOnce()
        #expect(await poller.planStateForTesting("orgP") == loaded, "an unchanged poll changes nothing")

        #expect(atPost.seen.contains("1 \(T.max20)"), "the event and the tier were in the store when the poll signalled")
        let stored = try await MainActor.run { try AccountPlanEvent.history(for: "orgP", in: ModelContext(container)).count }
        #expect(stored == 1)
    }
}

/// What a fresh read said at each `AccountWriteSignal` post from `sender`.
private final class PlanAtPost: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var observer: (any NSObjectProtocol)?

    init(sender: AnyObject, read: @escaping @Sendable () -> String) {
        observer = NotificationCenter.default.addObserver(
            forName: AccountWriteSignal.name, object: sender, queue: nil
        ) { [weak self] _ in
            let value = read()
            self?.lock.withLock { self?.values.append(value) }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var seen: [String] { lock.withLock { values } }
}
