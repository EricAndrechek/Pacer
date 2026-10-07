import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// What model is *this* agent running?
///
/// The session endpoint used to answer with the newest turn's model, which is
/// only right when a session runs one model at a time. Claude Code writes a
/// subagent's turns under the parent's session id, so a fan-out means several
/// models share one id and "newest" is whichever agent wrote last. A Sonnet
/// builder was told "Fable" and gated on its orchestrator's cap.
@Suite("Session models")
struct PacerSessionModelsTests {

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Account.self, AccountSessionInfo.self, ProjectMeta.self,
            AccountActivation.self, AccountDailyAggregate.self, TokenSample.self,
            RateLimitSample.self, UsageLimitSample.self, ExtraUsageSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @MainActor
    private static func turn(_ context: ModelContext, session: String, model: String,
                             secondsAgo: Double, now: Date) {
        context.insert(TokenSample(
            sampledAt: now.addingTimeInterval(-secondsAgo),
            date: TokenSample.formatDate(now.addingTimeInterval(-secondsAgo)),
            model: model,
            inputTokens: 10, outputTokens: 20, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
            sessionId: session, projectPath: "/tmp/p"))
    }

    @MainActor
    @Test func aFanOutReportsEveryModelInFlight() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // An orchestrator and its builders, interleaved under one session id.
        Self.turn(context, session: "s1", model: "claude-sonnet-5", secondsAgo: 30, now: now)
        Self.turn(context, session: "s1", model: "claude-fable-5-1", secondsAgo: 10, now: now)
        Self.turn(context, session: "s1", model: "claude-sonnet-5", secondsAgo: 5, now: now)
        try context.save()

