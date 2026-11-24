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

@Suite("Hang Mac state")
struct HangMacStateTests {
    private let load = MachineLoad(loadPerCore: 3, compressorBytes: 0, swapUsedBytes: 0, physicalBytes: 16 << 30)

    @Test("tags are strings prefixed mac., plus displays and verdict")
    func tags() {
        let tags = HangMacState.tags(load: load, pressure: .warning, displaysAsleep: false, verdict: .starved,
                                     thermal: .nominal, lowPower: false)
        #expect(tags["mac.load_per_core"] == "2_4")
        #expect(tags["mac.pressure"] == "warning")
        #expect(tags["mac.low_power"] == "false")
        #expect(tags["mac.ram_gb"] != nil)
        #expect(tags["hang.displays"] == "awake")
        #expect(tags["hang.verdict"] == "starved")
    }

    @Test("no verdict, no tag; asleep displays")
    func noVerdict() {
        let tags = HangMacState.tags(load: load, pressure: .normal, displaysAsleep: true, thermal: .nominal, lowPower: false)
        #expect(tags["hang.verdict"] == nil)
        #expect(tags["hang.displays"] == "asleep")
    }

    @Test("log suffix")
    func suffix() {
        #expect(HangMacState.logSuffix(load: load, pressure: .warning, displaysAsleep: false, verdict: .starved)
                == " · load 2_4 · pressure warning · verdict starved · displays awake")
    }
}
