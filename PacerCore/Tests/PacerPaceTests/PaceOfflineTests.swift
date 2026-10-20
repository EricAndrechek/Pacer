import Foundation
import SwiftData
import Testing
@testable import PacerCore
@testable import PacerPace

/// #194: with nothing listening on Pacer's port, `pace` answers from the store
/// through `PacerOfflineAPI`, using the server's own builders and route
/// answers. The test that matters: the same store gives the same output
/// whether the API serves it or the store does.
@Suite("pace: answered from the store when the API is off")
struct PaceOfflineTests {

    static let now = Date()
    /// Nothing listens on port 1.
    static let deadAPI = "http://127.0.0.1:1"

    /// Two logins with readings, and one session's turns on the active one.
    @MainActor
    static func store() throws -> ModelContainer {
        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        for (id, five, seven, active) in [("org-work", 37.5, 21.0, true), ("org-home", 2.25, 5.0, false)] {
            context.insert(Account(id: id, organizationId: id, displayName: "Acme \(id)",
                                   isActive: active, firstSeenAt: .distantPast, lastSeenAt: now))
            context.insert(RateLimitSample(
                sampledAt: now.addingTimeInterval(-60), window: RateLimitWindowName.fiveHour,
                usedPercentage: five, resetsAt: now.addingTimeInterval(3_600),
                source: RateLimitSource.oauth, accountId: id))
            context.insert(RateLimitSample(
                sampledAt: now.addingTimeInterval(-60), window: RateLimitWindowName.sevenDay,
                usedPercentage: seven, resetsAt: now.addingTimeInterval(90_000),
                source: RateLimitSource.oauth, accountId: id))
        }
        context.insert(AccountActivation(accountId: "org-work", startedAt: .distantPast,
                                         source: AccountActivation.sourceObserved))
        let at = now.addingTimeInterval(-300)
        let sample = TokenSample(
            sampledAt: at, date: TokenSample.formatDate(at), model: "claude-opus-5",
            inputTokens: 10, outputTokens: 20, cacheReadTokens: 0,
            cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
            sessionId: "session-194", projectPath: "/tmp/acme")
        sample.accountId = "org-work"
        context.insert(sample)
        try context.save()
        return container
    }

    static func offline(_ container: ModelContainer) -> PaceOffline {
        // The served run's snapshot is built at `now`; so is this one, or a
        // reset 3,600 s away on one side is 3,599 s on the other.
        PaceOffline(now: { now }) {
            PacerOfflineAPI(container: container, activeAccountId: { "org-work" }, desktop: nil)
        }
    }

    /// One run with a private state file. `get` is the transport; the store
    /// fallback is composed exactly as `PaceIO.live(offline:)` does.
    static func run(_ args: [String], api: String, offline: PaceOffline?,
                    extra: [String: String] = [:]) throws -> PaceResult {
        let box = try PaceSandbox(metrics: nil)
        var env = ["HOME": box.dir.path, "PATH": "/usr/bin:/bin", "PACER_API": api,
                   "PACE_STATE": box.stateURL.path, "PACE_RETRIES": "1"]
        for (key, value) in extra { env[key] = value }
        let capture = PaceCapture()
        let io = PaceIO(out: capture.append, err: capture.append, now: Date.init, sleep: { _ in },
                        get: { request in PaceHTTP.get(request) ?? offline?.answer(request) },
                        gitBranch: { _ in nil })
        return PaceResult(status: Pace.run(args, environment: env, io: io), out: capture.text)
    }

    /// The same store served "by the API": the server's `/metrics` text,
    /// written where `file://` reads it.
    @MainActor
    static func runServed(_ args: [String], container: ModelContainer) throws -> PaceResult {
        let snapshot = try PacerAPISnapshot.build(container: container, activeAccountId: "org-work",
                                                  desktop: nil, now: now)
        let text = PacerOfflineAPI.metrics(snapshot: snapshot, query: [:], now: now,
                                           version: "offline", build: "").body
        let box = try PaceSandbox(metrics: text)
        let env = ["HOME": box.dir.path, "PATH": "/usr/bin:/bin", "PACER_API": "file://\(box.dir.path)",
                   "PACE_STATE": box.stateURL.path, "PACE_RETRIES": "1"]
        let capture = PaceCapture()
        let io = PaceIO(out: capture.append, err: capture.append, now: Date.init, sleep: { _ in },
                        get: PaceHTTP.get, gitBranch: { _ in nil })
        return PaceResult(status: Pace.run(args, environment: env, io: io), out: capture.text)
    }

    @MainActor
    @Test("API off: the store gives what the API would have", arguments: [
        ["report"], ["json"], ["gate"], ["gate", "--cap", "30"], ["accounts"],
        ["report", "--account", "org-home"], ["gate", "--account", "all", "--cap", "20"],
    ])
    func sameAnswer(_ args: [String]) throws {
        let container = try Self.store()
        let served = try Self.runServed(args, container: container)
        let offline = try Self.run(args, api: Self.deadAPI, offline: Self.offline(container))
        // `pace`'s own clock still reads the wall: the verdict's timestamp,
        // a reset's local time and when a GO runs out, which two runs a
        // moment apart can see in different minutes.
        func normal(_ s: String) -> String {
            s.replacingOccurrences(of: #""(at|updatedAt)": "[^"]+""#, with: "\"$1\": \"<now>\"",
                                   options: .regularExpression)
                .replacingOccurrences(of: #"\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2}:\d{2} (AM|PM)\b"#,
                                      with: "<clock>", options: .regularExpression)
                .replacingOccurrences(of: #"\b\d{2}:\d{2}Z\b"#, with: "<utc>", options: .regularExpression)
        }
        #expect(offline.status == served.status)
        #expect(normal(offline.out) == normal(served.out))
        #expect(!offline.out.contains("no Pacer"))
    }

    @MainActor
    @Test("--model auto finds the session in the store")
    func sessionOffline() throws {
        let container = try Self.store()
        let result = try Self.run(["gate", "--model", "auto"], api: Self.deadAPI,
                                  offline: Self.offline(container),
                                  extra: ["CLAUDE_CODE_SESSION_ID": "session-194"])
        #expect(result.status == 0)
        #expect(result.out.contains("model auto: detected claude-opus-5"), "\(result.out)")
    }

    @MainActor
    @Test("no store, or not this machine: no Pacer, exit 2 as before")
    func noFallback() throws {
        let container = try Self.store()
        let unopenable = PaceOffline { nil }
        let none = try Self.run(["gate"], api: Self.deadAPI, offline: unopenable)
        #expect(none.status == 2)
        #expect(none.out.contains("no Pacer"))

        // A remote PACER_API is a question about that machine.
        let remote = try Self.run(["gate"], api: "http://pacer.invalid:7223", offline: Self.offline(container))
        #expect(remote.status == 2)
        #expect(PaceOffline.isLoopback(URL(string: "http://localhost:7223/metrics")!))
        #expect(!PaceOffline.isLoopback(URL(string: "file:///tmp/metrics")!))
    }
}
