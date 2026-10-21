import CommonCrypto
import Foundation
import SwiftData
import Testing
@testable import PacerCore

// #295: several Claude Desktop installs at once, each its own data folder,
// all treated alike. Fixtures only; fictional ids throughout.

private let cliOrg = "11111111-1111-4111-8111-111111111111"
private let workOrg = "22222222-2222-4222-8222-222222222222"
private let homeOrg = "33333333-3333-4333-8333-333333333333"
private let desktopUser = "44444444-4444-4444-8444-444444444444"

private func tempDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pacer-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeRecord(in data: URL, org: String, session: String) throws {
    let folder = data.appendingPathComponent("claude-code-sessions")
        .appendingPathComponent(desktopUser).appendingPathComponent(org)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try #"{"sessionId":"local_x","cliSessionId":"\#(session)","cwd":"/tmp/acme"}"#
        .write(to: folder.appendingPathComponent("local_\(UUID().uuidString).json"),
               atomically: true, encoding: .utf8)
}

private func desktopLine(_ timestamp: String, session: String, message: String) -> String {
    let fields: [String: Any] = [
        "type": "assistant", "timestamp": timestamp, "sessionId": session,
        "requestId": "req-\(message)", "cwd": "/tmp/acme", "entrypoint": "claude-desktop",
        "message": [
            "id": message, "model": "claude-opus-4-7", "stop_reason": "end_turn",
            "usage": ["input_tokens": 100, "output_tokens": 50],
        ] as [String: Any],
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
}

@Suite("Finding Desktop installs")
struct DesktopInstallDiscoveryTests {

    @Test("Application Support folders that hold records or a token cache, running ones, added ones")
    func discovers() throws {
        let support = try tempDirectory("app-support")
        let elsewhere = try tempDirectory("elsewhere")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: support.appendingPathComponent("Claude/claude-code-sessions"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: support.appendingPathComponent("Claude-Work/local-agent-mode-sessions"),
                               withIntermediateDirectories: true)
        // Another Anthropic app's folder: one config file, no sessions, no cache.
        try fm.createDirectory(at: support.appendingPathComponent("Claude-3p"), withIntermediateDirectories: true)
        try "{}".write(to: support.appendingPathComponent("Claude-3p/claude_desktop_config.json"),
                       atomically: true, encoding: .utf8)
        // A token cache alone is enough.
        try fm.createDirectory(at: support.appendingPathComponent("ClaudeHome"), withIntermediateDirectories: true)
        try #"{"oauth:tokenCache":"djEw"}"#.write(
            to: support.appendingPathComponent("ClaudeHome/config.json"), atomically: true, encoding: .utf8)
        // Not a Claude folder at all.
        try fm.createDirectory(at: support.appendingPathComponent("Other/claude-code-sessions"),
                               withIntermediateDirectories: true)
        let running = elsewhere.appendingPathComponent("instances/personal")
        let config = elsewhere.appendingPathComponent("instances/personal-code")
        let added = elsewhere.appendingPathComponent("ClaudeLab")
        try fm.createDirectory(at: running, withIntermediateDirectories: true)
        try fm.createDirectory(at: added, withIntermediateDirectories: true)

        let installs = DesktopInstallDiscovery.installs(
            applicationSupport: support,
            running: [.init(dataDirectory: running, configDirectory: config),
                      // The standard install, launched without the argument.
                      .init(dataDirectory: nil, configDirectory: nil)],
            remembered: [:],
            extraPaths: [added.path, elsewhere.appendingPathComponent("missing").path])

        #expect(installs.map(\.folderName) == ["Claude", "Claude-Work", "ClaudeHome", "personal", "ClaudeLab"])
        #expect(installs.first { $0.folderName == "personal" }?.configDirectory?.path
                == config.canonicalPathURL.path)
        #expect(installs.filter { $0.folderName == "Claude" }.count == 1)
    }

    @Test("a running Desktop's data folder and config folder come from its launch")
    func parsesLaunch() {
        let joined = DesktopInstallDiscovery.parse(
            arguments: ["--user-data-dir=/tmp/acme profile", "--other"],
            environment: ["HOME=/tmp", "CLAUDE_CONFIG_DIR=/tmp/acme-code,/tmp/ignored", "OTHER=x"])
        #expect(joined.dataDirectory?.path == "/tmp/acme profile")
        #expect(joined.configDirectory?.path == "/tmp/acme-code")
        let split = DesktopInstallDiscovery.parse(arguments: ["--user-data-dir", "/tmp/globex"], environment: [])
        #expect(split.dataDirectory?.path == "/tmp/globex")
        #expect(split.configDirectory == nil)
        let none = DesktopInstallDiscovery.parse(arguments: [], environment: [])
        #expect(none.dataDirectory == nil)
    }

    @Test("one install is Desktop; several are named by folder")
    func labels() {
        let one = [DesktopInstall(dataDirectory: URL(fileURLWithPath: "/s/Claude"))]
        #expect(DesktopInstall.labels(for: one).values.first == "Desktop")
        let several = [
            DesktopInstall(dataDirectory: URL(fileURLWithPath: "/s/Claude")),
            DesktopInstall(dataDirectory: URL(fileURLWithPath: "/s/Claude-Work")),
            DesktopInstall(dataDirectory: URL(fileURLWithPath: "/a/work")),
            DesktopInstall(dataDirectory: URL(fileURLWithPath: "/b/work")),
        ]
        let labels = DesktopInstall.labels(for: several)
        #expect(labels["/s/Claude"] == "Desktop · Claude")
        // A clash is told apart by the parent folder, and "Claude-Work" is
        // "Work", which clashes with neither "work".
        #expect(labels["/s/Claude-Work"] == "Desktop · Work")
        #expect(labels["/a/work"] == "Desktop · a/work")
        #expect(labels["/b/work"] == "Desktop · b/work")
    }
}

