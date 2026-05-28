import Foundation
import Testing
@testable import PacerCore

/// Unit tests for the OAuth client. Both the keychain and the transport
/// are injected, so no Keychain or network access happens here.
@Suite struct OAuthClientTests {

    private static let goodToken = "sk-ant-oat01-fake"

    private func goodKeychain(expiresAt: Date? = Date(timeIntervalSinceNow: 3600)) -> KeychainOAuth {
        let blob: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": Self.goodToken,
                "expiresAt": Int64(expiresAt?.timeIntervalSince1970 ?? 0) * 1000,
                "subscriptionType": "max20x",
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: blob)
        return KeychainOAuth(rawReader: { .success(data) })
    }

    private func client(
        keychain: KeychainOAuth,
        respond: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_750_000_000) }
    ) -> OAuthClient {
        OAuthClient(keychain: keychain, transport: respond, now: now)
    }

    private func http(_ status: Int, body: String = "{}", headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        let url = OAuthClient.endpoint
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(body.utf8), response)
    }

    // MARK: - Happy path

    @Test func parses200WithBothWindows() async {
        let body = #"""
        {
          "five_hour": {"utilization": 42.5, "resets_at": "2026-05-06T17:30:00Z"},
          "seven_day": {"utilization": 12.0, "resets_at": "2026-05-13T00:00:00Z"},
          "extra_usage": {"ignored": true}
        }
        """#
        let c = client(
            keychain: goodKeychain(),
            respond: { _ in self.http(200, body: body) }
        )
        guard case .success(let snap) = await c.fetchUsage() else {
            Issue.record("expected success")
            return
        }
        #expect(snap.fiveHour?.usedPercentage == 42.5)
        #expect(snap.sevenDay?.usedPercentage == 12.0)
        // ISO8601 round-trip
        #expect(snap.fiveHour?.resetsAt != nil)
        #expect(snap.sevenDay?.resetsAt != nil)
    }

    @Test func tolerateMissingWindow() async {
        // Anthropic occasionally omits one window. We surface nil for
        // that window, success overall.
        let body = #"""
        {"five_hour": {"utilization": 10, "resets_at": "2026-05-06T12:00:00Z"}}
        """#
        let c = client(keychain: goodKeychain(), respond: { _ in self.http(200, body: body) })
        guard case .success(let snap) = await c.fetchUsage() else {
            Issue.record("expected success")
            return
        }
        #expect(snap.fiveHour != nil)
        #expect(snap.sevenDay == nil)
    }

    @Test func tolerateNullResetsAt() async {
        let body = #"""
        {"five_hour": {"utilization": 5.5, "resets_at": null}}
        """#
        let c = client(keychain: goodKeychain(), respond: { _ in self.http(200, body: body) })
        guard case .success(let snap) = await c.fetchUsage() else {
            Issue.record("expected success")
            return
        }
        #expect(snap.fiveHour?.usedPercentage == 5.5)
        #expect(snap.fiveHour?.resetsAt == nil)
    }

    @Test func tolerateUtilizationAsInt() async {
        // Defensive: server may return integer if utilization is a round
        // number. JSONDecoder against Codable would fail; we accept it.
        let body = #"{"five_hour":{"utilization":50,"resets_at":""}}"#
        let c = client(keychain: goodKeychain(), respond: { _ in self.http(200, body: body) })
        guard case .success(let snap) = await c.fetchUsage() else {
            Issue.record("expected success")
            return
        }
        #expect(snap.fiveHour?.usedPercentage == 50.0)
        #expect(snap.fiveHour?.resetsAt == nil) // empty string → nil
    }

    @Test func sendsExpectedHeaders() async {
        let captured = Box<URLRequest>()
        let c = client(
            keychain: goodKeychain(),
            respond: { request in
                captured.value = request
                return self.http(200, body: "{}")
            }
        )
        _ = await c.fetchUsage()
        let req = captured.value
        #expect(req?.url == OAuthClient.endpoint)
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.goodToken)")
        #expect(req?.value(forHTTPHeaderField: "anthropic-beta") == OAuthClient.betaHeader)
        #expect(req?.value(forHTTPHeaderField: "User-Agent") == OAuthClient.userAgent)
        #expect(req?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(req?.httpMethod == "GET")
    }

    // MARK: - extra_usage decoding

    @Test func extraUsageAsTopLevelNumber() async {
        let body = #"""
        {
          "five_hour": {"utilization": 1, "resets_at": ""},
          "extra_usage": 250
        }
        """#
        let c = client(keychain: goodKeychain(), respond: { _ in self.http(200, body: body) })
        guard case .success(let snap) = await c.fetchUsage() else {
            Issue.record("expected success"); return
        }
        #expect(snap.extraUsageCents == 250)
    }

    @Test func extraUsageAsObjectWithCents() async {
        let body = #"""
        {
          "five_hour": {"utilization": 1, "resets_at": ""},
          "extra_usage": {"amount_cents": 425}
        }
        """#
        let c = client(keychain: goodKeychain(), respond: { _ in self.http(200, body: body) })
        guard case .success(let snap) = await c.fetchUsage() else {
            Issue.record("expected success"); return
        }
        #expect(snap.extraUsageCents == 425)
    }

    @Test func extraUsageAsObjectWithDollars() async {
        let body = #"""
        {
          "five_hour": {"utilization": 1, "resets_at": ""},
          "extra_usage": {"amount": 2.50}
        }
        """#
        let c = client(keychain: goodKeychain(), respond: { _ in self.http(200, body: body) })
        guard case .success(let snap) = await c.fetchUsage() else {
            Issue.record("expected success"); return
        }
        #expect(snap.extraUsageCents == 250)
    }

    @Test func extraUsageAbsentSurfacesNil() async {
        let body = #"{"five_hour":{"utilization":1,"resets_at":""}}"#
        let c = client(keychain: goodKeychain(), respond: { _ in self.http(200, body: body) })
        guard case .success(let snap) = await c.fetchUsage() else {
            Issue.record("expected success"); return
        }
        #expect(snap.extraUsageCents == nil)
    }

    @Test func extraUsageUnrecognizedShapeSurfacesNil() async {
        let body = #"""
        {
          "five_hour": {"utilization": 1, "resets_at": ""},
          "extra_usage": {"strange_key": "$1.23"}
        }
        """#
        let c = client(keychain: goodKeychain(), respond: { _ in self.http(200, body: body) })
        guard case .success(let snap) = await c.fetchUsage() else {
            Issue.record("expected success"); return
        }
        #expect(snap.extraUsageCents == nil)
    }

    @Test func usesInjectedNowForSampledAt() async {
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let body = #"{"five_hour":{"utilization":1,"resets_at":""}}"#
        let c = client(
            // Token must outlive the injected `now`, otherwise the
            // local-expiry gate trips before the request goes out.
            keychain: goodKeychain(expiresAt: fixed.addingTimeInterval(3600)),
            respond: { _ in self.http(200, body: body) },
            now: { fixed }
        )
        guard case .success(let snap) = await c.fetchUsage() else {
            Issue.record("expected success")
            return
        }
        #expect(snap.sampledAt == fixed)
    }

    // MARK: - Keychain failure pass-through

    @Test func credentialsNotFoundPassesThrough() async {
        let kc = KeychainOAuth(rawReader: { .failure(.notFound) })
        let c = client(keychain: kc, respond: { _ in self.http(200) })
        guard case .failure(.credentialsNotFound) = await c.fetchUsage() else {
            Issue.record("expected credentialsNotFound")
            return
        }
    }

    @Test func accessDeniedPassesThrough() async {
        let kc = KeychainOAuth(rawReader: { .failure(.accessDenied) })
        let c = client(keychain: kc, respond: { _ in self.http(200) })
        guard case .failure(.keychainAccessDenied) = await c.fetchUsage() else {
            Issue.record("expected keychainAccessDenied")
            return
        }
    }

    @Test func malformedKeychainBlob() async {
        let kc = KeychainOAuth(rawReader: { .success(Data("not json".utf8)) })
        let c = client(keychain: kc, respond: { _ in self.http(200) })
        guard case .failure(.keychainMalformed) = await c.fetchUsage() else {
            Issue.record("expected keychainMalformed")
            return
        }
    }

    // MARK: - Local expiry gate

    @Test func tokenOverrideBypassesKeychainAndExpiry() async {
        // Keychain is broken AND the keychain blob's expiresAt is in
        // the past — neither matters when an override is present. The
        // request must go out carrying the override token verbatim.
        let pastExpiry = Date(timeIntervalSince1970: 1_700_000_000)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let brokenKeychain = KeychainOAuth(rawReader: { .failure(.accessDenied) })
        let overrideToken = "sk-ant-oat01-OVERRIDE"
        let observedAuth = Box<String?>(nil)
        let c = OAuthClient(
            keychain: brokenKeychain,
            transport: { req in
                observedAuth.value = req.value(forHTTPHeaderField: "Authorization")
                return self.http(200, body: #"{"five_hour":{"utilization":1,"resets_at":""}}"#)
            },
            now: { now },
            tokenOverride: { overrideToken }
        )
        _ = await c.fetchUsage()
        #expect(observedAuth.value == "Bearer \(overrideToken)")
        // Sanity: also check that a keychain blob with `pastExpiry`
        // wouldn't have routed here if the override path were skipped.
        // (Kept for documentation; the brokenKeychain alone proves it.)
        _ = pastExpiry
    }

    @Test func emptyOverrideFallsThroughToKeychain() async {
        // Whitespace-trimmed empty override = no override → keychain is
        // authoritative. Verifies the closure can return nil/empty and
        // the keychain path takes over.
        let c = OAuthClient(
            keychain: goodKeychain(),
            transport: { _ in self.http(200, body: #"{"five_hour":{"utilization":7,"resets_at":""}}"#) },
            tokenOverride: { nil }
        )
        guard case .success = await c.fetchUsage() else {
            Issue.record("expected success on keychain fallback")
            return
        }
    }

    @Test func skipsExpiredToken() async {
        // expiresAt in the past — we short-circuit before hitting the
        // network.
        let pastExpiry = Date(timeIntervalSince1970: 1_700_000_000)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let transportCalled = Box<Bool>(false)
        let c = client(
            keychain: goodKeychain(expiresAt: pastExpiry),
            respond: { _ in
                transportCalled.value = true
                return self.http(200)
            },
            now: { now }
        )
        guard case .failure(.tokenExpired) = await c.fetchUsage() else {
            Issue.record("expected tokenExpired")
            return
        }
        #expect(transportCalled.value == false, "expected to short-circuit before transport")
    }

    // MARK: - HTTP status branching

    @Test func unauthorizedSurfacesBody() async {
        let c = client(
            keychain: goodKeychain(),
            respond: { _ in self.http(401, body: #"{"error":"invalid_token"}"#) }
        )
        guard case .failure(.unauthorized(let body)) = await c.fetchUsage() else {
            Issue.record("expected unauthorized")
            return
        }
        #expect(body.contains("invalid_token"))
    }

    @Test func rateLimitedParsesRetryAfterSeconds() async {
        let c = client(
            keychain: goodKeychain(),
            respond: { _ in self.http(429, body: "rate limited", headers: ["Retry-After": "120"]) }
        )
        guard case .failure(.rateLimited(let retryAfter)) = await c.fetchUsage() else {
            Issue.record("expected rateLimited")
            return
        }
        #expect(retryAfter == 120)
    }

    @Test func rateLimitedWithNoRetryAfter() async {
        let c = client(
            keychain: goodKeychain(),
            respond: { _ in self.http(429, body: "rate limited") }
        )
        guard case .failure(.rateLimited(let retryAfter)) = await c.fetchUsage() else {
            Issue.record("expected rateLimited")
            return
        }
        #expect(retryAfter == nil)
    }

    @Test func httpErrorOnUnexpectedStatus() async {
        let c = client(
            keychain: goodKeychain(),
            respond: { _ in self.http(500, body: "Internal Server Error") }
        )
        guard case .failure(.http(let status, let body)) = await c.fetchUsage() else {
            Issue.record("expected http()")
            return
        }
        #expect(status == 500)
        #expect(body.contains("Internal Server Error"))
    }

    @Test func transportFailureBubblesUp() async {
        struct StubError: Error {}
        let c = client(keychain: goodKeychain(), respond: { _ in throw StubError() })
        guard case .failure(.transport) = await c.fetchUsage() else {
            Issue.record("expected transport")
            return
        }
    }

    @Test func responseSchemaMismatchOnGarbageBody() async {
        let c = client(
            keychain: goodKeychain(),
            respond: { _ in self.http(200, body: "not json at all") }
        )
        guard case .failure(.responseSchemaMismatch) = await c.fetchUsage() else {
            Issue.record("expected responseSchemaMismatch")
            return
        }
    }

    // MARK: - Retry-After header parser

    @Test func parseRetryAfterUnderstandsSeconds() {
        #expect(parseRetryAfter("120") == 120)
        #expect(parseRetryAfter("0") == 0)
        #expect(parseRetryAfter("  60  ") == 60)
    }

    @Test func parseRetryAfterUnderstandsHTTPDate() {
        // 1 hour from a fixed reference point — direct math is brittle
        // because the parser uses time-since-now. So just verify it
        // produces a positive duration for a clearly-future date.
        let oneYearAhead = "Wed, 21 Oct 2099 07:28:00 GMT"
        let parsed = parseRetryAfter(oneYearAhead)
        #expect(parsed != nil)
        #expect((parsed ?? 0) > 0)
    }

    @Test func parseRetryAfterClampsPastDateToZero() {
        // Past HTTP-date returns 0 (don't retry-with-negative-delay).
        let past = "Wed, 21 Oct 2000 07:28:00 GMT"
        #expect(parseRetryAfter(past) == 0)
    }

    @Test func parseRetryAfterEmptyOrNil() {
        #expect(parseRetryAfter(nil) == nil)
        #expect(parseRetryAfter("") == nil)
        #expect(parseRetryAfter("garbage") == nil)
    }

    // MARK: - Live integration (gated)
    //
    // Set PACER_RUN_LIVE_OAUTH_TEST=1 to actually hit Anthropic's
    // endpoint with the real keychain credential. WILL prompt for
    // keychain access on first run; will count against the user's
    // 5h rate-limit window (one extra request every test invocation).

    @Test func liveOAuthFetch() async throws {
        guard ProcessInfo.processInfo.environment["PACER_RUN_LIVE_OAUTH_TEST"] == "1" else {
            return
        }
        let c = OAuthClient()
        let result = await c.fetchUsage()
        switch result {
        case .success(let snap):
            // At least one window must come back. Other than that we
            // can't assert hard values — the user's actual usage
            // determines them.
            #expect(snap.fiveHour != nil || snap.sevenDay != nil)
        case .failure(.credentialsNotFound):
            Issue.record("no Claude Code credentials in keychain")
        case .failure(.keychainAccessDenied):
            Issue.record("user declined keychain prompt; re-run and approve")
        case .failure(let other):
            Issue.record("unexpected failure: \(other)")
        }
    }
}

/// Minimal lock-protected reference type for capturing values out of
/// `@Sendable` closures in tests. Swift 6 strict concurrency rejects
/// mutating a captured `var` from a Sendable closure even when the
/// access is, in our test setup, single-threaded by construction. A
/// reference-typed lock-protected box is the canonical workaround.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value?
    init(_ value: Value? = nil) { self._value = value }
    var value: Value? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

