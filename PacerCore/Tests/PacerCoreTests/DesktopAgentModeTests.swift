import Foundation
import SwiftData
import Testing
@testable import PacerCore

// #250: Claude Desktop's agent mode (Cowork) runs Claude Code in a sandbox of
// its own and keeps the transcripts inside Desktop's data folder, which Pacer
// never scanned. Each session's `.claude` folder is a root that belongs to the
// org folder it sits in. Fictional ids throughout.

private let cliOrg = "11111111-1111-4111-8111-111111111111"
private let agentOrg = "22222222-2222-4222-8222-222222222222"
private let desktopUser = "44444444-4444-4444-8444-444444444444"

private func tempDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pacer-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func line(
    _ timestamp: String, session: String, message: String, output: Int = 50,
    complete: Bool = true, entrypoint: String? = "local-agent", cwd: String = "/sessions/quiet-otter"
) -> String {
    var fields: [String: Any] = [
        "type": "assistant", "timestamp": timestamp, "sessionId": session,
        "requestId": "req-\(message)", "cwd": cwd,
        "message": [
            "id": message, "model": "claude-opus-4-7",
            "stop_reason": complete ? "end_turn" : NSNull(),
            "usage": ["input_tokens": 100, "output_tokens": output],
        ] as [String: Any],
    ]
    if let entrypoint { fields["entrypoint"] = entrypoint }
    return String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
}

/// One agent-mode session laid out the way Desktop keeps it: the record
/// (pretty-printed, as agent mode writes them) beside a folder of the same
/// name holding the sandbox's `.claude`.
@discardableResult
private func writeAgentSession(
    in data: URL, org: String = agentOrg, session: String, lines: [String],
    record: Bool = true, underAgent: Bool = false
) throws -> URL {
    var folder = data.appendingPathComponent("local-agent-mode-sessions")
        .appendingPathComponent(desktopUser).appendingPathComponent(org)
    if underAgent { folder = folder.appendingPathComponent("agent") }
    let name = "local_\(UUID().uuidString.lowercased())"
    let projects = folder.appendingPathComponent(name)
        .appendingPathComponent(".claude/projects/-sessions-quiet-otter")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    if record {
        try "{\n  \"sessionId\": \"\(name)\",\n  \"processName\": \"quiet-otter\",\n  \"cliSessionId\": \"\(session)\",\n  \"lastActivityAt\": 1790000000000\n}"
            .write(to: folder.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8)
    }
    let transcript = projects.appendingPathComponent("\(session).jsonl")
    try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
    // Cowork's own action log sits beside the sandbox. Not a transcript.
    try line("2026-10-01T09:00:00Z", session: session, message: "audit-\(name)")
        .write(to: folder.appendingPathComponent(name).appendingPathComponent("audit.jsonl"),
               atomically: true, encoding: .utf8)
    return transcript
}

@Suite("Desktop's agent-mode sessions")
struct DesktopAgentModeDirectoryTests {

    @Test("each session's .claude is a root of the org it sits under, with a fixed project")
    func rootsAndOrgs() throws {
        let data = try tempDirectory("desktop-data")
        defer { try? FileManager.default.removeItem(at: data) }
        let a = UUID().uuidString.lowercased(), ditto = UUID().uuidString.lowercased()
        let orphan = UUID().uuidString.lowercased()
        try writeAgentSession(in: data, session: a, lines: [])
        try writeAgentSession(in: data, session: ditto, lines: [], underAgent: true)
        try writeAgentSession(in: data, session: orphan, lines: [], record: false)
        // `skills-plugin` at the user level holds org ids too; nothing in it
        // is a session.
        let plugin = data.appendingPathComponent("local-agent-mode-sessions/skills-plugin")
            .appendingPathComponent(agentOrg).appendingPathComponent("local_x/.claude/projects")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)

        let directory = DesktopSessionDirectory(dataDirectories: [data])
        let roots = directory.scanRoots

