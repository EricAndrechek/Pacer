import Darwin
import Foundation

/// What this process has used so far, from the kernel's own ledger (#389).
///
/// A slow piece of background work has several unrelated explanations, and wall
/// time cannot tell them apart. A production Mac showed a 68 s refit that used
/// 3 s of CPU, and all anyone could say was that the engine got slow. Against this
/// ledger the same shape on another Mac was threads ready to run with no core to
/// run on, 42 s of them in 8 s: not slow code and not memory, just a loaded machine
/// putting utility-priority work last. These counters separate those cases.
///
/// One `proc_pid_rusage` call, about a microsecond: no task port, no VM walk.
public struct ProcessActivity: Sendable, Equatable {
    /// User plus system CPU time.
    public var cpu: TimeInterval
    /// Time its threads spent ready to run, on a core or not, summed over them.
    public var runnable: TimeInterval
    /// Pages brought in from disk: mapped files (the forecast networks) and swap.
    public var pageins: UInt64
    /// Bytes read from disk, those pages included.
    public var diskRead: UInt64

    public init(cpu: TimeInterval = 0, runnable: TimeInterval = 0, pageins: UInt64 = 0, diskRead: UInt64 = 0) {
        self.cpu = cpu; self.runnable = runnable; self.pageins = pageins; self.diskRead = diskRead
    }

    /// Thread-seconds spent ready to run with no core free. `runnable` includes
    /// the time actually on a core, so this is what is left over.
    public var coreWait: TimeInterval { max(runnable - cpu, 0) }

    public var pageinBytes: UInt64 { pageins &* UInt64(getpagesize()) }

    /// The ledger's clock ticks in `mach_absolute_time` units, not nanoseconds
    /// (they differ on Apple silicon).
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(max(info.denom, 1)) / 1_000_000_000
    }()

    /// Zeroes if the kernel will not say, which reads as "nothing to report".
    public static func current() -> ProcessActivity {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        } == 0
        guard ok else { return ProcessActivity() }
        let tick = secondsPerTick
        return ProcessActivity(cpu: Double(info.ri_user_time &+ info.ri_system_time) * tick,
                               runnable: Double(info.ri_runnable_time) * tick,
                               pageins: info.ri_pageins, diskRead: info.ri_diskio_bytesread)
    }

    /// What happened between `earlier` and this reading.
    public func since(_ earlier: ProcessActivity) -> ProcessActivity {
        ProcessActivity(cpu: max(cpu - earlier.cpu, 0), runnable: max(runnable - earlier.runnable, 0),
                        pageins: pageins &- min(pageins, earlier.pageins),
                        diskRead: diskRead &- min(diskRead, earlier.diskRead))
    }
}

/// How hard the whole Mac is working: read when something is worth explaining,
/// never on a hot path (a `sysctl` and two host calls).
public struct MachineLoad: Sendable, Equatable {
    /// One-minute load average over the core count: above 1, threads queue.
    public var loadPerCore: Double
    /// Physical memory the compressor occupies. macOS keeps free memory low on
    /// purpose, so this says more than "free": a third of RAM here means the
    /// Mac wants far more than it has.
    public var compressorBytes: UInt64
    public var swapUsedBytes: UInt64
    public var physicalBytes: UInt64

    public init(loadPerCore: Double = 0, compressorBytes: UInt64 = 0, swapUsedBytes: UInt64 = 0, physicalBytes: UInt64 = 0) {
        self.loadPerCore = loadPerCore; self.compressorBytes = compressorBytes
        self.swapUsedBytes = swapUsedBytes; self.physicalBytes = physicalBytes
    }

    public static func current() -> MachineLoad {
        var load = MachineLoad(physicalBytes: ProcessInfo.processInfo.physicalMemory)
        var averages = [Double](repeating: 0, count: 1)
        if getloadavg(&averages, 1) == 1 {
            load.loadPerCore = averages[0] / Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        }
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            load.compressorBytes = UInt64(stats.compressor_page_count) &* UInt64(getpagesize())
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            load.swapUsedBytes = swap.xsu_used
        }
        return load
    }

    /// Taken once: every `mach_host_self()` adds a port reference nothing drops.
    private static let hostPort = mach_host_self()

    /// `lt1` when no thread has to queue, up to `gt8`: enumerable, and all a
    /// dashboard needs to see that a Mac was busy.
    public static func loadBand(_ loadPerCore: Double) -> String {
        switch loadPerCore {
        case ..<1: return "lt1"
        case ..<2: return "1_2"
        case ..<4: return "2_4"
        case ..<8: return "4_8"
        default: return "gt8"
        }
    }
}

