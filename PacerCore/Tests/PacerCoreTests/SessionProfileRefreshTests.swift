import Foundation
import SwiftData
import Testing
@testable import PacerCore

// #322: scan roots were resolved once, at launch. A switcher session profile
// created while Pacer ran (`cswap run`, a new pinned `CLAUDE_CONFIG_DIR`) was
// not scanned until the next restart: its turns missing from every total, with
// nothing to say so. Fictional ids and names throughout.

private let defaultOrg = "11111111-1111-4111-8111-111111111111"
private let profileOrg = "22222222-2222-4222-8222-222222222222"

private func tempDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pacer-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.canonicalPathURL
}

private func line(
    _ timestamp: String, session: String, message: String, output: Int = 50, complete: Bool = true
) -> String {
    let fields: [String: Any] = [
        "type": "assistant", "timestamp": timestamp, "sessionId": session,
        "requestId": "req-\(message)", "cwd": "/tmp/acme", "entrypoint": "cli",
        "message": [
            "id": message, "model": "claude-opus-4-7",
            "stop_reason": complete ? "end_turn" : NSNull(),
            "usage": ["input_tokens": 100, "output_tokens": output],
        ] as [String: Any],
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
}

@discardableResult
private func writeTranscript(under root: URL, session: String, lines: [String]) throws -> URL {
    let projects = root.appendingPathComponent("projects/-tmp-acme")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let url = projects.appendingPathComponent("\(session).jsonl")
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func writeLogin(_ root: URL, org: String) throws {
    try #"{"oauthAccount":{"organizationUuid":"\#(org)"}}"#
        .write(to: root.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
}

/// A claude-swap session profile under `home`, signed into `org`, created on
/// 2026-09-01 — before every fixture turn, as a real profile is.
private func makeProfile(_ home: URL, _ name: String, org: String) throws -> URL {
    let profile = home.appendingPathComponent(".claude-swap-backup/sessions/\(name)")
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    try writeLogin(profile, org: org)
    try FileManager.default.setAttributes(
        [.creationDate: ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")!],
        ofItemAtPath: profile.path)
    return profile
}

@ScanActor
private func makeCoordinator(
    home: URL, primaryRoot: URL, defaultAccount: String
) throws -> (ScanCoordinator, ModelContainer) {
    let container = try PacerStore.makeInMemoryContainer()
    let context = ModelContext(container)
    context.insert(AccountActivation(
        accountId: defaultAccount, startedAt: .distantPast, source: AccountActivation.sourceObserved))
    try context.save()
    let coordinator = ScanCoordinator(
        container: container,
        configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false,
                             desktopSessions: nil),
        resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": primaryRoot.path]),
        homeDirectory: home)
    return (coordinator, container)
}

private func samples(_ container: ModelContainer) throws -> [TokenSample] {
    try ModelContext(container).fetch(FetchDescriptor<TokenSample>())
}

@Suite("A session profile created while Pacer runs is scanned without a restart (#322)")
@ScanActor
struct SessionProfileRefreshTests {

    @Test("its first write is heard: scanned within one cycle, on its account, each turn once")
    func newProfileIsScannedOnItsFirstWrite() async throws {
        let home = try tempDirectory("profile-home")
        let configRoot = try tempDirectory("profile-default")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: configRoot)
        }
        try writeLogin(configRoot, org: defaultOrg)
        let defaultTranscript = try writeTranscript(under: configRoot, session: "cli-session", lines: [
            line("2026-10-01T10:00:00Z", session: "cli-session", message: "d1"),
            line("2026-10-01T10:01:00Z", session: "cli-session", message: "shared", output: 80),
        ])
        let (coordinator, container) = try makeCoordinator(
            home: home, primaryRoot: configRoot, defaultAccount: defaultOrg)
        _ = try await coordinator.runOnce()
        #expect(try samples(container).count == 2)
        #expect(coordinator.resolvedRootsForTesting.count == 1)

        // `cswap run` while Pacer runs: a profile appears with a transcript
        // that resumes the default login's session (its first turn is a
        // replayed copy of "shared") and goes on with turns of its own, one of
        // them streamed.
        let profile = try makeProfile(home, "2-personal", org: profileOrg)
        let transcript = try writeTranscript(under: profile, session: "profile-session", lines: [
            line("2026-10-01T10:01:00Z", session: "profile-session", message: "shared", output: 80),
            line("2026-10-01T11:00:00Z", session: "profile-session", message: "p1", output: 1,
                 complete: false),
            line("2026-10-01T11:00:02Z", session: "profile-session", message: "p1", output: 300),
            line("2026-10-01T11:05:00Z", session: "profile-session", message: "p2", output: 70),
        ])
        // The folder did not exist when the watcher was last handed its paths.
        #expect(!coordinator.watchedExtraPathsForTesting.contains {
            $0.hasSuffix(".claude-swap-backup/sessions") })

        // Its first write, as FSEvents reports it: a transcript no root claims.
        await coordinator.watcherForTesting.noteChangedPathsForTesting([transcript.path])
        _ = try await coordinator.runOnce()

        #expect(coordinator.resolvedRootsForTesting.map(\.root.path)
                == [configRoot.path, profile.canonicalPathURL.path])
        #expect(coordinator.profileRootRelistsForTesting == 1)
        // And is watched from this re-listing on.
        #expect(coordinator.watchedExtraPathsForTesting.contains {
            $0.hasSuffix(".claude-swap-backup/sessions") })
        let all = try samples(container)
        let own = all.filter { $0.sessionId == "profile-session" }
        // Its own turns, once each, the finished copy of the streamed one, on
        // the profile's account — including the ones written before Pacer
        // found it.
        #expect(own.count == 2)
        #expect(own.map(\.outputTokens).sorted() == [70, 300])
        #expect(own.allSatisfy { $0.accountId == profileOrg })
        // The replayed turn stays the one row it already was, where it was.
        let shared = all.filter { $0.dedupKey == "shared:req-shared" }
        #expect(shared.count == 1)
        #expect(shared.first?.accountId == defaultOrg)
        #expect(all.count == 4)
        #expect(all.filter { $0.accountId == defaultOrg }.count == 2)

        // Nothing changed: a write under a known root, then a full walk inside
        // the minute. Neither lists the folders or adds a root again.
        try (line("2026-10-01T12:00:00Z", session: "cli-session", message: "d2") + "\n")
            .appendLine(to: defaultTranscript)
        await coordinator.watcherForTesting.noteChangedPathsForTesting([defaultTranscript.path])
        _ = try await coordinator.runOnce()
        _ = try await coordinator.runOnce()
        #expect(coordinator.profileRootRelistsForTesting == 1)
        #expect(coordinator.resolvedRootsForTesting.count == 2)
        #expect(try samples(container).count == 5)

        // The minute's re-listing finds the same profile: nothing is added and
        // nothing is read twice.
        coordinator.expireProfileRootRefreshForTesting()
        _ = try await coordinator.runOnce()
        #expect(coordinator.profileRootRelistsForTesting == 2)
        #expect(coordinator.resolvedRootsForTesting.count == 2)
        #expect(try samples(container).count == 5)
    }

    @Test("without a write, the minute's full walk finds it; a profile that is the primary root is not added twice")
    func backstopFindsProfileAndSkipsThePrimary() async throws {
        let home = try tempDirectory("profile-home")
        defer { try? FileManager.default.removeItem(at: home) }
        // Pacer itself pointed at one profile (a probe's `CLAUDE_CONFIG_DIR`):
        // the same root reachable as primary and by discovery.
        let work = try makeProfile(home, "1-work", org: defaultOrg)
        try writeTranscript(under: work, session: "work-session", lines: [
            line("2026-10-01T09:00:00Z", session: "work-session", message: "w1"),
        ])
        let (coordinator, container) = try makeCoordinator(
            home: home, primaryRoot: work, defaultAccount: defaultOrg)
        _ = try await coordinator.runOnce()
        #expect(coordinator.resolvedRootsForTesting.count == 1)

        let personal = try makeProfile(home, "2-personal", org: profileOrg)
        try writeTranscript(under: personal, session: "personal-session", lines: [
            line("2026-10-01T11:00:00Z", session: "personal-session", message: "p1"),
        ])
        // A full walk inside the minute does not list: the profile waits.
        _ = try await coordinator.runOnce()
        #expect(coordinator.profileRootRelistsForTesting == 0)
        #expect(try samples(container).count == 1)

        coordinator.expireProfileRootRefreshForTesting()
        _ = try await coordinator.runOnce()
        #expect(coordinator.profileRootRelistsForTesting == 1)
        #expect(coordinator.resolvedRootsForTesting.map(\.root.path)
                == [work.canonicalPathURL.path, personal.canonicalPathURL.path])
        let all = try samples(container)
        #expect(all.count == 2)
        #expect(all.first { $0.sessionId == "work-session" }?.accountId == defaultOrg)
        #expect(all.first { $0.sessionId == "personal-session" }?.accountId == profileOrg)
    }

    @Test("a file under the switcher's folders that no profile claims is never read as the default login's")
    func strayFileIsDropped() async throws {
        let home = try tempDirectory("profile-home")
        let configRoot = try tempDirectory("profile-default")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: configRoot)
        }
        try writeLogin(configRoot, org: defaultOrg)
        try writeTranscript(under: configRoot, session: "cli-session", lines: [
            line("2026-10-01T10:00:00Z", session: "cli-session", message: "d1"),
        ])
        let (coordinator, container) = try makeCoordinator(
            home: home, primaryRoot: configRoot, defaultAccount: defaultOrg)
        _ = try await coordinator.runOnce()

        // A profile folder with no `projects/` yet, holding a stray `.jsonl`.
        let scratch = home.appendingPathComponent(".claude-swap-backup/sessions/3-scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let stray = scratch.appendingPathComponent("stray.jsonl")
        try (line("2026-10-01T11:00:00Z", session: "stray", message: "s1") + "\n")
            .write(to: stray, atomically: true, encoding: .utf8)
        await coordinator.watcherForTesting.noteChangedPathsForTesting([stray.path])
        _ = try await coordinator.runOnce()

        #expect(coordinator.profileRootRelistsForTesting == 1)
        #expect(coordinator.resolvedRootsForTesting.count == 1)
        #expect(try samples(container).count == 1)
        #expect(try samples(container).allSatisfy { $0.sessionId != "stray" })
    }
}

