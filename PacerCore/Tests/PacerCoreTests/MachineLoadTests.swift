import Foundation
import Testing
@testable import PacerCore

@Suite("What a slow stretch of work was doing (#389)")
struct MachineLoadTests {

    /// The ledger's units are ticks, not nanoseconds, and differ by chip. A
    /// wrong conversion would make every refit look starved or idle by a factor
    /// of 41, so it is pinned against the clock that has no such question.
    @Test func cpuMatchesTheProcessClock() {
        let clockBefore = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let before = ProcessActivity.current()
        var x = 0.0
        let deadline = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) + 150_000_000
        while clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) < deadline { x += x.squareRoot() + 1 }
        let delta = ProcessActivity.current().since(before)
        let clock = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - clockBefore) / 1e9
        #expect(x > 0)
        #expect(delta.cpu > clock * 0.5 && delta.cpu < clock * 2)
    }

    @Test func coreWaitLeavesOutTimeOnACore() {
        #expect(ProcessActivity(cpu: 1.5, runnable: 43.5).coreWait == 42)
        #expect(ProcessActivity(cpu: 2, runnable: 1).coreWait == 0)
    }

    @Test func sinceNeverGoesNegative() {
        let later = ProcessActivity(cpu: 1, runnable: 1, pageins: 1, diskRead: 1)
        let earlier = ProcessActivity(cpu: 2, runnable: 2, pageins: 2, diskRead: 2)
        #expect(later.since(earlier) == ProcessActivity())
    }

    /// The readings these come from are real ones (AGENTS.md: a verdict, not a
    /// photograph): the 68 s refit, a Mac asleep, a refit during a build.
    @Test func verdictNamesTheCause() {
        func verdict(wall: Double, awake: Double, cpu: Double = 0, runnable: Double = 0, pageins: UInt64 = 0,
                     diskRead: UInt64 = 0) -> WorkVerdict {
            .of(wall: wall, awake: awake,
                activity: ProcessActivity(cpu: cpu, runnable: runnable, pageins: pageins, diskRead: diskRead))
        }
        // 2,079 s of wall for 13 s awake.
        #expect(verdict(wall: 2079, awake: 13, cpu: 4.4, runnable: 4.5) == .asleep)
        // 52 s awake, 11 s of CPU, threads queueing for cores.
        #expect(verdict(wall: 52, awake: 52, cpu: 11, runnable: 150) == .starved)
        // The disk at more than 20 MB/s with cores free: mapped pages, or a read.
        let pages = UInt64(40_000_000 * 10 / getpagesize())
        #expect(verdict(wall: 10, awake: 10, cpu: 1, runnable: 1.2, pageins: pages) == .disk)
        #expect(verdict(wall: 1.2, awake: 1.2, cpu: 0.4, runnable: 0.4, diskRead: 115_000_000) == .disk)
        #expect(verdict(wall: 4, awake: 4, cpu: 3.6, runnable: 3.9) == .busy)
        // 68 s with 3 s of CPU, no core queue and no paging to show for it.
        #expect(verdict(wall: 68, awake: 68, cpu: 3.2, runnable: 3.5) == .blocked)
        // A short sleep inside a long refit is not the story.
        #expect(verdict(wall: 60, awake: 59.5, cpu: 50, runnable: 52) == .busy)
    }

    @Test func starvedOutranksDiskBecauseThatIsTheOneToWaitOut() {
        let pages = UInt64(100_000_000 * 8 / getpagesize())
        #expect(WorkVerdict.of(wall: 8, awake: 8, activity: ProcessActivity(cpu: 1, runnable: 40, pageins: pages)) == .starved)
    }

    @Test func loadBandsAreEnumerable() {
        #expect([0.5, 1, 3.9, 4, 100].map(MachineLoad.loadBand) == ["lt1", "1_2", "2_4", "4_8", "gt8"])
    }

    @Test func readsTheLiveMac() {
        let load = MachineLoad.current()
        #expect(load.physicalBytes > 0)
        #expect(load.loadPerCore >= 0)
    }

    /// AGENTS.md → Telemetry: attributes are our own enumerable values, and a
    /// size goes in a band. An exact byte count here would identify a machine.
    @Test func attributesCarryBandsNotExactFigures() {
        let load = MachineLoad(loadPerCore: 3.3, compressorBytes: 7_800_000_000, swapUsedBytes: 0,
                               physicalBytes: 17_179_869_184)
        let a = load.attributes(pressure: .warning, thermal: .fair, lowPower: false)
        #expect(a["pressure"] == .string("warning"))
        #expect(a["thermal"] == .string("fair"))
        #expect(a["load_per_core"] == .string("2_4"))
        #expect(a["compressor_gb"] == .int(8))
        #expect(a["swap_gb"] == .int(0))
        #expect(a["ram_gb"] == .int(16))
    }

    @Test func meterReadsAllThreeClocks() throws {
        let meter = WorkMeter()
        var x = 0.0
        for i in 0..<100_000 { x += Double(i).squareRoot() }
        let reading = meter.finish()
        #expect(x > 0)
        #expect(reading.wall >= 0 && reading.awake >= 0)
        #expect(abs(reading.wall - reading.awake) < 5)
        let a = reading.attributes(pressure: .normal, load: MachineLoad())
        #expect(a["verdict"] != nil)
        #expect(a["cpu_share"] != nil)
        #expect(a["core_wait_share"] != nil)
        #expect(a["pagein_mb"] != nil)
        #expect(a["read_mb"] != nil)
    }
}

