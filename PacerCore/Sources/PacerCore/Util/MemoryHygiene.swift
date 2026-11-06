import Darwin
import Foundation

/// Hands freed heap back after Pacer's heavy passes, and writes the process's
/// memory to the log once an hour so a regression shows in `Pacer.err.log`
/// rather than only in Activity Monitor (#337).
///
/// A menu-bar app has to stay light. Under memory pressure a bloated Pacer was
/// paged out and its main thread stalled for 60-145 s, and nothing in the log
/// said so: the bloat was only found with `vmmap` on the live process.
///
/// **What actually returns the memory is the allocator mode, not a call.**
/// Measured on macOS 27 with the upgrade probe on a real 746k-sample store:
/// after the rebuild the default allocator held 3.3 GB of *empty* small-heap
/// regions, still dirty, and `malloc_zone_pressure_relief` released none of it
/// (it returned 0, here and in an isolated test). With
/// `MallocSpaceEfficient=1` in the environment the same run ended at a 70 MB
/// footprint instead of 4.5 GB, in the same wall time. libmalloc reads that
/// variable once, when the process starts, so the app sets it through
/// `LSEnvironment` in its Info.plist (project.yml) and `allocatorMode` reports
/// whether it took. `relieve()` stays for the configurations where the zones
/// do honour it.
public enum MemoryHygiene {

    /// Least time between two reliefs asked for by recurring work (the HTTP
    /// snapshot), so a quiet steady state doesn't walk the heap every build.
    /// One-off heavy passes (a rebuild, a bulk import) pass no interval.
    public static let recurringReliefInterval: TimeInterval = 10 * 60

    /// How often the `[Memory]` line is written while the app runs.
    public static let reportInterval: TimeInterval = 60 * 60

    private static let lock = NSLock()
    nonisolated(unsafe) private static var reportTimer: DispatchSourceTimer?
    nonisolated(unsafe) private static var lastReliefAt: Date?
    nonisolated(unsafe) private static var pressureReporter: MemoryPressureReporter?

    /// `space-efficient` when libmalloc was started with `MallocSpaceEfficient`
    /// (the app's `LSEnvironment`), `default` otherwise — e.g. a launch that
    /// didn't go through LaunchServices, which is the case to look for if the
    /// `[Memory]` lines grow again.
    public static var allocatorMode: String {
        ProcessInfo.processInfo.environment["MallocSpaceEfficient"].map { $0 != "0" } == true
            ? "space-efficient" : "default"
    }

    /// Ask every malloc zone to return the free pages it holds. Returns false
    /// when skipped because another relief ran within `minimumInterval`.
    ///
    /// It cannot return a page that still holds one live allocation; that
    /// fragmentation is fixed only by not interleaving short-lived bulk
    /// allocations with long-lived ones, which is why the heavy passes page
    /// through the store instead of materializing it.
    @discardableResult
    public static func relieve(minimumInterval: TimeInterval = 0, now: Date = Date()) -> Bool {
        lock.lock()
        if minimumInterval > 0, let last = lastReliefAt,
           now.timeIntervalSince(last) < minimumInterval {
            lock.unlock()
            return false
        }
        lastReliefAt = now
        lock.unlock()
        malloc_zone_pressure_relief(nil, 0)
        return true
    }

    /// Write `[Memory] footprint … peak … malloc live … dirty …` now.
    /// `context` is appended after the numbers, so the line's head stays
    /// fixed for grepping.
    public static func report(_ context: String? = nil) {
        let memory = ProcessMemory.current()
        let load = MachineLoad.current()
        let pressure = MemoryPressure.shared.level
        let line = memory.summary + " · " + detail(memory, load: load, pressure: pressure)
        Log.write("Memory", context.map { "\(line) · \($0)" } ?? line)
        // Launch, hourly and after a rebuild only; never a hot path. The
        // context label is mapped to a fixed set, as the log's is free text.
        let kind = context.map { $0.hasPrefix("launch") ? "launch" : $0.contains("rebuild") ? "after_rebuild" : "other" }
            ?? "hourly"
        var attributes = load.attributes(pressure: pressure)
        attributes["context"] = .string(kind)
        attributes["allocator"] = .string(allocatorMode)
        attributes["peak_mb"] = .int(TelemetryBands.megabytesBucket(bytes: Int64(memory.peakFootprint)))
        attributes["file_mb"] = .int(TelemetryBands.megabytesBucket(bytes: Int64(memory.fileBacked)))
        Telemetry.gauge("memory.footprint_mb", Double(memory.footprint) / 1_000_000, unit: .none,
                        attributes: attributes)
        lock.lock()
        let reporter = pressureReporter
        lock.unlock()
        reporter?.tallyOpenInterval()
    }

