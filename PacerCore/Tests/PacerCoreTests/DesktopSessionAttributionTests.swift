import Foundation
import SwiftData
import Testing
@testable import PacerCore

// #244: Claude Desktop runs its own Claude Code, writes the transcripts into
// the same `~/.claude/projects` as the CLI, and bills its own login. Its turns
// were attributed by the CLI's trail, so they landed on whichever account the
// CLI was on. Desktop records which org each of its sessions ran under; that
// record now decides. Fictional org ids throughout.

private let cliOrg = "11111111-1111-4111-8111-111111111111"
private let desktopOrg = "22222222-2222-4222-8222-222222222222"
private let otherDesktopOrg = "33333333-3333-4333-8333-333333333333"
private let desktopUser = "44444444-4444-4444-8444-444444444444"

private func tempDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pacer-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// One Desktop session record, laid out the way Desktop keeps them.
@discardableResult
private func writeRecord(
    in sessionsRoot: URL, org: String, cliSessionId: String?,
    user: String = desktopUser, name: String = "local_\(UUID().uuidString).json"
) throws -> URL {
    let folder = sessionsRoot.appendingPathComponent(user).appendingPathComponent(org)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var record: [String: Any] = ["sessionId": "local_x", "title": "A session", "cwd": "/tmp/acme"]
    if let cliSessionId { record["cliSessionId"] = cliSessionId }
    let url = folder.appendingPathComponent(name)
    try JSONSerialization.data(withJSONObject: record).write(to: url)
    return url
}

private func assistantLine(
    _ timestamp: String, session: String, message: String, entrypoint: String?
) -> String {
    var fields: [String: Any] = [
        "type": "assistant", "timestamp": timestamp, "sessionId": session,
        "requestId": "req-\(message)", "cwd": "/tmp/acme",
        "message": [
            "id": message, "model": "claude-opus-4-7", "stop_reason": "end_turn",
            "usage": ["input_tokens": 100, "output_tokens": 50],
        ] as [String: Any],
    ]
    if let entrypoint { fields["entrypoint"] = entrypoint }
    return String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
}

private func makeSample(session: String?, account: String?, at seconds: TimeInterval = 1_790_000_000) -> TokenSample {
    let when = Date(timeIntervalSince1970: seconds)
    let s = TokenSample(
        sampledAt: when, date: TokenSample.formatDate(when), model: "claude-opus-4-7",
        inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
        cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, sessionId: session)
    s.accountId = account
    return s
}

@Suite("A line says which client wrote it")
struct EntrypointParsingTests {

    @Test("entrypoint is parsed, and Desktop's is recognised")
    func parsesEntrypoint() {
        let desktop = JSONLLineParser.parse(
            line: assistantLine("2026-10-01T10:00:00Z", session: "s", message: "m1",
                                entrypoint: "claude-desktop"))
        let cli = JSONLLineParser.parse(
            line: assistantLine("2026-10-01T10:00:00Z", session: "s", message: "m2", entrypoint: "cli"))
        let old = JSONLLineParser.parse(
            line: assistantLine("2026-10-01T10:00:00Z", session: "s", message: "m3", entrypoint: nil))

        #expect(desktop?.entrypoint == "claude-desktop")
        #expect(desktop?.isFromDesktop == true)
        #expect(cli?.entrypoint == "cli")
        #expect(cli?.isFromDesktop == false)
        #expect(old?.entrypoint == nil)
        #expect(old?.isFromDesktop == false)
    }
}

@Suite("Desktop's session records")
@ScanActor
struct DesktopSessionDirectoryTests {

    @Test("each record maps its transcript session to the org folder it sits in")
    func mapsSessionsToOrgs() throws {
        let root = try tempDirectory("desktop-sessions")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRecord(in: root, org: desktopOrg, cliSessionId: "session-a")
        try writeRecord(in: root, org: otherDesktopOrg, cliSessionId: "session-b")
        // Not an org id: some other kind of folder, which says nothing.
        try writeRecord(in: root, org: "skills-plugin", cliSessionId: "session-c")

        let directory = DesktopSessionDirectory(root: root)

        #expect(directory.recordedAccount(forSession: "session-a") == desktopOrg)
        #expect(directory.recordedAccount(forSession: "session-b") == otherDesktopOrg)
        #expect(directory.recordedAccount(forSession: "session-c") == nil)
        #expect(directory.drainDiscovered() == ["session-a": desktopOrg, "session-b": otherDesktopOrg])
        #expect(directory.drainDiscovered().isEmpty)
    }

    @Test("a session with no record yet is looked for again, but not on every turn")
    func missRereadsThrottled() throws {
        let root = try tempDirectory("desktop-sessions")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = DesktopSessionDirectory(root: root)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)

