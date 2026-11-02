import Foundation
import Testing
@testable import PacerCore

struct TelemetryOutcomeTests {
    private func outcome(_ e: OAuthClientError) -> String {
        OAuthPoller.telemetryOutcome(.failure(e))
    }

    @Test func pollOutcomesAreSmallEnumerableLabels() {
        let snap = RateLimitSnapshot(sampledAt: Date(), fiveHour: nil, sevenDay: nil)
        #expect(OAuthPoller.telemetryOutcome(.success(snap)) == "ok")
        #expect(outcome(.unauthorized(body: "secret body")) == "401")
        #expect(outcome(.rateLimited(retryAfter: 5)) == "429")
        #expect(outcome(.http(status: 403, body: "")) == "403")
        #expect(outcome(.http(status: 503, body: "")) == "5xx")
        #expect(outcome(.http(status: 418, body: "")) == "http_other")
        #expect(outcome(.transport(underlying: URLError(.notConnectedToInternet))) == "transport")
        #expect(outcome(.credentialsNotFound) == "credentials")
        #expect(outcome(.keychainStatus(-1)) == "credentials")
        #expect(outcome(.responseSchemaMismatch("x")) == "schema_mismatch")
    }

    @Test func malformedLineIsCounted() {
        let before = TelemetryCounters.peek()["data.malformed_line", default: 0]
        _ = JSONLLineParser.parseAll(line: Data("{not json".utf8))
        #expect(TelemetryCounters.peek()["data.malformed_line", default: 0] >= before + 1)
    }
}
