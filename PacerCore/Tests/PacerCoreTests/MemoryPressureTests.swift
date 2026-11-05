import Foundation
import Synchronization
import Testing
@testable import PacerCore

@Suite("Memory pressure level")
struct MemoryPressureTests {
    @Test func startsNormalAndReportsOnlyChanges() {
        let pressure = MemoryPressure()
        #expect(pressure.level == .normal)
        let seen = Mutex<[MemoryPressure.Level]>([])
        let id = pressure.listen { level in seen.withLock { $0.append(level) } }
        pressure.set(.normal)
        pressure.set(.warning)
        pressure.set(.warning)
        pressure.set(.critical)
        pressure.set(.normal)
        pressure.unlisten(id)
        pressure.set(.warning)
        #expect(seen.withLock { $0 } == [.warning, .critical, .normal])
        #expect(pressure.level == .warning)
    }

    @Test func levelsOrderBySeverity() {
        #expect(MemoryPressure.Level.normal < .warning)
        #expect(MemoryPressure.Level.warning < .critical)
    }

    /// Whatever this machine's state, the sysctl must be readable and map to a
    /// level; a renamed key would silently report normal for ever.
    @Test func theKernelKeyExists() {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        #expect(sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0)
        #expect([1, 2, 4].contains(value))
    }
}