    /// What the footprint leaves out: the mapped networks, and how the rest of
    /// the Mac is doing, so a bad hour in the log needs no guess about which.
    private static func detail(_ memory: ProcessMemory, load: MachineLoad, pressure: MemoryPressure.Level) -> String {
        String(format: "resident %d MB file %d MB · pressure %@ · load %.1f/core · compressor %.1f GB · swap %.1f GB",
               ProcessMemory.mb(memory.resident), ProcessMemory.mb(memory.fileBacked), pressure.name,
               load.loadPerCore, Double(load.compressorBytes) / 1e9, Double(load.swapUsedBytes) / 1e9)
    }

    /// Start the hourly `[Memory]` line, once per process; later calls are
    /// no-ops. Its own timer on a utility queue rather than the scan loop's
    /// cadence, so a stuck or idle loop doesn't silence it.
    public static func startHourlyReports() {
        lock.lock()
        defer { lock.unlock() }
        guard reportTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + reportInterval, repeating: reportInterval,
                       leeway: .seconds(60))
        timer.setEventHandler { report() }
        timer.resume()
        reportTimer = timer
        pressureReporter = MemoryPressureReporter(monitor: .shared)
    }

    /// One line and one metric when the Mac's memory pressure changes.
    fileprivate static func reportPressureChange(to level: MemoryPressure.Level, from previous: MemoryPressure.Level) {
        let memory = ProcessMemory.current()
        let load = MachineLoad.current()
        Log.write("Memory", "pressure \(previous.name) → \(level.name) · \(memory.summary) · "
                  + detail(memory, load: load, pressure: level))
        var attributes = load.attributes(pressure: level)
        attributes["from"] = .string(previous.name)
        attributes["footprint_mb"] = .int(TelemetryBands.megabytesBucket(bytes: Int64(memory.footprint)))
        attributes["file_mb"] = .int(TelemetryBands.megabytesBucket(bytes: Int64(memory.fileBacked)))
        Telemetry.count("memory.pressure_change", attributes: attributes)
    }
}

/// The bookkeeping behind pressure telemetry, pure so a test can drive it.
///
/// A loaded Mac's level flips between normal and warning every few minutes (one
/// did 13 times in six hours while its window was open), so a send per change
/// would spend the metric's daily cap on the flapping. Each level sends at most
/// once per `sendInterval`, and the time spent at each is a tally the check-in
/// drains, which is the number that says how bad a day was.
struct MemoryPressureTally: Sendable {
    static let sendInterval: TimeInterval = 15 * 60

    private(set) var level: MemoryPressure.Level
    private var since: Date
    private var seconds: [MemoryPressure.Level: TimeInterval] = [:]
    private var lastSent: [MemoryPressure.Level: Date] = [:]

    init(level: MemoryPressure.Level, at now: Date) {
        self.level = level
        self.since = now
    }

    /// Whole minutes newly spent at a level above normal, leaving the remainder
    /// for next time.
    private mutating func closeInterval(at now: Date) -> [(level: MemoryPressure.Level, minutes: Int)] {
        if level > .normal { seconds[level, default: 0] += max(now.timeIntervalSince(since), 0) }
        since = now
        var out: [(level: MemoryPressure.Level, minutes: Int)] = []
        for (key, value) in seconds {
            let minutes = Int(value / 60)
            guard minutes > 0 else { continue }
            seconds[key] = value - Double(minutes) * 60
            out.append((key, minutes))
        }
        return out
    }

    /// Note a change. Returns the minutes to tally and whether this change is
    /// worth a line and a metric.
    mutating func change(to next: MemoryPressure.Level, at now: Date)
        -> (minutes: [(level: MemoryPressure.Level, minutes: Int)], send: Bool) {
        let minutes = closeInterval(at: now)
        level = next
        let send = lastSent[next].map { now.timeIntervalSince($0) >= Self.sendInterval } ?? true
        if send { lastSent[next] = now }
        return (minutes, send)
    }

    /// The minutes so far at the current level, so a day spent at warning shows
    /// up without waiting for it to end.
    mutating func flush(at now: Date) -> [(level: MemoryPressure.Level, minutes: Int)] { closeInterval(at: now) }
}

/// Listens to `MemoryPressure` for the life of the process.
final class MemoryPressureReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var tally: MemoryPressureTally

    init(monitor: MemoryPressure) {
        tally = MemoryPressureTally(level: monitor.level, at: Date())
        monitor.listen { [weak self] level in self?.levelChanged(to: level) }
    }

    private func levelChanged(to next: MemoryPressure.Level) {
        lock.lock()
        let previous = tally.level
        let change = tally.change(to: next, at: Date())
        lock.unlock()
        Self.add(change.minutes)
        if next > .normal { TelemetryCounters.add("memory.pressure.enter.\(next.name)") }
        if change.send { MemoryHygiene.reportPressureChange(to: next, from: previous) }
    }

    func tallyOpenInterval() {
        lock.lock()
        let minutes = tally.flush(at: Date())
        lock.unlock()
        Self.add(minutes)
    }

    private static func add(_ minutes: [(level: MemoryPressure.Level, minutes: Int)]) {
        for entry in minutes { TelemetryCounters.add("memory.pressure.\(entry.level.name)_minutes", entry.minutes) }
    }
}