        let found = try #require(try PacerSessionLookupBuilder.lookup(
            container: container, sessionId: "s1", now: now))
        #expect(Set(found.models) == ["claude-sonnet-5", "claude-fable-5-1"])
        // Newest first, so a single-model session's `model` is unchanged.
        #expect(found.model == "claude-sonnet-5")
    }

    @MainActor
    @Test func oneModelSessionsAreStillUnambiguous() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Self.turn(context, session: "s1", model: "claude-opus-5", secondsAgo: 60, now: now)
        Self.turn(context, session: "s1", model: "claude-opus-5", secondsAgo: 5, now: now)
        try context.save()

        let found = try #require(try PacerSessionLookupBuilder.lookup(
            container: container, sessionId: "s1", now: now))
        #expect(found.models == ["claude-opus-5"])
        #expect(found.model == "claude-opus-5")
    }

    /// A model used an hour ago is not a model in flight. Without a horizon,
    /// any long session eventually looks ambiguous forever and never gates on
    /// a per-model cap again.
    @MainActor
    @Test func aModelFromHoursAgoIsNotStillRunning() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Self.turn(context, session: "s1", model: "claude-haiku-4-5-20251001",
                  secondsAgo: 3 * 3600, now: now)
        Self.turn(context, session: "s1", model: "claude-opus-5", secondsAgo: 5, now: now)
        try context.save()

        let found = try #require(try PacerSessionLookupBuilder.lookup(
            container: container, sessionId: "s1", now: now))
        #expect(found.models == ["claude-opus-5"])
    }

    /// `<synthetic>` is Claude Code's sentinel for non-billable internal
    /// traffic. It names no real model and must not make a session look like
    /// it is running two.
    @MainActor
    @Test func syntheticTurnsAreNotAModel() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Self.turn(context, session: "s1", model: "claude-opus-5", secondsAgo: 20, now: now)
        Self.turn(context, session: "s1", model: JSONLLineParser.syntheticModelSentinel,
                  secondsAgo: 2, now: now)
        try context.save()

        let found = try #require(try PacerSessionLookupBuilder.lookup(
            container: container, sessionId: "s1", now: now))
        #expect(found.models == ["claude-opus-5"])
        #expect(found.model == "claude-opus-5")
    }

    // MARK: - Which login the session bills now (#184)

    @MainActor
    private static func login(_ context: ModelContext, _ account: String,
                              from: Date, until: Date?) {
        context.insert(AccountActivation(
            accountId: account, startedAt: from, endedAt: until, rootPath: nil,
            source: AccountActivation.sourceObserved))
    }

    /// The session's last turn was before a `/login` switch and it has written
    /// none since (asleep in `pace.sh wait`). Its turn stays on the old login;
    /// its next one goes to the new login.
    @MainActor
    @Test func aSwitchSinceTheLastTurnMovesTheCurrentAccount() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Self.turn(context, session: "s1", model: "claude-opus-5", secondsAgo: 600, now: now)
        (try context.fetch(FetchDescriptor<TokenSample>())).forEach { $0.accountId = "org-work" }
        Self.login(context, "org-work", from: now.addingTimeInterval(-7200),
                   until: now.addingTimeInterval(-300))
        Self.login(context, "org-home", from: now.addingTimeInterval(-300), until: nil)
        try context.save()

        let found = try #require(try PacerSessionLookupBuilder.lookup(
            container: container, sessionId: "s1", now: now))
        #expect(found.accountId == "org-work")
        #expect(found.currentAccountId == "org-home")
    }

    @MainActor
    @Test func withNoObservedLoginTheCurrentAccountIsTheTurns() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Self.turn(context, session: "s1", model: "claude-opus-5", secondsAgo: 5, now: now)
        (try context.fetch(FetchDescriptor<TokenSample>())).forEach { $0.accountId = "org-work" }
        try context.save()

        let found = try #require(try PacerSessionLookupBuilder.lookup(
            container: container, sessionId: "s1", now: now))
        #expect(found.currentAccountId == "org-work")
    }

    /// A session that spans a switch has a per-account row for each login.
    /// The accounts list counted it on both, so the old login kept its
    /// sessions for an hour after everyone had moved.
    @MainActor
    @Test func aSessionSpanningASwitchCountsOnceOnItsNewestLogin() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for id in ["org-work", "org-home"] {
            context.insert(Account(id: id, organizationId: id, displayName: id,
                                   isActive: id == "org-home",
                                   firstSeenAt: .distantPast, lastSeenAt: now))
        }
        func row(_ account: String, lastSeen secondsAgo: Double) {
            context.insert(AccountSessionInfo(
                accountId: account, sessionId: "s1",
                firstSeenAt: now.addingTimeInterval(-secondsAgo - 60),
                lastSeenAt: now.addingTimeInterval(-secondsAgo), projectPath: "/tmp/p",
                ccVersion: nil, cumulativeCostUSD: 0, cumulativeInputTokens: 0,
                cumulativeOutputTokens: 0, cumulativeCacheReadTokens: 0,
                cumulativeCacheCreation5mTokens: 0, cumulativeCacheCreation1hTokens: 0,
                topModel: "claude-opus-5"))
        }
        row("org-work", lastSeen: 240)
        row("org-home", lastSeen: 30)
        try context.save()

        let list = try PacerAccountsBuilder.list(container: container, now: now)
        let byId = Dictionary(uniqueKeysWithValues: list.accounts.map { ($0.id, $0) })
        #expect(byId["org-home"]?.activeSessions == 1)
        #expect(byId["org-work"]?.activeSessions == 0)
        #expect(byId["org-work"]?.recentSessions == 0)
    }

    /// #190: right after a switch, every running session's newest row is still
    /// on the old login, because none has written a turn since. The counts
    /// credited all of them to the old login, and the new one, whose usage was
    /// the one rising, showed none.
    @MainActor
    @Test func runningSessionsCountOnTheLoginTheyAreOnNow() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for id in ["org-work", "org-home"] {
            context.insert(Account(id: id, organizationId: id, displayName: id,
                                   isActive: id == "org-home",
                                   firstSeenAt: .distantPast, lastSeenAt: now))
        }
        Self.login(context, "org-work", from: now.addingTimeInterval(-7200),
                   until: now.addingTimeInterval(-30))
        Self.login(context, "org-home", from: now.addingTimeInterval(-30), until: nil)
        func row(_ session: String, lastSeen secondsAgo: Double) {
            context.insert(AccountSessionInfo(
                accountId: "org-work", sessionId: session,
                firstSeenAt: now.addingTimeInterval(-secondsAgo - 60),
                lastSeenAt: now.addingTimeInterval(-secondsAgo), projectPath: "/tmp/p",
                ccVersion: nil, cumulativeCostUSD: 0, cumulativeInputTokens: 0,
                cumulativeOutputTokens: 0, cumulativeCacheReadTokens: 0,
                cumulativeCacheCreation5mTokens: 0, cumulativeCacheCreation1hTokens: 0,
                topModel: "claude-opus-5"))
        }
        row("running", lastSeen: 60)        // active, last turn before the switch
        row("idle", lastSeen: 1800)         // recent but idle: counted where it drew
        try context.save()

        let list = try PacerAccountsBuilder.list(container: container, now: now)
        let byId = Dictionary(uniqueKeysWithValues: list.accounts.map { ($0.id, $0) })
        #expect(byId["org-home"]?.activeSessions == 1)
        #expect(byId["org-work"]?.activeSessions == 0)
        #expect(byId["org-work"]?.recentSessions == 1)

        let sessions = try PacerSessionLookupBuilder.list(
            container: container, withinSeconds: 3600, account: nil, now: now)
        let running = try #require(sessions.sessions.first { $0.sessionId == "running" })
        #expect(running.accountId == "org-work")
        #expect(running.currentAccountId == "org-home")
        let idle = try #require(sessions.sessions.first { $0.sessionId == "idle" })
        #expect(idle.currentAccountId == "org-work")
        // Filtering by the new login finds the running session.
        let onHome = try PacerSessionLookupBuilder.list(
            container: container, withinSeconds: 3600, account: "org-home", now: now)
        #expect(onHome.sessions.map(\.sessionId) == ["running"])
    }

    @MainActor
    @Test func aSessionSpanningASwitchIsListedOnce() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (account, ago) in [("org-work", 400.0), ("org-home", 20.0)] {
            context.insert(AccountSessionInfo(
                accountId: account, sessionId: "s1",
                firstSeenAt: now.addingTimeInterval(-ago - 60),
                lastSeenAt: now.addingTimeInterval(-ago), projectPath: "/tmp/p",
                ccVersion: nil, cumulativeCostUSD: 0, cumulativeInputTokens: 0,
                cumulativeOutputTokens: 0, cumulativeCacheReadTokens: 0,
                cumulativeCacheCreation5mTokens: 0, cumulativeCacheCreation1hTokens: 0,
                topModel: "claude-opus-5"))
        }
        try context.save()
        let sessions = try PacerSessionLookupBuilder.list(
            container: container, withinSeconds: 3600, account: nil, now: now)
        #expect(sessions.sessions.count == 1)
        #expect(sessions.sessions.first?.accountId == "org-home")
    }

    @MainActor
    @Test func theLookupSaysWhenTheCurrentLoginStarted() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Self.turn(context, session: "s1", model: "claude-opus-5", secondsAgo: 5, now: now)
        Self.login(context, "org-home", from: now.addingTimeInterval(-300), until: nil)
        try context.save()
        let found = try #require(try PacerSessionLookupBuilder.lookup(
            container: container, sessionId: "s1", now: now))
        #expect(found.currentAccountSince == now.addingTimeInterval(-300))
    }
}