        #expect(directory.accountForDesktopSession("late", now: t0) == nil)
        try writeRecord(in: root, org: desktopOrg, cliSessionId: "late")
        // Within the interval the folder is not read again for this session.
        #expect(directory.accountForDesktopSession("late", now: t0.addingTimeInterval(1)) == nil)
        let later = t0.addingTimeInterval(DesktopSessionDirectory.missRefreshInterval)
        #expect(directory.accountForDesktopSession("late", now: later) == desktopOrg)
        #expect(directory.drainDiscovered() == ["late": desktopOrg])
    }

    @Test("a record written before its session id is read again once it has one")
    func recordWithoutSessionIdIsRetried() throws {
        let root = try tempDirectory("desktop-sessions")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeRecord(in: root, org: desktopOrg, cliSessionId: nil, name: "local_1.json")
        let directory = DesktopSessionDirectory(root: root)
        #expect(directory.drainDiscovered().isEmpty)

        try writeRecord(in: root, org: desktopOrg, cliSessionId: "filled", name: url.lastPathComponent)
        directory.refresh()
        #expect(directory.recordedAccount(forSession: "filled") == desktopOrg)
    }

    @Test("no folder, or no root at all, is simply no records")
    func absentFolder() throws {
        let missing = DesktopSessionDirectory(
            root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(missing.recordedAccount(forSession: "x") == nil)
        let none = DesktopSessionDirectory(root: nil)
        #expect(none.accountForDesktopSession("x") == nil)
        #expect(none.drainDiscovered().isEmpty)
    }
}

@Suite("Re-stamping around Desktop's sessions")
@ScanActor
struct DesktopRestampTests {

    @Test("a recorded session's stored turns move to Desktop's org; others stay")
    func historyMoves() throws {
        let context = ModelContext(try PacerStore.makeInMemoryContainer())
        let stampedCLI = makeSample(session: "desk", account: cliOrg)   // the #244 bug
        let unattributed = makeSample(session: "desk", account: nil)    // record came late
        let alreadyRight = makeSample(session: "desk", account: desktopOrg)
        let cliTurn = makeSample(session: "cli-session", account: cliOrg)
        for s in [stampedCLI, unattributed, alreadyRight, cliTurn] { context.insert(s) }
        try context.save()

        let moved = try AccountBackfill.restampDesktopSessions(["desk": desktopOrg], context: context)

        #expect(moved.count == 2)
        #expect(stampedCLI.accountId == desktopOrg)
        #expect(unattributed.accountId == desktopOrg)
        #expect(alreadyRight.accountId == desktopOrg)
        #expect(cliTurn.accountId == cliOrg)
        // Run again: nothing disagrees any more, so nothing comes back.
        #expect(try AccountBackfill.restampDesktopSessions(["desk": desktopOrg], context: context).isEmpty)
    }

    @Test("a CLI trail correction never moves a Desktop session's turns")
    func trailCorrectionSkipsDesktop() throws {
        let context = ModelContext(try PacerStore.makeInMemoryContainer())
        // The trail briefly believed a stale config write naming Desktop's
        // org, which Desktop itself wrote while running. The credential
        // refutes it: CLI turns in that range move, Desktop's own do not.
        let cliTurn = makeSample(session: "cli-session", account: desktopOrg, at: 2_500)
        let desktopTurn = makeSample(session: "desk", account: desktopOrg, at: 2_600)
        for s in [cliTurn, desktopTurn] { context.insert(s) }
        try context.save()
        let trail = AccountTrail(spans: [
            .init(accountId: cliOrg, startedAt: Date(timeIntervalSince1970: 2_000),
                  endedAt: nil, rootPath: nil),
        ])

        let moved = try AccountBackfill.restamp(
            [.init(from: Date(timeIntervalSince1970: 2_000), to: nil,
                   wrongAccount: desktopOrg, rightAccount: cliOrg)],
            trail: trail, desktopSessions: ["desk": desktopOrg], context: context)

        #expect(moved.count == 1)
        #expect(cliTurn.accountId == cliOrg)
        #expect(desktopTurn.accountId == desktopOrg)
    }
}

@Suite("A scan attributes Desktop's turns to Desktop's account")
@ScanActor
struct DesktopScanAttributionTests {

    /// A config root whose login is `cliOrg`, holding one CLI transcript and
    /// two Desktop ones: one Desktop recorded, one it did not.
    private struct Rig {
        let configRoot: URL
        let sessionsRoot: URL
        let container: ModelContainer
        let coordinator: ScanCoordinator
    }