@Suite("The watcher hears a profile's transcripts under its sessions folder, and nothing else there")
struct ProfileFolderWatchTests {

    @Test("a transcript under a discovery folder counts; a profile's history and Cowork's audit log do not")
    func transcriptFilter() {
        let sessions = "/h/.claude-swap-backup/sessions/"
        #expect(JSONLWatcher.isTranscript(
            sessions + "2-personal/projects/-tmp-acme/s.jsonl", underDiscoveryFolder: sessions))
        #expect(JSONLWatcher.isTranscript(
            sessions + "2-personal/projects/-tmp-acme/s/subagents/agent-a.jsonl",
            underDiscoveryFolder: sessions))
        #expect(!JSONLWatcher.isTranscript(sessions + "2-personal/history.jsonl",
                                           underDiscoveryFolder: sessions))
        #expect(!JSONLWatcher.isTranscript(sessions + "stray.jsonl", underDiscoveryFolder: sessions))

        let agent = "/d/local-agent-mode-sessions/"
        #expect(JSONLWatcher.isTranscript(
            agent + "u/o/local_x/.claude/projects/-sessions-quiet-otter/s.jsonl",
            underDiscoveryFolder: agent))
        #expect(!JSONLWatcher.isTranscript(agent + "u/o/local_x/audit.jsonl",
                                           underDiscoveryFolder: agent))
    }

    @Test("existing profiles are covered by their sessions folder rather than watched one by one")
    func profilesAreCoveredByTheirFolder() {
        let primary = ClaudePathResolver.ResolvedRoot(
            root: URL(fileURLWithPath: "/h/.claude"),
            projectsDirectory: URL(fileURLWithPath: "/h/.claude/projects"))
        let profile = ClaudePathResolver.ResolvedRoot(
            root: URL(fileURLWithPath: "/h/.claude-swap-backup/sessions/2-personal"),
            projectsDirectory: URL(fileURLWithPath: "/h/.claude-swap-backup/sessions/2-personal/projects"))
        let paths = JSONLWatcher.watchPaths(
            roots: [primary, profile],
            discovery: ["/h/.claude-swap-backup/sessions/"],
            extraPaths: ["/h/.claude-swap-backup/sessions"])
        #expect(paths == ["/h/.claude/projects", "/h/.claude-swap-backup/sessions"])
    }
}

private extension String {
    func appendLine(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(utf8))
    }
}