@Suite("Every install's records, merged")
struct DesktopInstallsDirectoryTests {

    @Test("each install's sessions go to its own org; a shared session is kept once")
    func merges() throws {
        let work = try tempDirectory("desktop-work")
        let home = try tempDirectory("desktop-home")
        defer {
            try? FileManager.default.removeItem(at: work)
            try? FileManager.default.removeItem(at: home)
        }
        try writeRecord(in: work, org: workOrg, session: "work-session")
        try writeRecord(in: home, org: homeOrg, session: "home-session")
        // Both installs recorded this one under the same org (a copied
        // folder): one session, one account.
        try writeRecord(in: work, org: workOrg, session: "copied")
        try writeRecord(in: home, org: workOrg, session: "copied")
        // Two installs naming different orgs for one session: no account.
        try writeRecord(in: work, org: workOrg, session: "contested")
        try writeRecord(in: home, org: homeOrg, session: "contested")

        let directory = DesktopSessionDirectory(dataDirectories: [work, home])
        #expect(directory.installs.count == 2)
        #expect(directory.accounts == [
            "work-session": workOrg, "home-session": homeOrg, "copied": workOrg,
        ])
    }

    @Test("an install's own CLAUDE_CONFIG_DIR is a scan root")
    func configRoot() throws {
        let data = try tempDirectory("desktop-data")
        let config = try tempDirectory("desktop-code")
        defer {
            try? FileManager.default.removeItem(at: data)
            try? FileManager.default.removeItem(at: config)
        }
        try FileManager.default.createDirectory(
            at: config.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let directory = DesktopSessionDirectory(
            installs: [DesktopInstall(dataDirectory: data, configDirectory: config)])
        #expect(directory.scanRoots.map(\.root.path) == [config.canonicalPathURL.path])
        #expect(directory.scanRoots.first?.fixedProjectPath == nil)
    }

    @Test("a reader picks up an install that appears later")
    func rediscovers() throws {
        let data = try tempDirectory("desktop-late")
        defer { try? FileManager.default.removeItem(at: data) }
        try writeRecord(in: data, org: workOrg, session: "late-session")
        final class Box: @unchecked Sendable { var installs: [DesktopInstall] = [] }
        let box = Box()
        let directory = DesktopSessionDirectory(discover: { box.installs })
        #expect(directory.accounts.isEmpty)
        box.installs = [DesktopInstall(dataDirectory: data)]
        directory.refresh()
        #expect(directory.accounts == ["late-session": workOrg])
    }
}

@Suite("A scan across two installs")
@ScanActor
struct DesktopInstallsScanTests {

