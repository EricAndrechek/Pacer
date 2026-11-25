import Foundation
import Testing
@testable import PacerCore

@Suite("Feed request headers")
struct FeedRequestHeadersTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    @Test("bucket boundaries")
    func buckets() {
        func b(_ h: Double?) -> String { FeedRequestHeaders.sinceBucket(since: h.map(Self.ago), now: Self.now) }
        #expect(b(nil) == "never")
        #expect(b(0) == "lt1h")
        #expect(b(0.99) == "lt1h")
        #expect(b(1) == "1-6h")
        #expect(b(5.99) == "1-6h")
        #expect(b(6) == "6-12h")
        #expect(b(11.99) == "6-12h")
        #expect(b(12) == "12-24h")
        #expect(b(23.99) == "12-24h")
        #expect(b(24) == "1-7d")
        #expect(b(167.99) == "1-7d")
        #expect(b(168) == "gt7d")
        #expect(b(-5) == "lt1h")
    }

    @Test("manual vs scheduled, version only when given")
    func kinds() {
        let m = FeedRequestHeaders.headers(check: .manual, since: nil, now: Self.now)
        #expect(m["X-Pacer-Check"] == "manual")
        #expect(m["X-Pacer-Since-Last-Check"] == "never")
        #expect(m["X-Pacer-Version"] == nil)
        #expect(m["X-Pacer-Id"] == nil)
        let s = FeedRequestHeaders.headers(check: .scheduled, since: Self.ago(2), now: Self.now, version: "0.9.5")
        #expect(s["X-Pacer-Check"] == "scheduled")
        #expect(s["X-Pacer-Since-Last-Check"] == "1-6h")
        #expect(s["X-Pacer-Version"] == "0.9.5")
    }

    final class Flag: @unchecked Sendable { var on = true }

    @Test("id present iff usage is on, decided on every call")
    func idPerCall() {
        let usage = Flag()
        func h() -> [String: String] {
            FeedRequestHeaders.idHeader(usageAllowed: { usage.on }, isNormalLaunch: { true }, installId: { "abc" })
        }
        #expect(h() == ["X-Pacer-Id": "abc"])
        usage.on = false
        #expect(h().isEmpty)
        usage.on = true
        #expect(h()["X-Pacer-Id"] == "abc")
    }

    @Test("no id outside a normal launch or before one exists")
    func idGuards() {
        #expect(FeedRequestHeaders.idHeader(usageAllowed: { true }, isNormalLaunch: { false }, installId: { "abc" }).isEmpty)
        #expect(FeedRequestHeaders.idHeader(usageAllowed: { true }, isNormalLaunch: { true }, installId: { nil }).isEmpty)
        #expect(FeedRequestHeaders.idHeader(usageAllowed: { true }, isNormalLaunch: { true }, installId: { "" }).isEmpty)
    }

    @Test("the price request carries the provider's headers and nothing else changes")
    func priceRequest() throws {
        let suite = "feed-headers-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let provider = FeedRequestHeaderProvider()
        let usage = Flag()
        provider.setExtra { usage.on ? ["X-Pacer-Id": "abc"] : [:] }

        let first = CuratedPriceHistory.request(now: Self.now, store: store, headers: provider)
        #expect(first.url == CuratedPriceHistory.remoteURL)
        #expect(first.httpMethod == "GET")
        #expect(first.cachePolicy == URLRequest(url: CuratedPriceHistory.remoteURL).cachePolicy)
        #expect(first.timeoutInterval == URLRequest(url: CuratedPriceHistory.remoteURL).timeoutInterval)
        #expect(first.value(forHTTPHeaderField: "X-Pacer-Check") == "scheduled")
        #expect(first.value(forHTTPHeaderField: "X-Pacer-Since-Last-Check") == "never")
        #expect(first.value(forHTTPHeaderField: "X-Pacer-Id") == "abc")

        usage.on = false
        let second = CuratedPriceHistory.request(now: Self.now.addingTimeInterval(3 * 3600), store: store, headers: provider)
        #expect(second.value(forHTTPHeaderField: "X-Pacer-Id") == nil)
        // Tests are not a normal launch, so no fetch time is persisted.
        #expect(second.value(forHTTPHeaderField: "X-Pacer-Since-Last-Check") == "never")
    }

    @Test("the previous fetch time becomes the next request's bucket")
    func sincePersisted() throws {
        let suite = "feed-headers-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let provider = FeedRequestHeaderProvider()
        _ = CuratedPriceHistory.request(now: Self.now, store: store, headers: provider, record: true)
        let next = CuratedPriceHistory.request(now: Self.now.addingTimeInterval(30 * 3600), store: store,
                                               headers: provider, record: true)
        #expect(next.value(forHTTPHeaderField: "X-Pacer-Since-Last-Check") == "1-7d")
    }
}
