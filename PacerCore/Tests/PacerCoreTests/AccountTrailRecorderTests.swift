import Foundation
import SwiftData
import Testing
@testable import PacerCore

private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: AccountActivation.self, Account.self, TokenSample.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

private func makeHome() throws -> URL {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

/// Write `~/.claude.json` with the given account, at a controlled mtime so the
/// recorder's staleness gate is exercised deterministically.
private func writeConfig(
    _ home: URL, org: String?, email: String? = nil, orgName: String? = nil,
    modified: Date, raw: String? = nil
) throws {
    let body: String
    if let raw {
        body = raw
    } else {
        var fields: [String] = []
        if let org { fields.append("\"organizationUuid\":\"\(org)\"") }
        if let email { fields.append("\"emailAddress\":\"\(email)\"") }
        if let orgName { fields.append("\"organizationName\":\"\(orgName)\"") }
        body = "{\"oauthAccount\":{\(fields.joined(separator: ","))}}"
    }
    let url = home.appendingPathComponent(".claude.json")
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
}

@Suite("Account trail recorder")
@ScanActor
struct AccountTrailRecorderTests {

    private func makeRecorder(_ home: URL, _ context: ModelContext) -> AccountTrailRecorder {
        AccountTrailRecorder(context: context, homeDirectory: home)
    }

    @Test("the first observation opens an activation")
    func firstObservationOpensASpan() throws {
        let home = try makeHome()
        let context = ModelContext(try makeContainer())
        try writeConfig(home, org: "org-a", modified: Date())

        let key = makeRecorder(home, context).poll()
        #expect(key == "org-a")

        let spans = try context.fetch(FetchDescriptor<AccountActivation>())
        #expect(spans.count == 1)
        #expect(spans[0].accountId == "org-a")
        #expect(spans[0].endedAt == nil)
        #expect(spans[0].source == AccountActivation.sourceObserved)
    }

    @Test("an unchanged config is not re-read and writes nothing")
    func unchangedConfigIsANoOp() throws {
        let home = try makeHome()
        let context = ModelContext(try makeContainer())
        let stamp = Date(timeIntervalSince1970: 1_780_000_000)
        try writeConfig(home, org: "org-a", modified: stamp)

        let recorder = makeRecorder(home, context)
        _ = recorder.poll()
        _ = recorder.poll()
        _ = recorder.poll()

        #expect(try context.fetch(FetchDescriptor<AccountActivation>()).count == 1)
    }

    @Test("a real switch closes the old span and opens a new one")
    func switchClosesAndOpens() throws {
        let home = try makeHome()
        let context = ModelContext(try makeContainer())
        try writeConfig(home, org: "org-a", modified: Date(timeIntervalSince1970: 1_000))
        let recorder = makeRecorder(home, context)
        _ = recorder.poll(now: Date(timeIntervalSince1970: 1_000))

        try writeConfig(home, org: "org-b", modified: Date(timeIntervalSince1970: 2_000))
        let key = recorder.poll(now: Date(timeIntervalSince1970: 2_000))
        #expect(key == "org-b")

        let spans = try context.fetch(FetchDescriptor<AccountActivation>(
            sortBy: [SortDescriptor(\.startedAt)]))
        #expect(spans.count == 2)
        #expect(spans[0].accountId == "org-a")
        #expect(spans[0].endedAt == Date(timeIntervalSince1970: 2_000))
        #expect(spans[1].accountId == "org-b")
        #expect(spans[1].endedAt == nil)
    }

    /// The asymmetry that matters: a missed switch self-corrects next cycle,
    /// a FALSE switch splits one account's session across two accounts and is
    /// undetectable afterwards. So only a successful read of a *different*
    /// account may close a span.
    @Test("an unreadable config leaves the trail exactly as it was")
    func unreadableConfigNeverClosesASpan() throws {
        let home = try makeHome()
        let context = ModelContext(try makeContainer())
        try writeConfig(home, org: "org-a", modified: Date(timeIntervalSince1970: 1_000))
        let recorder = makeRecorder(home, context)
        _ = recorder.poll(now: Date(timeIntervalSince1970: 1_000))

        // Caught mid-rewrite: valid file, no oauthAccount.
        try writeConfig(home, org: nil, modified: Date(timeIntervalSince1970: 2_000),
                        raw: "{\"numStartups\":4}")
        _ = recorder.poll(now: Date(timeIntervalSince1970: 2_000))

        // Not JSON at all.
        try writeConfig(home, org: nil, modified: Date(timeIntervalSince1970: 3_000),
                        raw: "{ half-written")
        _ = recorder.poll(now: Date(timeIntervalSince1970: 3_000))

        let spans = try context.fetch(FetchDescriptor<AccountActivation>())
        #expect(spans.count == 1)
        #expect(spans[0].accountId == "org-a")
        #expect(spans[0].endedAt == nil)   // still open — no false switch
    }

    @Test("re-observing the same account is idempotent")
    func sameAccountDoesNotChurnSpans() throws {
        let home = try makeHome()
        let context = ModelContext(try makeContainer())
        let recorder = makeRecorder(home, context)
        for (i, stamp) in [1_000.0, 2_000.0, 3_000.0].enumerated() {
            try writeConfig(home, org: "org-a", email: "a\(i)@example.com",
                            modified: Date(timeIntervalSince1970: stamp))
            _ = recorder.poll(now: Date(timeIntervalSince1970: stamp))
        }
        let spans = try context.fetch(FetchDescriptor<AccountActivation>())
        #expect(spans.count == 1)
        #expect(spans[0].endedAt == nil)
    }

    @Test("the live login's real identity lands on its Account row")
    func labelsAreAppliedToTheAccount() throws {
        let home = try makeHome()
        let context = ModelContext(try makeContainer())
        context.insert(Account(
            id: "org-a", organizationId: "org-a",
            displayName: "Claude account (max)", isActive: true,
            firstSeenAt: .distantPast, lastSeenAt: .distantPast))
        try context.save()

        try writeConfig(home, org: "org-a", email: "me@example.com",
                        orgName: "My Org", modified: Date())
        _ = makeRecorder(home, context).poll()

        let account = try context.fetch(FetchDescriptor<Account>()).first
        #expect(account?.emailAddress == "me@example.com")
        #expect(account?.organizationName == "My Org")
        #expect(account?.label == "me@example.com")
        // The user-facing rename field is untouched.
        #expect(account?.displayName == "Claude account (max)")
    }

    @Test("a pinned session profile is bound to its own account, not the default login")
    func pinnedProfileGetsItsOwnSpan() throws {
        let home = try makeHome()
        let context = ModelContext(try makeContainer())
        try writeConfig(home, org: "org-default", modified: Date(timeIntervalSince1970: 1_000))
        let recorder = makeRecorder(home, context)
        _ = recorder.poll(now: Date(timeIntervalSince1970: 1_000))

        // A profile directory with its own config naming a different account.
        let profile = home.appendingPathComponent("profiles/2-personal")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try "{\"oauthAccount\":{\"organizationUuid\":\"org-session\"}}"
            .write(to: profile.appendingPathComponent(".claude.json"),
                   atomically: true, encoding: .utf8)

        recorder.pollPinnedRoots([profile], now: Date(timeIntervalSince1970: 1_500))

        let spans = try context.fetch(FetchDescriptor<AccountActivation>(
            sortBy: [SortDescriptor(\.startedAt)]))
        #expect(spans.count == 2)
        // The default login's span is untouched — the profile did not
        // displace it, because they are concurrent, not sequential.
        #expect(spans[0].accountId == "org-default")
        #expect(spans[0].endedAt == nil)
        #expect(spans[1].accountId == "org-session")
        #expect(spans[1].rootPath == profile.standardizedFileURL.path)
        #expect(spans[1].source == AccountActivation.sourceExternal)

        // And the trail resolves the same instant two different ways.
        let trail = recorder.trail()
        let at = Date(timeIntervalSince1970: 2_000)
        #expect(trail.accountId(at: at) == "org-default")
        #expect(trail.accountId(at: at, rootPath: profile.standardizedFileURL.path) == "org-session")
        #expect(trail.hasConcurrentAccounts)
    }
}
