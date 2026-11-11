import Testing
@testable import PacerCore

@Suite("MetricKit CPU classifier")
struct MetricKitCPUClassifierTests {
    static let grader = "MXCPUException totalCPUTime:90 sec totalSampledTime:144.765 sec"
    static let busy = "MXCPUException totalCPUTime:300 sec totalSampledTime:100 sec"
    static let mx = "mx_cpu_exception"

    @Test("one core of CPU while the grader runs full is demoted and grouped")
    func demoted() {
        #expect(MetricKitCPUClassifier.decide(
            mechanism: Self.mx, mode: "full", exceptionValue: Self.grader, cores: 10) == .demoteAsArena)
        #expect(MetricKitCPUClassifier.decide(
            mechanism: Self.mx, mode: "multi", exceptionValue: Self.busy, cores: 10) == .demoteAsArena)
        #expect(MetricKitCPUClassifier.fingerprint == ["metrickit-cpu", "arena"])
    }

    @Test("the cheap and paused modes stay as they are")
    func cheapModes() {
        for mode in ["fifth", "paused"] {
            #expect(MetricKitCPUClassifier.decide(
                mechanism: Self.mx, mode: mode, exceptionValue: Self.grader, cores: 10) == .unchanged)
        }
        #expect(MetricKitCPUClassifier.decide(
            mechanism: Self.mx, mode: nil, exceptionValue: Self.grader, cores: 10) == .unchanged)
    }

    @Test("more CPU than the mode allows is not the grader")
    func tooMuchCPU() {
        #expect(MetricKitCPUClassifier.decide(
            mechanism: Self.mx, mode: "full", exceptionValue: Self.busy, cores: 10) == .unchanged)
        #expect(MetricKitCPUClassifier.decide(
            mechanism: Self.mx, mode: "multi", exceptionValue: Self.busy, cores: 2) == .unchanged)
    }

    @Test("a value that does not say how much CPU stays as it is")
    func unparsable() {
        #expect(MetricKitCPUClassifier.decide(
            mechanism: Self.mx, mode: "full", exceptionValue: "something else", cores: 10) == .unchanged)
        #expect(MetricKitCPUClassifier.decide(
            mechanism: Self.mx, mode: "full", exceptionValue: nil, cores: 10) == .unchanged)
    }

    @Test("only CPU exceptions are touched")
    func otherMechanisms() {
        #expect(MetricKitCPUClassifier.decide(
            mechanism: "mx_hang_diagnostic", mode: "full", exceptionValue: Self.grader, cores: 10) == .unchanged)
        #expect(MetricKitCPUClassifier.decide(
            mechanism: nil, mode: "full", exceptionValue: Self.grader, cores: 10) == .unchanged)
    }

    @Test("the average is read from the SDK's exception value")
    func average() throws {
        let value = try #require(MetricKitCPUClassifier.averageCores(exceptionValue: Self.grader))
        #expect(abs(value - 90.0 / 144.765) < 1e-9)
    }
}