@Suite("Memory pressure telemetry (#389)")
struct MemoryPressureTallyTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func everyLevelSendsAtMostOncePerInterval() {
        var tally = MemoryPressureTally(level: .normal, at: start)
        // One Mac flipped this often: the first of each level goes, the rest wait.
        #expect(tally.change(to: .warning, at: start).send)
        #expect(tally.change(to: .normal, at: start.addingTimeInterval(60)).send)
        #expect(!tally.change(to: .warning, at: start.addingTimeInterval(120)).send)
        #expect(!tally.change(to: .normal, at: start.addingTimeInterval(180)).send)
        #expect(tally.change(to: .critical, at: start.addingTimeInterval(240)).send)
        let later = start.addingTimeInterval(MemoryPressureTally.sendInterval + 1)
        #expect(tally.change(to: .warning, at: later).send)
    }

    @Test func minutesCountOnlyTimeAboveNormal() {
        var tally = MemoryPressureTally(level: .normal, at: start)
        #expect(tally.change(to: .warning, at: start.addingTimeInterval(3600)).minutes.isEmpty)
        let left = tally.change(to: .normal, at: start.addingTimeInterval(3600 + 150)).minutes
        #expect(left.count == 1)
        #expect(left.first?.level == .warning)
        #expect(left.first?.minutes == 2)
    }

    /// Thirty seconds at a time adds up rather than rounding away, because a
    /// flapping Mac is exactly the case the number is for.
    @Test func remaindersCarry() {
        var tally = MemoryPressureTally(level: .normal, at: start)
        var at = start
        var total = 0
        for _ in 0..<4 {
            _ = tally.change(to: .warning, at: at)
            at = at.addingTimeInterval(30)
            total += tally.change(to: .normal, at: at).minutes.reduce(0) { $0 + $1.minutes }
            at = at.addingTimeInterval(300)
        }
        #expect(total == 2)
    }

    /// A Mac at warning all day reports before it leaves warning.
    @Test func flushReportsTheOpenInterval() {
        var tally = MemoryPressureTally(level: .warning, at: start)
        #expect(tally.flush(at: start.addingTimeInterval(3600)).first?.minutes == 60)
        #expect(tally.flush(at: start.addingTimeInterval(3630)).isEmpty)
        #expect(tally.flush(at: start.addingTimeInterval(3660)).first?.minutes == 1)
    }
}
