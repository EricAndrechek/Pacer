import Foundation
import Testing
@testable import PacerCore

@Suite("Telemetry core")
struct TelemetryCoreTests {

    @Test("sequential phases lay end to end and skip empty ones")
    func sequential() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let span = Telemetry.Span.sequential(op: "scan.cycle", name: "slow scan", start: t0,
                                             phases: [("prep", 0.1), ("migration", 0), ("scan", 0.5)])
        #expect(span.children.map(\.name) == ["prep", "scan"])
        #expect(span.children[1].start == t0.addingTimeInterval(0.1))
        #expect(span.end == t0.addingTimeInterval(0.6))
    }

    @Test("the daily cap allows N per local day, then resets the next day")
    func dailyCap() throws {
        let store = try #require(UserDefaults(suiteName: "cap-\(UUID().uuidString)"))
        let cap = DailyCap(kind: "hang", limit: 2)
        #expect(cap.take(on: "2026-11-02", store: store))
        #expect(cap.take(on: "2026-11-02", store: store))
        #expect(!cap.take(on: "2026-11-02", store: store))
        #expect(cap.take(on: "2026-11-03", store: store))
    }

    @Test("a DSN parses into the envelope URL and auth header")
    func dsn() throws {
        let dsn = try #require(SentryEnvelope.DSN("https://abc123@o1.ingest.us.sentry.io/42"))
        #expect(dsn.envelopeURL.absoluteString == "https://o1.ingest.us.sentry.io/api/42/envelope/")
        #expect(dsn.authHeader.contains("sentry_key=abc123"))
        #expect(SentryEnvelope.DSN("not a dsn") == nil)
    }

    @Test("a feedback envelope is three JSON lines, scrubbed, with matching event ids")
    func feedback() throws {
        let data = try #require(SentryEnvelope.feedback(
            message: "gate said GO at 99% — /Users/alice/x, me@example.com",
            release: "com.ericandrechek.pacer@0.8.0+1", environment: "production",
            home: "/Users/alice"))
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 3)
        let header = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let item = try #require(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        let body = try #require(try JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [String: Any])
        #expect(item["type"] as? String == "feedback")
        #expect(header["event_id"] as? String == body["event_id"] as? String)
        let message = ((body["contexts"] as? [String: Any])?["feedback"] as? [String: Any])?["message"] as? String
        #expect(message == "gate said GO at 99% — ~/x, <email>")
    }

    @Test("an empty or whitespace message builds nothing")
    func emptyFeedback() {
        #expect(SentryEnvelope.feedback(message: "  \n", release: nil, environment: "x") == nil)
    }
}
