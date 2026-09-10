import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Who else is spending an account's budget.
///
/// A rate-limit window is account-wide, so every session signed into an account
/// draws on the same percentage. A burn rate already includes all of them; what
/// an agent deciding whether to fan out needs is how many ways it is split.
@Suite("Live sessions")
struct PacerSessionListTests {

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Account.self, AccountSessionInfo.self, ProjectMeta.self,
            AccountActivation.self, AccountDailyAggregate.self, TokenSample.self,
            RateLimitSample.self, UsageLimitSample.self, ExtraUsageSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @MainActor
    private static func session(_ context: ModelContext, id: String, account: String,
                                path: String, minutesAgo: Double, now: Date,
                                model: String = "claude-opus-5") {
        context.insert(AccountSessionInfo(
            accountId: account, sessionId: id,
            firstSeenAt: now.addingTimeInterval(-7200),
            lastSeenAt: now.addingTimeInterval(-minutesAgo * 60),
            projectPath: path, ccVersion: nil, cumulativeCostUSD: 1,
            cumulativeInputTokens: 10, cumulativeOutputTokens: 20,
            cumulativeCacheReadTokens: 0, cumulativeCacheCreation5mTokens: 0,
            cumulativeCacheCreation1hTokens: 0, topModel: model))
    }

    @MainActor
    @Test func activityUsesTheSameThresholdsAsTheRestOfTheApp() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Self.session(context, id: "s-now", account: "org-work", path: "/tmp/a", minutesAgo: 2, now: now)
        Self.session(context, id: "s-recent", account: "org-work", path: "/tmp/b", minutesAgo: 30, now: now)
        Self.session(context, id: "s-old", account: "org-work", path: "/tmp/c", minutesAgo: 600, now: now)
        try context.save()

        let list = try PacerSessionLookupBuilder.list(
            container: container, withinSeconds: LiveSessionActivity.recentThreshold,
            account: nil, now: now)
        // The hour-old one is outside the window entirely.
        #expect(list.sessions.map(\.sessionId) == ["s-now", "s-recent"])
        #expect(list.sessions.first?.activity == "active")
        #expect(list.sessions.last?.activity == "recent")
    }

    @MainActor
    @Test func sessionsCarryTheirAccountProjectAndModel() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Self.session(context, id: "s1", account: "org-home", path: "/Users/x/Code/Acme",
                     minutesAgo: 1, now: now, model: "claude-fable-5-1")
        try context.save()

        let row = try #require(try PacerSessionLookupBuilder.list(
            container: container, withinSeconds: 3600, account: nil, now: now).sessions.first)
        #expect(row.accountId == "org-home")
        #expect(row.project == "Acme")
        #expect(row.projectPath == "/Users/x/Code/Acme")
        #expect(row.model == "claude-fable-5-1")
    }

    /// `colorSeed` is a git remote *or* a canonical path — it exists to be a
    /// stable colour input. Publishing the fallback under a field called
    /// `repository` would hand a caller a local directory and call it a remote.
    @MainActor
    @Test func onlyARealRemoteIsReportedAsTheRepository() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Self.session(context, id: "s1", account: "a", path: "/tmp/with-remote", minutesAgo: 1, now: now)
        Self.session(context, id: "s2", account: "a", path: "/tmp/no-remote", minutesAgo: 1, now: now)
        let withRemote = ProjectMeta(projectPath: "/tmp/with-remote")
        withRemote.colorSeed = "git@github.com:Acme/thing.git"
        let noRemote = ProjectMeta(projectPath: "/tmp/no-remote")
        noRemote.colorSeed = "/tmp/some/other/canonical/path"
        context.insert(withRemote)
        context.insert(noRemote)
        try context.save()

        let rows = try PacerSessionLookupBuilder.list(
            container: container, withinSeconds: 3600, account: nil, now: now).sessions
        #expect(rows.first { $0.projectPath == "/tmp/with-remote" }?.repository
            == "git@github.com:Acme/thing.git")
        #expect(rows.first { $0.projectPath == "/tmp/no-remote" }?.repository == nil)
    }

    @MainActor
    @Test func sessionsCanBeScopedToOneAccount() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        Self.session(context, id: "w1", account: "org-work", path: "/tmp/a", minutesAgo: 1, now: now)
        Self.session(context, id: "h1", account: "org-home", path: "/tmp/b", minutesAgo: 1, now: now)
        try context.save()

        let scoped = try PacerSessionLookupBuilder.list(
            container: container, withinSeconds: 3600, account: "org-home", now: now)
        #expect(scoped.sessions.map(\.sessionId) == ["h1"])
    }

    /// The count that matters for a fan-out decision: how many ways this
    /// account's window is already being split.
    @MainActor
    @Test func accountsReportHowManySessionsAreDrawingOnThem() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(Account(id: "org-work", organizationId: "org-work", displayName: "W",
                               isActive: true, firstSeenAt: .distantPast, lastSeenAt: now))
        context.insert(Account(id: "org-home", organizationId: "org-home", displayName: "H",
                               isActive: false, firstSeenAt: .distantPast, lastSeenAt: now))
        Self.session(context, id: "a", account: "org-work", path: "/tmp/1", minutesAgo: 1, now: now)
        Self.session(context, id: "b", account: "org-work", path: "/tmp/2", minutesAgo: 3, now: now)
        Self.session(context, id: "c", account: "org-work", path: "/tmp/3", minutesAgo: 40, now: now)
        try context.save()

        let list = try PacerAccountsBuilder.list(container: container, now: now)
        let work = try #require(list.accounts.first { $0.id == "org-work" })
        #expect(work.activeSessions == 2)     // within 5 minutes
        #expect(work.recentSessions == 3)     // within the hour
        let home = try #require(list.accounts.first { $0.id == "org-home" })
        #expect(home.activeSessions == 0)
        #expect(home.recentSessions == 0)
    }
}
