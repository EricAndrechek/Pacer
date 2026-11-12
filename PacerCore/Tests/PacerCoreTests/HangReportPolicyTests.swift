import Testing
@testable import PacerCore

@Suite("Hang report policy", .serialized)
struct HangReportPolicyTests {
    @Test("awake: sent; asleep: not sent")
    func decision() {
        #expect(HangReportPolicy.shouldSend(displaysAsleep: false))
        #expect(!HangReportPolicy.shouldSend(displaysAsleep: true))
    }

    @Test("a held-back hang is counted, a sent one is not")
    func counting() {
        _ = TelemetryCounters.drain()
        #expect(HangReportPolicy.admit(displaysAsleep: false))
        #expect(TelemetryCounters.peek()[HangReportPolicy.asleepCounter] == nil)
        #expect(!HangReportPolicy.admit(displaysAsleep: true))
        #expect(!HangReportPolicy.admit(displaysAsleep: true))
        #expect(TelemetryCounters.drain()[HangReportPolicy.asleepCounter] == 2)
    }

    @Test("state defaults to awake and round-trips")
    func state() {
        DisplaySleepState.set(asleep: true)
        #expect(DisplaySleepState.isAsleep)
        DisplaySleepState.set(asleep: false)
        #expect(!DisplaySleepState.isAsleep)
    }
}
