import Foundation
import Synchronization
import Testing
@testable import PacerCore

/// Answers by host, so one session can play "the site is down, GitHub is up".
final class FeedStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable { case body(Data, Int), network(Int) }
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.seen.append(request); let reply = Self.replies[request.url?.host ?? ""]; Self.lock.unlock()
        switch reply {
        case .body(let data, let status):
            let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .network(let code):
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: code))
        case nil:
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))
        }
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FeedStubProtocol.self]
        return URLSession(configuration: c)
    }
}

@Suite("Feed fallbacks", .serialized)
struct FeedFallbackTests {
    static let site = "pacer.andrechek.com"
    static let raw = "raw.githubusercontent.com"

    func fixture(asOf: String) -> Data {
        Data(#"{"schema":1,"asOf":"\#(asOf)","records":[]}"#.utf8)
    }

    func run(site: FeedStubProtocol.Reply, raw: FeedStubProtocol.Reply, asOf: String = "2999-01-01")
        async -> (ok: Bool, hosts: [String], requests: [URLRequest], store: UserDefaults, cache: URL) {
        FeedStubProtocol.lock.withLock {
            FeedStubProtocol.replies = [Self.site: site, Self.raw: raw]; FeedStubProtocol.seen = []
        }
        let suite = "feedfallback.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        let ok = await CuratedPriceHistory.refresh(urlSession: FeedStubProtocol.session(), cacheURL: cache, store: store)
        let seen = FeedStubProtocol.lock.withLock { FeedStubProtocol.seen }
        return (ok, seen.compactMap { $0.url?.host }, seen, store, cache)
    }

    // MARK: price history

    @Test func primaryAnswersAndNothingElseIsAsked() async {
        let r = await run(site: .body(fixture(asOf: "2999-01-01"), 200), raw: .network(-1))
        #expect(r.ok)
        #expect(r.hosts == [Self.site])
        #expect(r.store.object(forKey: FeedFallback.problemKey(.priceHistory)) == nil)
    }

    @Test func notNewerIsNotAFailure() async {
        let r = await run(site: .body(fixture(asOf: "2000-01-01"), 200), raw: .body(fixture(asOf: "2999-01-01"), 200))
        #expect(!r.ok)
        #expect(r.hosts == [Self.site])
    }

    @Test(arguments: [
        FeedStubProtocol.Reply.network(NSURLErrorTimedOut),
        .network(NSURLErrorNotConnectedToInternet),
        .body(Data(), 503),
        .body(Data("<html>captive</html>".utf8), 200),
        .body(Data(#"{"schema":9,"asOf":"2999-01-01","records":[]}"#.utf8), 200),
    ])
    func eachFailureClassFallsBack(primary: FeedStubProtocol.Reply) async {
        let r = await run(site: primary, raw: .body(fixture(asOf: "2999-01-01"), 200))
        #expect(r.ok)
        #expect(r.hosts == [Self.site, Self.raw])
        #expect(r.store.object(forKey: FeedFallback.problemKey(.priceHistory)) is Date)
    }

    @Test func fallbackIsValidatedToo() async {
        let r = await run(site: .body(Data(), 500), raw: .body(Data("nope".utf8), 200))
        #expect(!r.ok)
        #expect(r.hosts == [Self.site, Self.raw])
    }

    @Test func pacerHeadersNeverReachTheFallbackHost() async {
        FeedRequestHeaderProvider.priceHistory.setExtra { ["X-Pacer-Id": "install-123"] }
        defer { FeedRequestHeaderProvider.priceHistory.setExtra { [:] } }
        let r = await run(site: .body(Data(), 500), raw: .body(fixture(asOf: "2999-01-01"), 200))
        let site = r.requests.first { $0.url?.host == Self.site }!
        let raw = r.requests.first { $0.url?.host == Self.raw }!
        #expect(site.value(forHTTPHeaderField: "X-Pacer-Check") == "scheduled")
        #expect(site.value(forHTTPHeaderField: "X-Pacer-Id") == "install-123")
        #expect((raw.allHTTPHeaderFields ?? [:]).keys.allSatisfy { !$0.lowercased().hasPrefix("x-pacer-") })
        #expect(raw.url == FeedFallback.priceHistoryURL)
    }

    // MARK: appcast URL choice

    @Test func appcastChooserWalksPrimaryFallbackPrimary() {
        var c = FeedFallback.AppcastChooser()
        #expect(c.feedURLString == nil && !c.usesFallback)
        #expect(c.finished(failure: nil) == .none)
        #expect(c.feedURLString == nil)

        let f = FeedFallback.Failure(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(c.finished(failure: f) == .none)
        #expect(c.feedURLString == FeedFallback.appcastURL.absoluteString)
        #expect(c.feedURLString == FeedFallback.appcastURL.absoluteString)   // asking twice changes nothing
        #expect(c.usesFallback)

        // The fallback check fails too: reported as failed, and the primary is next anyway.
        #expect(c.finished(failure: f) == .report(primary: f, fallbackOK: false))
        #expect(c.feedURLString == nil)

        #expect(c.finished(failure: f) == .none)
        #expect(c.finished(failure: nil) == .report(primary: f, fallbackOK: true))
        #expect(c.feedURLString == nil)
    }

    @Test func appcastFailureClassification() {
        let a = FeedFallback.appcastFailure
        #expect(a(NSURLErrorDomain, NSURLErrorNotConnectedToInternet, nil, nil)?.code == NSURLErrorNotConnectedToInternet)
        #expect(a(NSURLErrorDomain, NSURLErrorCancelled, nil, nil) == nil)
        #expect(a("SUSparkleErrorDomain", 1001, nil, nil) == nil)               // up to date
        #expect(a("SUSparkleErrorDomain", 2001, NSURLErrorDomain, -1001) == nil) // archive download
        #expect(a("SUSparkleErrorDomain", 1002, NSURLErrorDomain, -1009) == .init(domain: NSURLErrorDomain, code: -1009))
        #expect(a("SUSparkleErrorDomain", 1002, nil, nil) == .init(domain: "SUSparkleErrorDomain", code: 1002))
        #expect(a("SUSparkleErrorDomain", 1000, nil, nil)?.code == 1000)
    }

    // MARK: reporting

    @Test func problemIsRateLimitedPerFeedPerDay() {
        let store = UserDefaults(suiteName: "feedfallback.\(UUID().uuidString)")!
        let f = FeedFallback.Failure(domain: NSURLErrorDomain, code: -1001)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let before = TelemetryCounters.peek()["feed.fallback_used.appcast", default: 0]
        #expect(FeedFallback.report(feed: .appcast, failure: f, fallbackOK: true, now: t0, store: store))
        #expect(!FeedFallback.report(feed: .appcast, failure: f, fallbackOK: true, now: t0 + 23 * 3600, store: store))
        #expect(FeedFallback.report(feed: .priceHistory, failure: f, fallbackOK: true, now: t0 + 3600, store: store))
        #expect(FeedFallback.report(feed: .appcast, failure: f, fallbackOK: false, now: t0 + 24 * 3600, store: store))
        #expect(TelemetryCounters.peek()["feed.fallback_used.appcast", default: 0] - before == 3)
    }

    @Test func attributesAreAllowListed() {
        let a = FeedFallback.problemAttributes(
            feed: .priceHistory, failure: .init(domain: "http", code: 503, httpStatus: 503), fallbackOK: false)
        #expect(a == [
            "feed": .string("price_history"), "error.domain": .string("http"), "error.code": .int(503),
            "http.status": .int(503), "fallback": .string("failed"),
        ])
        let odd = FeedFallback.Failure(domain: "/Users/someone/secret", code: 1)
        #expect(odd.domain == "other")
        #expect(FeedFallback.problemAttributes(feed: .appcast, failure: odd, fallbackOK: true)["http.status"] == nil)
    }
}

@Suite("Update retry policy")
struct UpdateRetryPolicyTests {
    @Test func downloadBackoffIsThirtyMinutesThenTwoHoursThenNormal() {
        #expect(UpdateRetryPolicy.downloadRetryDelay(afterFailures: 1) == 1800)
        #expect(UpdateRetryPolicy.downloadRetryDelay(afterFailures: 2) == 7200)
        #expect(UpdateRetryPolicy.downloadRetryDelay(afterFailures: 3) == nil)
        #expect(UpdateRetryPolicy.downloadRetryDelay(afterFailures: 0) == nil)
    }

    @Test func catchUpOnlyWhenTheBuildChanged() {
        #expect(!UpdateRetryPolicy.needsCatchUpCheck(previousBuild: nil, currentBuild: "5"))
        #expect(!UpdateRetryPolicy.needsCatchUpCheck(previousBuild: "5", currentBuild: "5"))
        #expect(UpdateRetryPolicy.needsCatchUpCheck(previousBuild: "4", currentBuild: "5"))
        #expect(UpdateRetryPolicy.catchUpDelay == 120)
    }

    @Test func downloadProblemIsAllowListedAndRateLimitedWithTheFeeds() {
        let a = FeedFallback.downloadProblemAttributes(domain: "SUSparkleErrorDomain", code: 2001,
                                                       underlyingDomain: NSURLErrorDomain, underlyingCode: -1001)
        #expect(a == ["feed": .string("update_archive"), "error.domain": .string("SUSparkleErrorDomain"),
                      "error.code": .int(2001), "error.underlying_domain": .string(NSURLErrorDomain),
                      "error.underlying_code": .int(-1001)])
        #expect(FeedFallback.downloadProblemAttributes(domain: "weird/path", code: 1, underlyingDomain: nil, underlyingCode: nil)
            == ["feed": .string("update_archive"), "error.domain": .string("other"), "error.code": .int(1)])
        let store = UserDefaults(suiteName: "feedfallback.\(UUID().uuidString)")!
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(FeedFallback.reportDownloadFailure(domain: "x", code: 1, underlyingDomain: nil, underlyingCode: nil, now: t, store: store))
        #expect(!FeedFallback.reportDownloadFailure(domain: "x", code: 1, underlyingDomain: nil, underlyingCode: nil, now: t + 3600, store: store))
    }
}
