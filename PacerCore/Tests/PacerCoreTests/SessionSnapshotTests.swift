import Foundation
import SwiftData
import Testing
@testable import PacerCore

// #211: `/v1/session` is answered from the API snapshot for every live
// session, so a store stall no longer costs `pace.sh` its timeout and then the
// wrong account. And a session that bills an account of its own (Claude
// Desktop's, a pinned profile's) no longer follows the CLI's switches.
// Fictional org ids throughout.

private let cliOld = "11111111-1111-4111-8111-111111111111"
private let cliNew = "22222222-2222-4222-8222-222222222222"
private let desktopOrg = "33333333-3333-4333-8333-333333333333"
private let pinnedOrg = "44444444-4444-4444-8444-444444444444"

@Suite("Session binding and the session snapshot")
struct SessionSnapshotTests {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Account.self, AccountSessionInfo.self, ProjectMeta.self,
            AccountActivation.self, AccountDailyAggregate.self, DailyAggregate.self,
            SessionInfo.self, TokenSample.self, ClaudeCodeMeta.self,
            RateLimitSample.self, UsageLimitSample.self, ExtraUsageSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// A Desktop records folder naming `session` as `desktopOrg`'s.
    static func desktopDirectory(session: String) throws -> (DesktopSessionDirectory, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-desktop-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("55555555-5555-4555-8555-555555555555")
            .appendingPathComponent(desktopOrg)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["cliSessionId": session])
            .write(to: folder.appendingPathComponent("local_1.json"))
        return (DesktopSessionDirectory(root: root), root)
    }

    /// The CLI was on `cliOld` until ten minutes ago and is on `cliNew` now. A
    /// pinned profile has been on `pinnedOrg` all along. Three sessions last
    /// wrote twenty minutes ago, before the switch:
    /// - `cli` on the default login;
    /// - `desk` in Claude Desktop, on Desktop's account;
    /// - `pinned` in the pinned profile.
    @MainActor
    static func seed(_ context: ModelContext) {
        context.insert(AccountActivation(
            accountId: cliOld, startedAt: now.addingTimeInterval(-86_400),
            endedAt: now.addingTimeInterval(-600), source: AccountActivation.sourceObserved))
        context.insert(AccountActivation(
            accountId: cliNew, startedAt: now.addingTimeInterval(-600),
            source: AccountActivation.sourceObserved))
        context.insert(AccountActivation(
            accountId: pinnedOrg, startedAt: now.addingTimeInterval(-86_400),
            rootPath: "/tmp/profiles/2", source: AccountActivation.sourceExternal))
        let at = now.addingTimeInterval(-1_200)
        for (session, account) in [("cli", cliOld), ("desk", desktopOrg), ("pinned", pinnedOrg)] {
            let sample = TokenSample(
                sampledAt: at, date: TokenSample.formatDate(at), model: "claude-opus-5",
                inputTokens: 10, outputTokens: 20, cacheReadTokens: 0,
                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                sessionId: session, projectPath: "/tmp/acme")
            sample.accountId = account
            context.insert(sample)
            context.insert(AccountSessionInfo(
                accountId: account, sessionId: session, firstSeenAt: at, lastSeenAt: at,
                projectPath: "/tmp/acme", ccVersion: nil, cumulativeCostUSD: 0,
                cumulativeInputTokens: 10, cumulativeOutputTokens: 20,
                cumulativeCacheReadTokens: 0, cumulativeCacheCreation5mTokens: 0,
                cumulativeCacheCreation1hTokens: 0, topModel: "claude-opus-5"))
        }
        try? context.save()
    }

    @MainActor
    @Test("only a session on the default login follows the CLI's switch")
    func bindingFollowsOnlyTheDefaultLogin() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        Self.seed(context)
        let (desktop, root) = try Self.desktopDirectory(session: "desk")
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = PacerSessionBinding.load(context: context, desktop: desktop)

        func lookup(_ id: String) -> PacerSessionLookup? {
            PacerSessionLookupBuilder.lookup(context: context, sessionId: id,
                                             binding: binding, now: Self.now)
        }
        // The CLI session moves with the login (#184), and says since when.
        #expect(lookup("cli")?.currentAccountId == cliNew)
        #expect(lookup("cli")?.currentAccountSince == Self.now.addingTimeInterval(-600))
        // Desktop's and the pinned profile's stay on their own accounts.
        #expect(lookup("desk")?.currentAccountId == desktopOrg)
        #expect(lookup("desk")?.currentAccountSince == nil)
        #expect(lookup("pinned")?.currentAccountId == pinnedOrg)
        #expect(lookup("pinned")?.currentAccountSince == nil)
    }

    @MainActor
    @Test("the snapshot answers every live session exactly as the store does")
    func snapshotMatchesTheStorePath() throws {
        let container = try Self.makeContainer()
        Self.seed(ModelContext(container))
        let (desktop, root) = try Self.desktopDirectory(session: "desk")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = try PacerAPISnapshot.build(
            container: container, activeAccountId: cliNew, desktop: desktop, now: Self.now)
        #expect(Set(snapshot.sessions.keys) == ["cli", "desk", "pinned"])

        let later = Self.now.addingTimeInterval(30)
        for id in ["cli", "desk", "pinned"] {
            let context = ModelContext(container)
            let stored = try #require(PacerSessionLookupBuilder.lookup(
                context: context, sessionId: id,
                binding: .load(context: context, desktop: desktop), now: later))
            let cached = try #require(snapshot.session(id: id, at: later))
            // Byte-identical, `generatedAt` included: it is rebased to the request.
            #expect(try cached.encodedJSON() == stored.encodedJSON())
        }
        // Whitespace around the id is forgiven, as on the store path.
        #expect(snapshot.session(id: " cli ", at: later)?.sessionId == "cli")
    }

    @MainActor
    @Test("a session older than the window is left to the store")
    func oldSessionsFallBack() throws {
        let container = try Self.makeContainer()
        Self.seed(ModelContext(container))
        let past = Self.now.addingTimeInterval(PacerSessionLookupBuilder.snapshotWindow + 1_300)
        let snapshot = try PacerAPISnapshot.build(
            container: container, activeAccountId: cliNew, desktop: nil, now: past)
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.session(id: "cli", at: past) == nil)
        // The store still has it.
        #expect(try PacerSessionLookupBuilder.lookup(
            container: container, sessionId: "cli", now: past)?.sessionId == "cli")
    }

    @MainActor
    @Test("/v1/sessions lists a running Desktop session on Desktop's account")
    func listBindsDesktopSessions() throws {
        let container = try Self.makeContainer()
        let context = ModelContext(container)
        Self.seed(context)
        // Make them all active (≤5 min) so the list reports a current account.
        // A CLI turn written after the switch was stamped with the new login.
        for row in try context.fetch(FetchDescriptor<AccountSessionInfo>()) {
            row.lastSeenAt = Self.now.addingTimeInterval(-60)
            if row.sessionId == "cli" { row.accountId = cliNew }
        }
        for sample in try context.fetch(FetchDescriptor<TokenSample>()) {
            sample.sampledAt = Self.now.addingTimeInterval(-60)
            if sample.sessionId == "cli" { sample.accountId = cliNew }
        }
        try context.save()
        let (desktop, root) = try Self.desktopDirectory(session: "desk")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = desktop.accounts

        let list = try PacerSessionLookupBuilder.list(
            container: container, withinSeconds: 3_600, account: nil, now: Self.now,
            desktop: desktop)
        let current = Dictionary(uniqueKeysWithValues: list.sessions.map {
            ($0.sessionId, $0.currentAccountId) })
        #expect(current["desk"] == .some(desktopOrg))
        #expect(current["pinned"] == .some(pinnedOrg))
        #expect(current["cli"] == .some(cliNew))
    }
}
