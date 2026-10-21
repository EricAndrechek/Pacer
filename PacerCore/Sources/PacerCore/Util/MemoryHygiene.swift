import Darwin
import Foundation

/// Writes the process's memory to the log once an hour (#337), so a future
/// regression shows in `Pacer.err.log` rather than only in Activity Monitor.
///
/// A menu-bar app has to stay light. Under memory pressure a bloated Pacer was
/// paged out and its main thread stalled for 60-145 s, and nothing in the log
/// said so: the bloat was only found with `vmmap` on the live process.
public enum MemoryHygiene {

    /// How often the `[Memory]` line is written while the app runs.
    public static let reportInterval: TimeInterval = 60 * 60

    private static let lock = NSLock()
    nonisolated(unsafe) private static var reportTimer: DispatchSourceTimer?

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