    private func rig(preexisting: [TokenSample] = []) throws -> Rig {
        let configRoot = try tempDirectory("desktop-config")
        let sessionsRoot = try tempDirectory("desktop-sessions")
        try #"{"oauthAccount":{"organizationUuid":"\#(cliOrg)"}}"#
            .write(to: configRoot.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let projects = configRoot.appendingPathComponent("projects/-tmp-acme")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        func transcript(_ session: String, _ lines: [String]) throws {
            try (lines.joined(separator: "\n") + "\n").write(
                to: projects.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8)
        }
        try transcript("cli-session", [
            assistantLine("2026-10-01T10:00:00Z", session: "cli-session", message: "c1", entrypoint: "cli"),
        ])
        try transcript("desk", [
            assistantLine("2026-10-01T10:01:00Z", session: "desk", message: "d1", entrypoint: "claude-desktop"),
            // An older Desktop line without the field: the record still decides.
            assistantLine("2026-10-01T10:02:00Z", session: "desk", message: "d2", entrypoint: nil),
        ])
        try transcript("desk-unrecorded", [
            assistantLine("2026-10-01T10:03:00Z", session: "desk-unrecorded", message: "u1",
                          entrypoint: "claude-desktop"),
        ])
        try writeRecord(in: sessionsRoot, org: desktopOrg, cliSessionId: "desk")

        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        // The CLI has been on `cliOrg` throughout: a trail opened at launch
        // would start after these turns and attribute none of them.
        context.insert(AccountActivation(
            accountId: cliOrg, startedAt: .distantPast,
            source: AccountActivation.sourceObserved))
        for s in preexisting { context.insert(s) }
        try context.save()
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false,
                                 desktopSessionsRoot: sessionsRoot),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": configRoot.path]),
            homeDirectory: configRoot)
        return Rig(configRoot: configRoot, sessionsRoot: sessionsRoot,
                   container: container, coordinator: coordinator)
    }

    private func accounts(_ container: ModelContainer) throws -> [String: String?] {
        let samples = try ModelContext(container).fetch(FetchDescriptor<TokenSample>())
        return Dictionary(uniqueKeysWithValues: samples.map { ($0.dedupKey ?? "", $0.accountId) })
    }

    @Test("CLI turns follow the trail; Desktop's follow Desktop's record, or stay unattributed")
    func newTurns() async throws {
        let rig = try rig()
        defer {
            try? FileManager.default.removeItem(at: rig.configRoot)
            try? FileManager.default.removeItem(at: rig.sessionsRoot)
        }
        _ = try await rig.coordinator.runOnce()

        let byTurn = try accounts(rig.container)
        #expect(byTurn["c1:req-c1"] == .some(cliOrg))
        #expect(byTurn["d1:req-d1"] == .some(desktopOrg))
        #expect(byTurn["d2:req-d2"] == .some(desktopOrg))
        // Desktop's, but no record: never the CLI's account.
        #expect(byTurn["u1:req-u1"] == .some(nil))

        // Desktop's account exists, so its usage has somewhere to show.
        let context = ModelContext(rig.container)
        let ids = Set(try context.fetch(FetchDescriptor<Account>()).map(\.id))
        #expect(ids.contains(desktopOrg))

        // The per-account rollups split the same total the unscoped one holds.
        let perAccount = try context.fetch(FetchDescriptor<AccountDailyAggregate>())
        let all = try context.fetch(FetchDescriptor<DailyAggregate>())
        #expect(perAccount.reduce(0) { $0 + $1.outputTokens } == all.reduce(0) { $0 + $1.outputTokens })
        let desktopOutput = perAccount.filter { $0.accountId == desktopOrg }.reduce(0) { $0 + $1.outputTokens }
        #expect(desktopOutput == 100)
    }

    @Test("history stamped with the CLI's account moves on the first scan, rollups included")
    func historyIsRepaired() async throws {
        // A turn of the recorded Desktop session, stored before #244 with the
        // CLI's account, from a transcript Claude Code has since cleaned up.
        let old = makeSample(session: "desk", account: cliOrg)
        old.dedupKey = "old:req-old"
        let rig = try rig(preexisting: [old])
        defer {
            try? FileManager.default.removeItem(at: rig.configRoot)
            try? FileManager.default.removeItem(at: rig.sessionsRoot)
        }
        _ = try await rig.coordinator.runOnce()

        #expect(try accounts(rig.container)["old:req-old"] == .some(desktopOrg))
        let perAccount = try ModelContext(rig.container).fetch(FetchDescriptor<AccountDailyAggregate>())
        let cliDay = perAccount.filter { $0.accountId == cliOrg && $0.date == old.date }
        #expect(cliDay.reduce(0) { $0 + $1.outputTokens } == 0)
        let desktopDay = perAccount.filter { $0.accountId == desktopOrg && $0.date == old.date }
        #expect(desktopDay.reduce(0) { $0 + $1.outputTokens } == 1)
    }
}
