import Testing
@testable import PacerCore

@Suite("Arena telemetry ids")
struct ArenaTelemetryIdTests {
    @Test("a 40-hex revision is cut to 12 and survives the scrubber")
    func shortened() {
        let id = "amazon/chronos-2@0123456789abcdef0123456789abcdef01234567"
        let out = ArenaWeightStore.telemetryId(id)
        #expect(out == "amazon/chronos-2@0123456789ab")
        #expect(!TelemetryScrubber.scrub(out).contains("<redacted>"))
        #expect(ArenaWeightStore.telemetryId("plain-id") == "plain-id")
    }
}
