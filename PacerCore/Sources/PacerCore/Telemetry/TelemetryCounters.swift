import Foundation
import Synchronization

/// Counts of things that happen too often to report one by one: clicks, menu
/// opens, tab views, malformed transcript lines skipped, models priced as
/// unknown. Call sites add to an in-memory tally (a lock and a dictionary
/// write, no I/O); the daily check-in drains it and sends the totals.
///
/// **Why not `Telemetry.count` directly**: the scan loop can run twice a
/// second and a click is a click, so per-event metrics would spend the free
/// plan's metric quota on noise and put work on hot paths (AGENTS.md →
/// Performance). A tally costs nothing until the day ends.
///
/// Process-local and lost on quit: a crash or quit drops at most a day of
/// counts, which is fine for "what do people use most".
public enum TelemetryCounters {

    private static let tally = Mutex<[String: Int]>([:])

    /// `key` is our own dotted name (`ui.tab.history`, `data.malformed_line`).
    /// Never put user data in it: keys become metric attributes.
    public static func add(_ key: String, _ n: Int = 1) {
        guard n != 0 else { return }
        tally.withLock { $0[key, default: 0] += n }
    }

    /// The current totals, cleared. For the daily check-in.
    public static func drain() -> [String: Int] {
        tally.withLock { counts in
            defer { counts = [:] }
            return counts
        }
    }

    /// The current totals, not cleared. For diagnostics snapshots.
    public static func peek() -> [String: Int] { tally.withLock { $0 } }
}
