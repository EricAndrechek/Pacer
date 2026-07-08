import Foundation
import SwiftData
import Testing
@testable import PacerCore

@Suite struct OAuthPollerTests {

    // MARK: - Helpers

    private static func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Heartbeat.self,
            TokenSample.self,
            DailyAggregate.self,
            ProjectDailyAggregate.self,
            RateLimitSample.self,
            SessionInfo.self,
            ClaudeCodeMeta.self,
            configurations: config
        )
    }

    /// Builds an `OAuthClient` whose transport returns a fixed sequence of
    /// HTTP results (last entry repeated), keyed off a single keychain
    /// token. Desktop is disabled so tests never touch the real machine.
    private static func sequencedClient(
        _ outcomes: [HTTPOutcome],
        keychainBlob: Data? = nil
    ) -> OAuthClient {
        let blob = keychainBlob ?? Self.defaultKeychainBlob()
        let kc = KeychainOAuth(rawReader: { .success(blob) })
        let counter = AtomicCounter()
        let outcomes = outcomes
        let transport: OAuthClient.Transport = { _ in
            let i = counter.next()
            return try outcomes[min(i, outcomes.count - 1)].materialize()
        }
        return OAuthClient(keychain: kc, transport: transport, desktopEnabled: { false })
    }

    private static func defaultKeychainBlob() -> Data { keychainBlob(token: "tok") }

    private static func keychainBlob(token: String) -> Data {
        let body: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": token,
                "expiresAt": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000,
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// Sendable summary so we don't ferry `@Model` instances across actors.
    private static func fetchSampleSummaries(
        in container: ModelContainer
    ) async throws -> [(window: String, usedPercentage: Double, hasResetsAt: Bool, source: String)] {
        try await MainActor.run {
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<RateLimitSample>())
            return rows.map {
                (window: $0.window, usedPercentage: $0.usedPercentage, hasResetsAt: $0.resetsAt != nil, source: $0.source)
            }
        }
    }

    // MARK: - Persistence on success

    @Test func successPersistsBothWindows() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.success(jsonBody: """
            {"five_hour":{"utilization":40.0,"resets_at":"2026-05-06T17:00:00Z"},
             "seven_day":{"utilization":12.5,"resets_at":"2026-05-13T00:00:00Z"}}
        """)])
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(),
            clock: TestClock()
        )

        let outcome = await poller.runOnce()
        if case .success(let fh, let sd) = outcome {
            #expect(fh == 40.0)
            #expect(sd == 12.5)
        } else {
            Issue.record("expected success outcome, got \(outcome)")
        }

        let rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.count == 2)
        let byWindow = Dictionary(grouping: rows, by: { $0.window })
        #expect(byWindow["five_hour"]?.first?.usedPercentage == 40.0)
        #expect(byWindow["seven_day"]?.first?.usedPercentage == 12.5)
        #expect(rows.allSatisfy { $0.source == "oauth" })
    }

    @Test func successPersistsSingleWindow() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.success(jsonBody: """
            {"five_hour":{"utilization":3,"resets_at":null}}
        """)])
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(),
            clock: TestClock()
        )

        _ = await poller.runOnce()

        let rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.count == 1)
        #expect(rows[0].window == "five_hour")
        #expect(rows[0].hasResetsAt == false)  // null preserved as nil
    }

    // MARK: - Per-lane cooldown + account guard

    /// A 429 cools the lane it hit; with only one lane, the next
    /// (cadence-ignoring) poll has nothing eligible left to spend.
    @Test func rateLimited429CoolsTheLane() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.status(429), .status(429)])
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        let first = await poller.runOnce()
        if case .rateLimited = first {} else { Issue.record("expected rateLimited, got \(first)") }
        // Lane is cooling; no other lane to fall back to.
        #expect(await poller.runOnce() == .credentialsNotFound)
    }

    /// A 401 drops the lane and rejects the token, so rediscovery filters
    /// it out — a single-token user then has no lane at all.
    @Test func unauthorized401DropsTheLaneAndDoesNotRecur() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.status(401), .success(jsonBody: #"{"five_hour":{"utilization":1}}"#)])
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        #expect(await poller.runOnce() == .unauthorized)
        #expect(await poller.runOnce() == .credentialsNotFound)
    }

    /// Two same-account tokens both persist; a token that resolves to a
    /// different org is marked foreign, excluded, and never persisted —
    /// so interleaving can never mix two accounts into one timeline.
    @Test func foreignAccountTokenExcludedAndNotPersisted() async throws {
        let container = try Self.makeContainer()
        let kc = KeychainOAuth(rawReader: { .success(Self.keychainBlob(token: "tokA")) })
        let held = EphemeralCredentialStore(OAuthCredential(
            accessToken: "tokB",
            expiresAt: Date().addingTimeInterval(3600),
            subscriptionType: nil
        ))
        let counter = AtomicCounter()
        let outcomes: [HTTPOutcome] = [
            .success(jsonBody: #"{"five_hour":{"utilization":10}}"#, headers: ["anthropic-organization-id": "orgA"]),
            .success(jsonBody: #"{"five_hour":{"utilization":99}}"#, headers: ["anthropic-organization-id": "orgB"]),
        ]
        let transport: OAuthClient.Transport = { _ in
            try outcomes[min(counter.next(), outcomes.count - 1)].materialize()
        }
        let client = OAuthClient(keychain: kc, transport: transport, desktopEnabled: { false }, heldStore: held)
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        // Lane 0 (keychain, tokA) establishes primary org A and persists.
        let first = await poller.runOnce()
        if case .success = first {} else { Issue.record("expected success, got \(first)") }
        // Lane 1 (held, tokB) resolves to org B → foreign, not persisted.
        #expect(await poller.runOnce() == .foreignAccount)

        let rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.count == 1)                      // only org A's window
        #expect(rows.first?.usedPercentage == 10.0)   // not org B's 99

        let snap = await poller.snapshot()
        #expect(snap.primaryLaneCount == 1)
        #expect(snap.primaryOrg == "orgA")
    }

    // MARK: - Other failure paths

    @Test func transportErrorSurfacesAndCoolsLane() async throws {
        struct StubError: Error {}
        let container = try Self.makeContainer()
        let kc = KeychainOAuth(rawReader: { .success(Self.defaultKeychainBlob()) })
        let client = OAuthClient(keychain: kc, transport: { _ in throw StubError() }, desktopEnabled: { false })
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        let outcome = await poller.runOnce()
        if case .transport = outcome {} else { Issue.record("expected transport, got \(outcome)") }
        // Lane cooled; single-lane user has nothing else to poll.
        #expect(await poller.runOnce() == .credentialsNotFound)
    }

    @Test func credsNotFoundWhenNoToken() async throws {
        let container = try Self.makeContainer()
        let kc = KeychainOAuth(rawReader: { .failure(.notFound) })
        let client = OAuthClient(keychain: kc, transport: { _ in (Data(), HTTPURLResponse()) }, desktopEnabled: { false })
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        #expect(await poller.runOnce() == .credentialsNotFound)
    }

    // MARK: - start() / stop() lifecycle

    @Test func startStopIsIdempotent() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.success(jsonBody: #"{"five_hour":{"utilization":1,"resets_at":""}}"#)])
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        await poller.start()
        await poller.start()  // double-start is no-op
        await poller.stop()
        await poller.stop()   // double-stop is no-op
    }

    @Test func loopExitsCleanlyOnStop() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.success(jsonBody: #"{"five_hour":{"utilization":1,"resets_at":""}}"#)])
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())
        await poller.start()
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms of loop iterations
        await poller.stop()
        // Reaching here without hanging means the task fully unwound.
    }
}

// MARK: - Test scaffolding

/// Yieldable HTTP outcome — a 200 with a JSON body (and optional
/// response headers), or a non-2xx with optional headers and body.
enum HTTPOutcome: Sendable {
    case success(jsonBody: String, headers: [String: String] = [:])
    case status(_ code: Int, body: String = "{}", headers: [String: String] = [:])

    func materialize() throws -> (Data, HTTPURLResponse) {
        switch self {
        case .success(let body, let headers):
            let response = HTTPURLResponse(
                url: OAuthClient.endpoint,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (Data(body.utf8), response)
        case .status(let code, let body, let headers):
            let response = HTTPURLResponse(
                url: OAuthClient.endpoint,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (Data(body.utf8), response)
        }
    }
}

/// Atomic monotonic counter used to walk the outcomes array. Plain
/// `var` capture is rejected by Swift 6 strict concurrency.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Test clock: `now()` advances only via `advance(by:)`; `sleep` is a
/// `Task.yield` so the loop spins quickly. Cancellation is cooperative —
/// a sleep run after `Task.cancel()` throws, matching production.
final class TestClock: PollerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 0)) {
        self.current = start
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
    }
}