/// Why a stretch of background work took as long as it did.
public enum WorkVerdict: String, Sendable, CaseIterable {
    /// The Mac slept through most of it. Not slow at all.
    case asleep
    /// Threads ready to run, no core free: the Mac has other work it ranks above ours.
    case starved
    /// Waiting on the disk: file reads, mapped pages or swap, at a rate it notices.
    case disk
    /// Using the CPU it was given: the work itself is that big.
    case busy
    /// None of those: a lock, a store write, or waiting on another context.
    case blocked

    /// The dominant cause, in the order that decides what to do about it.
    /// `activity` is process-wide, so concurrent work shares it: this names what
    /// the process was going through, which is the question a slow refit raises.
    public static func of(wall: TimeInterval, awake: TimeInterval, activity: ProcessActivity) -> WorkVerdict {
        if wall - awake > max(1, wall / 2) { return .asleep }
        let span = max(awake, 0.001)
        if activity.coreWait >= span / 3 { return .starved }
        if Double(max(activity.diskRead, activity.pageinBytes)) / span >= 20_000_000 { return .disk }
        if activity.cpu >= span * 2 / 3 { return .busy }
        return .blocked
    }
}

/// Times a stretch of work on three clocks at once: the wall, the awake clock
/// (stops while the Mac sleeps) and the process's ledger.
public struct WorkMeter: Sendable {
    private let wallStart = Date()
    private let awakeStart = SuspendingClock.now
    private let activityStart = ProcessActivity.current()

    public init() {}

    public struct Reading: Sendable {
        public let wall: TimeInterval
        public let awake: TimeInterval
        public let activity: ProcessActivity

        public var verdict: WorkVerdict { .of(wall: wall, awake: awake, activity: activity) }
        public var awakeMilliseconds: Int { Int(awake * 1000) }

        /// What a slow stretch of work sends, in bands: enumerable values, no
        /// exact figures about the Mac (AGENTS.md → Telemetry). Reads the
        /// machine's load, so it is for work already known to be slow.
        public func attributes(pressure: MemoryPressure.Level = MemoryPressure.shared.level,
                               load: MachineLoad = .current()) -> Telemetry.Attributes {
            let span = max(awake, 0.001)
            var a = load.attributes(pressure: pressure)
            a["verdict"] = .string(verdict.rawValue)
            a["cpu_share"] = .int(TelemetryBands.percentBand(activity.cpu / span * 100))
            a["core_wait_share"] = .int(TelemetryBands.percentBand(activity.coreWait / span * 100))
            a["pagein_mb"] = .int(TelemetryBands.megabytesBucket(bytes: Int64(activity.pageinBytes)))
            a["read_mb"] = .int(TelemetryBands.megabytesBucket(bytes: Int64(activity.diskRead)))
            return a
        }

        /// For a log line: `starved cpu 3.2s coreWait 42.1s pagein 12MB`.
        public var summary: String {
            String(format: "%@ cpu %.1fs coreWait %.1fs pagein %dMB", verdict.rawValue, activity.cpu, activity.coreWait,
                   Int(activity.pageinBytes / 1_000_000))
        }
    }

    public func finish() -> Reading {
        let awake = awakeStart.duration(to: .now)
        return Reading(wall: Date().timeIntervalSince(wallStart),
                       awake: Double(awake.components.seconds) + Double(awake.components.attoseconds) * 1e-18,
                       activity: ProcessActivity.current().since(activityStart))
    }
}

extension MachineLoad {
    /// The Mac's state as telemetry attributes: the same set on the hourly
    /// footprint, a pressure change and a slow refit, so they read together.
    public func attributes(pressure: MemoryPressure.Level = MemoryPressure.shared.level,
                           thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
                           lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled) -> Telemetry.Attributes {
        ["pressure": .string(pressure.name),
         "thermal": .string(thermal.telemetryName),
         "low_power": .bool(lowPower),
         "load_per_core": .string(Self.loadBand(loadPerCore)),
         "compressor_gb": .int(TelemetryBands.gigabytesBucket(bytes: Int64(compressorBytes))),
         "swap_gb": .int(TelemetryBands.gigabytesBucket(bytes: Int64(swapUsedBytes))),
         "ram_gb": .int(TelemetryBands.gigabytesBucket(bytes: Int64(physicalBytes)))]
    }
}

extension ProcessInfo.ThermalState {
    public var telemetryName: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
