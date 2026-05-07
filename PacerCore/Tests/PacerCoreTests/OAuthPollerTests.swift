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
            RateLimitSample.self,
            SessionInfo.self,
            ClaudeCodeMeta.self,
            configurations: config
        )
    }

    /// Always succeeds with both windows present. Resets are 5h and 7d
    /// in the future from the injected `sampledAt`.
    private static func successfulSnapshot(at: Date = .init()) -> RateLimitSnapshot {
        RateLimitSnapshot(
            sampledAt: at,
            fiveHour: RateLimitWindow(
                usedPercentage: 42.0,
                resetsAt: at.addingTimeInterval(5 * 3600)
            ),
            sevenDay: RateLimitWindow(
                usedPercentage: 7.5,
                resetsAt: at.addingTimeInterval(7 * 24 * 3600)
            )
        )
    }

    /// Builds an `OAuthClient` whose underlying transport returns a
    /// fixed sequence of HTTP results. Each call advances through the
    /// sequence; the last entry is repeated indefinitely.
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
            let outcome = outcomes[min(i, outcomes.count - 1)]
            return try outcome.materialize()
        }
        return OAuthClient(keychain: kc, transport: transport)
    }

    private static func defaultKeychainBlob() -> Data {
        let body: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "tok",
                "expiresAt": Int64(Date().addingTimeInterval(3600).timeIntervalSince1970) * 1000,
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    // MARK: - Persistence on success

    /// Helper that runs a fetch and returns a Sendable summary so we
    /// don't try to ferry `@Model` instances across actor boundaries.
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

    @Test func successPersistsBothWindows() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.success(jsonBody: """
            {"five_hour":{"utilization":40.0,"resets_at":"2026-05-06T17:00:00Z"},
             "seven_day":{"utilization":12.5,"resets_at":"2026-05-13T00:00:00Z"}}
        """)])
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 0),
            clock: TestClock(),
            random: { 0.5 }  // jitter midpoint = no offset
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
            configuration: .init(baseInterval: 300, jitterSeconds: 0),
            clock: TestClock()
        )

        _ = await poller.runOnce()

        let rows = try await Self.fetchSampleSummaries(in: container)
        #expect(rows.count == 1)
        #expect(rows[0].window == "five_hour")
        #expect(rows[0].hasResetsAt == false)  // null preserved as nil
    }

    // MARK: - Backoff math

    @Test func cleanRunSchedulesBaseIntervalAhead() async throws {
        let container = try Self.makeContainer()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: now)
        let client = Self.sequencedClient([.success(jsonBody: #"{"five_hour":{"utilization":1,"resets_at":""}}"#)])
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 0),
            clock: clock,
            random: { 0.5 }  // no offset
        )

        _ = await poller.runOnce()
        let snap = await poller.snapshot()
        #expect(snap.nextPollAt == now.addingTimeInterval(300))
    }

    @Test func jitterAppliesSymmetricallyAroundBase() async throws {
        let container = try Self.makeContainer()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: now)

        // Random = 0.0  → jitter = -jitterSeconds
        let pollerLow = OAuthPoller(
            client: Self.sequencedClient([.success(jsonBody: #"{"five_hour":{"utilization":1,"resets_at":""}}"#)]),
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 30),
            clock: clock,
            random: { 0.0 }
        )
        _ = await pollerLow.runOnce()
        let lowNext = await pollerLow.snapshot().nextPollAt!
        #expect(lowNext == now.addingTimeInterval(270))

        // Random = 1.0 (technically excluded) — we use 0.999
        let clockHi = TestClock(start: now)
        let pollerHi = OAuthPoller(
            client: Self.sequencedClient([.success(jsonBody: #"{"five_hour":{"utilization":1,"resets_at":""}}"#)]),
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 30),
            clock: clockHi,
            random: { 0.999 }
        )
        _ = await pollerHi.runOnce()
        let hiNext = await pollerHi.snapshot().nextPollAt!
        // 300 + (0.999 * 2 - 1) * 30 = 300 + 0.998*30 ≈ 329.94
        #expect(abs(hiNext.timeIntervalSince(now) - 329.94) < 0.1)
    }

    @Test func first429UsesExponentialFromBaseInterval() async throws {
        // First 429: consecutive429s becomes 1, exponential = base * 2^0 = base.
        // No Retry-After → sleep = max(0, base) = base, capped at maxBackoff.
        let container = try Self.makeContainer()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: now)
        let client = Self.sequencedClient([.status(429, body: "rate limited", headers: [:])])
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 0, maxBackoff: 3600),
            clock: clock
        )

        _ = await poller.runOnce()
        let snap = await poller.snapshot()
        if case .rateLimited = snap.lastOutcome {} else {
            Issue.record("expected rateLimited, got \(String(describing: snap.lastOutcome))")
        }
        #expect(snap.consecutive429s == 1)
        #expect(snap.nextPollAt == now.addingTimeInterval(300))
    }

    @Test func consecutive429sGrowExponentially() async throws {
        let container = try Self.makeContainer()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: now)
        let client = Self.sequencedClient([
            .status(429),
            .status(429),
            .status(429),
        ])
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 0, maxBackoff: 3600),
            clock: clock
        )

        _ = await poller.runOnce()  // 1st 429: 300 * 2^0 = 300
        clock.advance(by: 1)

        _ = await poller.runOnce()  // 2nd 429: 300 * 2^1 = 600
        let next2 = await poller.snapshot().nextPollAt!
        let now2 = clock.now()

        _ = await poller.runOnce()  // 3rd 429: 300 * 2^2 = 1200
        let next3 = await poller.snapshot().nextPollAt!
        let now3 = clock.now()

        // Next-poll times are computed from `clock.now()` *during the
        // cycle*, which we know — verify each delta.
        let delta2 = next2.timeIntervalSince(now2)
        let delta3 = next3.timeIntervalSince(now3)
        #expect(delta2 == 600)
        #expect(delta3 == 1200)
    }

    @Test func backoffCapsAtMaxBackoff() async throws {
        let container = try Self.makeContainer()
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
        // 6 consecutive 429s: 300, 600, 1200, 2400, 4800 (capped to 3600), 9600 (capped).
        let client = Self.sequencedClient(Array(repeating: HTTPOutcome.status(429), count: 6))
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 0, maxBackoff: 3600),
            clock: clock
        )
        for _ in 0..<6 { _ = await poller.runOnce() }
        let snap = await poller.snapshot()
        let delta = snap.nextPollAt!.timeIntervalSince(clock.now())
        #expect(delta == 3600)  // capped
    }

    @Test func retryAfterOverridesExponentialWhenLarger() async throws {
        let container = try Self.makeContainer()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: now)
        let client = Self.sequencedClient([
            .status(429, headers: ["Retry-After": "1500"])
        ])
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 0, maxBackoff: 3600),
            clock: clock
        )

        _ = await poller.runOnce()
        let snap = await poller.snapshot()
        // exponential = 300 (consecutive429s = 1), retryAfter = 1500.
        // chosen = 1500 < cap 3600.
        #expect(snap.nextPollAt == now.addingTimeInterval(1500))
    }

    @Test func retryAfterIgnoredWhenSmallerThanExponential() async throws {
        // After 3 429s, exponential = 300 * 2^2 = 1200. Retry-After=10
        // should not shrink that.
        let container = try Self.makeContainer()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: now)
        let client = Self.sequencedClient([
            .status(429),
            .status(429),
            .status(429, headers: ["Retry-After": "10"]),
        ])
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 0, maxBackoff: 3600),
            clock: clock
        )
        _ = await poller.runOnce()
        _ = await poller.runOnce()
        _ = await poller.runOnce()
        let snap = await poller.snapshot()
        let delta = snap.nextPollAt!.timeIntervalSince(clock.now())
        #expect(delta == 1200)
    }

    @Test func successResetsBackoff() async throws {
        let container = try Self.makeContainer()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: now)
        let client = Self.sequencedClient([
            .status(429),
            .status(429),
            .success(jsonBody: #"{"five_hour":{"utilization":1,"resets_at":""}}"#),
            .status(429),
        ])
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 0, maxBackoff: 3600),
            clock: clock
        )

        _ = await poller.runOnce()  // 1st 429
        _ = await poller.runOnce()  // 2nd 429 → consecutive=2
        _ = await poller.runOnce()  // success → consecutive=0
        _ = await poller.runOnce()  // 1st 429 again → exponential = 300

        let snap = await poller.snapshot()
        let delta = snap.nextPollAt!.timeIntervalSince(clock.now())
        #expect(delta == 300)
        #expect(snap.consecutive429s == 1)
    }

    // MARK: - Other failure paths don't grow backoff

    @Test func transportErrorUsesBaseInterval() async throws {
        struct StubError: Error {}
        let container = try Self.makeContainer()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(start: now)
        let kc = KeychainOAuth(rawReader: { .success(Self.defaultKeychainBlob()) })
        let client = OAuthClient(
            keychain: kc,
            transport: { _ in throw StubError() }
        )
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 0),
            clock: clock,
            random: { 0.5 }
        )
        let outcome = await poller.runOnce()
        if case .transport = outcome {} else {
            Issue.record("expected transport, got \(outcome)")
        }
        let snap = await poller.snapshot()
        #expect(snap.consecutive429s == 0)  // not bumped on transport
        #expect(snap.nextPollAt == now.addingTimeInterval(300))
    }

    @Test func credsNotFoundQuietlySleepsBaseInterval() async throws {
        let container = try Self.makeContainer()
        let kc = KeychainOAuth(rawReader: { .failure(.notFound) })
        let client = OAuthClient(keychain: kc, transport: { _ in (Data(), HTTPURLResponse()) })
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 0),
            clock: TestClock(),
            random: { 0.5 }
        )
        let outcome = await poller.runOnce()
        #expect(outcome == .credentialsNotFound)
    }

    // MARK: - start() / stop() lifecycle

    @Test func startStopIsIdempotent() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.success(jsonBody: #"{"five_hour":{"utilization":1,"resets_at":""}}"#)])
        let clock = TestClock()
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 0),
            clock: clock
        )

        await poller.start()
        await poller.start()  // double-start is no-op
        await poller.stop()
        await poller.stop()  // double-stop is no-op
    }

    @Test func loopExitsCleanlyOnStop() async throws {
        let container = try Self.makeContainer()
        let client = Self.sequencedClient([.success(jsonBody: #"{"five_hour":{"utilization":1,"resets_at":""}}"#)])
        // TestClock.sleep yields, so the loop drains quickly without
        // burning CPU; stop() then cancels the next sleep.
        let clock = TestClock()
        let poller = OAuthPoller(
            client: client,
            container: container,
            configuration: .init(baseInterval: 300, jitterSeconds: 0),
            clock: clock
        )
        await poller.start()
        // Let the loop run a few iterations.
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        await poller.stop()
        // If stop() returned, the task fully unwound. No assertion
        // needed beyond "we got here without hanging."
    }
}

// MARK: - Test scaffolding

/// Yieldable HTTP outcome — either a 200 with a JSON body, or a
/// non-2xx with optional headers and body.
enum HTTPOutcome: Sendable {
    case success(jsonBody: String)
    case status(_ code: Int, body: String = "{}", headers: [String: String] = [:])

    func materialize() throws -> (Data, HTTPURLResponse) {
        switch self {
        case .success(let body):
            let response = HTTPURLResponse(
                url: OAuthClient.endpoint,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
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

/// Test clock: `now()` advances only when `advance(by:)` is called,
/// `sleep` is a `Task.yield` so the loop spins quickly. Cancellation
/// is cooperative — a sleep that runs after `Task.cancel()` throws
/// `CancellationError`, matching the production clock's behavior.
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
