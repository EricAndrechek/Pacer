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
