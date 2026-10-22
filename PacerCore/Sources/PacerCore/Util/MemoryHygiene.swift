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
        let line = ProcessMemory.current().summary
        Log.write("Memory", context.map { "\(line) · \($0)" } ?? line)
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
    }
}