        #expect(roots.count == 3)
        #expect(roots.allSatisfy { $0.fixedProjectPath == DesktopSessionDirectory.agentProjectPath })
        #expect(roots.allSatisfy { directory.account(forAgentRoot: $0.root.path) == agentOrg })
        #expect(directory.account(forAgentRoot: "/somewhere/else/.claude") == nil)
        // The pretty-printed record, the ditto one, and the session whose
        // record is gone (named by its transcript) all map to the org.
        #expect(directory.accounts == [a: agentOrg, ditto: agentOrg, orphan: agentOrg])
        #expect(directory.agentSessionDirectories.count == 1)
    }

    @Test("an agent-mode line is Desktop's")
    func entrypoint() {
        let entry = JSONLLineParser.parse(line: line("2026-10-01T10:00:00Z", session: "s", message: "m"))
        #expect(entry?.entrypoint == "local-agent")
        #expect(entry?.isFromDesktop == true)
    }

    @Test("a hinted file is stamped with the root it sits under, and that root's project")
    func hintedFilesKeepTheirRoot() async throws {
        let data = try tempDirectory("desktop-data")
        defer { try? FileManager.default.removeItem(at: data) }
        let session = UUID().uuidString.lowercased()
        let transcript = try writeAgentSession(in: data, session: session, lines: [
            line("2026-10-01T10:00:00Z", session: session, message: "m1"),
        ])
        let roots = DesktopSessionDirectory(dataDirectories: [data]).scanRoots
        final class Box: @unchecked Sendable { var entries: [ParsedUsageEntry] = [] }
        let box = Box()
        _ = try await JSONLScanner().scan(
            roots: roots, hintedPaths: [transcript.path], emit: { box.entries.append($0) })

        #expect(box.entries.count == 1)
        #expect(box.entries.first?.rootPath == roots.first?.root.path)
        #expect(box.entries.first?.projectPath == DesktopSessionDirectory.agentProjectPath)
        #expect(box.entries.first?.originalProjectPath == "/sessions/quiet-otter")
    }
}

@Suite("A scan counts agent-mode turns once, against the session's org")
@ScanActor
struct DesktopAgentModeScanTests {

    @Test("totals rise by exactly the agent-mode turns; the CLI's are unchanged")
    func countsOnce() async throws {
        let configRoot = try tempDirectory("agent-config")
        let data = try tempDirectory("agent-data")
        defer {
            try? FileManager.default.removeItem(at: configRoot)
            try? FileManager.default.removeItem(at: data)
        }
        try #"{"oauthAccount":{"organizationUuid":"\#(cliOrg)"}}"#
            .write(to: configRoot.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let projects = configRoot.appendingPathComponent("projects/-tmp-acme")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try (line("2026-10-01T10:00:00Z", session: "cli-session", message: "c1",
                  entrypoint: "cli", cwd: "/tmp/acme") + "\n")
            .write(to: projects.appendingPathComponent("cli-session.jsonl"), atomically: true, encoding: .utf8)

        let session = UUID().uuidString.lowercased()
        try writeAgentSession(in: data, session: session, lines: [
            // Streamed: the mid-stream copy, then the finished one.
            line("2026-10-01T10:01:00Z", session: session, message: "a1", output: 1, complete: false),
            line("2026-10-01T10:01:02Z", session: session, message: "a1", output: 300),
            line("2026-10-01T10:02:00Z", session: session, message: "a2", output: 70),
        ])

        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(AccountActivation(
            accountId: cliOrg, startedAt: .distantPast, source: AccountActivation.sourceObserved))
        try context.save()
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false,
                                 desktopSessions: DesktopSessionDirectory(dataDirectories: [data])),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": configRoot.path]),
            homeDirectory: configRoot)
        _ = try await coordinator.runOnce()

        let samples = try ModelContext(container).fetch(FetchDescriptor<TokenSample>())
        let agent = samples.filter { $0.sessionId == session }
        let cli = samples.filter { $0.sessionId == "cli-session" }
        // Once each, the finished copy of the streamed one, and never the
        // audit log's line.
        #expect(agent.count == 2)
        #expect(agent.map(\.outputTokens).sorted() == [70, 300])
        #expect(agent.allSatisfy { $0.accountId == agentOrg })
        #expect(agent.allSatisfy { $0.projectPath == DesktopSessionDirectory.agentProjectPath })
        #expect(cli.count == 1)
        #expect(cli.first?.accountId == cliOrg)
        #expect(cli.first?.outputTokens == 50)
        #expect(samples.count == 3)

        // The org gets an account, and the per-account rollups split the
        // same total the unscoped one holds.
        let ids = Set(try ModelContext(container).fetch(FetchDescriptor<Account>()).map(\.id))
        #expect(ids.contains(agentOrg))
        let perAccount = try ModelContext(container).fetch(FetchDescriptor<AccountDailyAggregate>())
        #expect(perAccount.filter { $0.accountId == agentOrg }.reduce(0) { $0 + $1.outputTokens } == 370)
        #expect(perAccount.filter { $0.accountId == cliOrg }.reduce(0) { $0 + $1.outputTokens } == 50)
        let projectsRollup = try ModelContext(container).fetch(FetchDescriptor<ProjectDailyAggregate>())
        #expect(projectsRollup.contains { $0.projectPath == DesktopSessionDirectory.agentProjectPath })
    }
}
