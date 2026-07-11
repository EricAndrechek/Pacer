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
            ExtraUsageSample.self,
            UsageLimitSample.self,
            SessionInfo.self,
            ClaudeCodeMeta.self,
            TokenLaneMeta.self,
            Account.self,
            AccountUsageArchive.self,
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

    /// Sendable account summary for cross-actor assertions.
    struct AccountRow: Sendable { let id: String; let isActive: Bool; let latestFiveHourPct: Double? }

    private static func fetchAccounts(in container: ModelContainer) async throws -> [AccountRow] {
        try await MainActor.run {
            let context = ModelContext(container)
            return try context.fetch(FetchDescriptor<Account>()).map {
                AccountRow(id: $0.id, isActive: $0.isActive, latestFiveHourPct: $0.latestFiveHourPct)
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

    /// Two distinct orgs are BOTH tracked — neither dropped. The active
    /// account (org A) writes the shared timeline; a different-account token
    /// (org B) is a tracked *secondary* whose readings are cached on its
    /// `Account` row but kept out of the active timeline, so interleaving
    /// can never mix two accounts into one history.
    @Test func secondaryAccountTrackedNotDroppedAndTimelineStaysActiveOnly() async throws {
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

        // Lane 0 (keychain, tokA) establishes the active account A and persists.
        let first = await poller.runOnce()
        if case .success = first {} else { Issue.record("expected success, got \(first)") }
        // Lane 1 (held, tokB) resolves to org B → secondary, tracked, no history.
        if case .secondaryAccount = await poller.runOnce() {} else {
            Issue.record("expected secondaryAccount")
        }

        // The shared timeline holds ONLY the active account (org A).
        let rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.count == 1)
        #expect(rows.first?.usedPercentage == 10.0)   // not org B's 99

        // But BOTH accounts exist and org B's reading is cached on its row.
        let accounts = try await Self.fetchAccounts(in: container)
        #expect(accounts.count == 2)
        #expect(accounts.first { $0.id == "orgA" }?.isActive == true)
        let b = accounts.first { $0.id == "orgB" }
        #expect(b?.isActive == false)
        #expect(b?.latestFiveHourPct == 99.0)

        let snap = await poller.snapshot()
        #expect(snap.primaryLaneCount == 1)          // only org A is primary
        #expect(snap.primaryOrg == "orgA")
    }

    /// Switching the active account swaps which timeline the shared tables
    /// hold — org B's usage drives display afterward — and switching back
    /// restores org A's timeline intact (neither is lost).
    @Test func switchingActiveAccountSwapsTimelineWithoutLoss() async throws {
        let container = try Self.makeContainer()
        let kc = KeychainOAuth(rawReader: { .success(Self.keychainBlob(token: "tokA")) })
        let held = EphemeralCredentialStore(OAuthCredential(
            accessToken: "tokB", expiresAt: Date().addingTimeInterval(3600), subscriptionType: nil
        ))
        let counter = AtomicCounter()
        // A poll (orgA 10%), B poll (orgB 99%), then B is active and polled (orgB 77%).
        let outcomes: [HTTPOutcome] = [
            .success(jsonBody: #"{"five_hour":{"utilization":10}}"#, headers: ["anthropic-organization-id": "orgA"]),
            .success(jsonBody: #"{"five_hour":{"utilization":99}}"#, headers: ["anthropic-organization-id": "orgB"]),
            .success(jsonBody: #"{"five_hour":{"utilization":77}}"#, headers: ["anthropic-organization-id": "orgB"]),
        ]
        let transport: OAuthClient.Transport = { _ in
            try outcomes[min(counter.next(), outcomes.count - 1)].materialize()
        }
        let client = OAuthClient(keychain: kc, transport: transport, desktopEnabled: { false }, heldStore: held)
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        _ = await poller.runOnce()   // orgA active, timeline = [A:10]
        _ = await poller.runOnce()   // orgB secondary tracked
        let laneBId = OAuthPoller.laneId("tokB")

        // Switch to org B: A's timeline is archived, B's (empty) restored.
        await poller.setActiveAccount(id: "orgB")
        var rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.isEmpty)                                // A archived out, B has none yet
        #expect(await poller.snapshot().activeAccountKey == "orgB")

        // Poll B now that it's active → it writes the shared timeline.
        if case .success = await poller.testLane(id: laneBId) {} else {
            Issue.record("expected success polling active org B")
        }
        rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.contains { $0.usedPercentage == 77.0 })

        // Switch back to org A: B archived, A restored (its 10% is back).
        await poller.setActiveAccount(id: "orgA")
        rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.contains { $0.usedPercentage == 10.0 })
        #expect(!rows.contains { $0.usedPercentage == 77.0 })   // B's rows aren't in A's timeline
        #expect(await poller.snapshot().activeAccountKey == "orgA")
    }

    /// A single-account user with pre-existing (accountId == nil) history
    /// keeps working after the additive migration: the first poll adopts
    /// those rows as the active account and appends to the same timeline.
    @Test func existingSingleAccountDataStillResolvesAfterMigration() async throws {
        let container = try Self.makeContainer()
        // Seed a legacy row with no accountId, as an existing user would have.
        try await MainActor.run {
            let ctx = ModelContext(container)
            ctx.insert(RateLimitSample(
                sampledAt: Date(timeIntervalSince1970: 1_000),
                window: "five_hour", usedPercentage: 33, resetsAt: nil, source: "oauth"
            ))
            try ctx.save()
        }
        let client = Self.sequencedClient([.success(
            jsonBody: #"{"five_hour":{"utilization":44}}"#,
            headers: ["anthropic-organization-id": "orgA"]
        )])
        let poller = OAuthPoller(client: client, container: container, configuration: .init(), clock: TestClock())

        if case .success = await poller.runOnce() {} else { Issue.record("expected success") }
        let rows = try await Self.fetchSampleSummaries(in: container)
        // Legacy 33% row still present alongside the new 44% row — one
        // continuous timeline, nothing reset or dropped.
        #expect(rows.contains { $0.usedPercentage == 33.0 })
        #expect(rows.contains { $0.usedPercentage == 44.0 })
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