    @Test("two installs, two orgs, one session each: each counted once, against its own org")
    func twoInstalls() async throws {
        let configRoot = try tempDirectory("installs-config")
        let work = try tempDirectory("installs-work")
        let home = try tempDirectory("installs-home")
        defer {
            for url in [configRoot, work, home] { try? FileManager.default.removeItem(at: url) }
        }
        try #"{"oauthAccount":{"organizationUuid":"\#(cliOrg)"}}"#
            .write(to: configRoot.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let projects = configRoot.appendingPathComponent("projects/-tmp-acme")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        // Both Desktops write into the shared `~/.claude/projects`, the way
        // tools without a CLAUDE_CONFIG_DIR leave them.
        try (desktopLine("2026-10-01T10:00:00Z", session: "work-session", message: "w1") + "\n")
            .write(to: projects.appendingPathComponent("work-session.jsonl"), atomically: true, encoding: .utf8)
        try (desktopLine("2026-10-01T10:01:00Z", session: "home-session", message: "h1") + "\n")
            .write(to: projects.appendingPathComponent("home-session.jsonl"), atomically: true, encoding: .utf8)
        try writeRecord(in: work, org: workOrg, session: "work-session")
        try writeRecord(in: home, org: homeOrg, session: "home-session")

        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(AccountActivation(
            accountId: cliOrg, startedAt: .distantPast, source: AccountActivation.sourceObserved))
        try context.save()
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false,
                                 desktopSessions: DesktopSessionDirectory(dataDirectories: [work, home])),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": configRoot.path]),
            homeDirectory: configRoot)
        _ = try await coordinator.runOnce()

        let samples = try ModelContext(container).fetch(FetchDescriptor<TokenSample>())
        #expect(samples.count == 2)
        #expect(samples.first { $0.sessionId == "work-session" }?.accountId == workOrg)
        #expect(samples.first { $0.sessionId == "home-session" }?.accountId == homeOrg)
    }
}

@Suite("Every install's token cache")
struct DesktopInstallsTokenTests {

    private static let testKey = Data("pacer-test-safe-storage-key".utf8)

    private func blob(token: String, account: String, key: Data = testKey) -> String {
        let expiry = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000
        let dict: [String: Any] = [
            "c1:\(account):https://api.anthropic.com:user:profile": [
                "token": token, "expiresAt": expiry, "subscriptionType": "max",
            ],
        ]
        let plaintext = try! JSONSerialization.data(withJSONObject: dict)
        let derived = DesktopOAuth.pbkdf2SHA1(password: key, salt: Data("saltysalt".utf8),
                                              rounds: 1003, keyLength: kCCKeySizeAES128)!
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        _ = out.withUnsafeMutableBytes { o in
            plaintext.withUnsafeBytes { p in derived.withUnsafeBytes { k in iv.withUnsafeBytes { v in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, derived.count, v.baseAddress, p.baseAddress, plaintext.count,
                        o.baseAddress, o.count, &moved)
            }}}
        }
        out.removeSubrange(moved..<out.count)
        return (Data("v10".utf8) + out).base64EncodedString()
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test("two installs sharing one keychain key cost one key read, and both tokens are kept")
    func oneKeyReadForTwoInstalls() {
        let reads = Counter()
        // Same account in both, so the cache keys match too: merging by key
        // would have kept one token and dropped the other's budget.
        let blobs = [blob(token: "work-token", account: "acct"), blob(token: "home-token", account: "acct")]
        let client = OAuthClient(
            keychain: KeychainOAuth(rawReader: { .failure(.notFound) }),
            desktop: DesktopOAuth(keyReader: { reads.bump(); return .success(Self.testKey) },
                                  cacheReader: { blobs }),
            desktopEnabled: { true },
            desktopKeyStore: EphemeralDesktopKeyStore(nil))

        let first = client.candidateCredentials().map(\.credential.accessToken)
        #expect(Set(first) == ["work-token", "home-token"])
        _ = client.candidateCredentials()
        #expect(reads.count == 1)
    }

    @Test("an install whose key does not decrypt is skipped, never failing the others")
    func foreignKeySkipped() {
        let d = DesktopOAuth(keyReader: { .success(Self.testKey) }, cacheReader: { nil })
        let creds = d.profileCredentials(
            fromBlobs: [blob(token: "ours", account: "a"),
                        blob(token: "theirs", account: "b", key: Data("another-key".utf8))],
            keyPassword: Self.testKey)
        #expect(creds.map(\.accessToken) == ["ours"])
    }
}
