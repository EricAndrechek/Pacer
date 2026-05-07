import Foundation
import PacerCore

/// Resource panel snapshot derived from daemon-written state instead
/// of subprocess inspection. Earlier versions of this file shelled out
/// to `/usr/bin/pgrep` and `/bin/ps`; on macOS Sequoia those calls
/// re-trigger the "Pacer.app would like to access data from other
/// apps" TCC prompt every time, since enumerating other processes
/// requires the App Management permission. Reading the daemon's own
/// JSON-encoded heartbeat row is permission-free and gives the same
/// information sourced authoritatively from the daemon itself.
///
/// The store/WAL file sizes are measured by the GUI directly — those
/// are reads inside the App Group container we already own, no
/// permission needed.
enum DaemonResourceProbe {

    struct Snapshot {
        var pid: Int?
        var cpuPercent: Double?
        var rssBytes: Int64?
        var storeSizeBytes: Int64?
        var walSizeBytes: Int64?
        /// When the daemon last wrote its heartbeat. nil if no row has
        /// ever been written (fresh install before the first daemon
        /// tick) or if the JSON failed to decode.
        var heartbeatAt: Date?
        /// Wall-clock seconds since the heartbeat. Anything beyond ~30s
        /// is treated as "daemon not running" — pid/cpu/rss render as
        /// "—" rather than reporting potentially stale numbers.
        var heartbeatAgeSeconds: Double?
    }

    /// Maximum age of the heartbeat row before we consider the daemon
    /// unresponsive. The daemon writes every 5s under normal load; 30s
    /// gives ample slack for a slow scan cycle without showing values
    /// that are no longer true.
    static let stalenessThreshold: TimeInterval = 30

    /// Build a snapshot from the meta rows the GUI already queries via
    /// `@Query`, plus on-disk file sizes. Pure function so it's safe to
    /// call inside a view's body.
    static func snapshot(metaRows: [ClaudeCodeMeta], storePath: String?, walPath: String?, now: Date = Date()) -> Snapshot {
        var snap = Snapshot()
        if let path = storePath {
            snap.storeSizeBytes = sizeOfFile(at: path)
        }
        if let path = walPath {
            snap.walSizeBytes = sizeOfFile(at: path)
        }
        let json = metaRows.first(where: { $0.key == ClaudeCodeMetaKey.daemonStats })?.value
        guard let json, let stats = DaemonStats.decode(from: json) else {
            return snap
        }
        snap.heartbeatAt = stats.timestamp
        let age = now.timeIntervalSince(stats.timestamp)
        snap.heartbeatAgeSeconds = age
        // Show numbers only if the daemon is still actively writing.
        // Beyond the staleness threshold the "live" fields render as
        // "—" while the heartbeat timestamp itself stays visible so a
        // user troubleshooting a dead daemon sees the last known time.
        if age <= stalenessThreshold {
            snap.pid = Int(stats.pid)
            snap.cpuPercent = stats.cpuPercent
            snap.rssBytes = stats.rssBytes
        }
        return snap
    }

    private static func sizeOfFile(at path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.size] as? Int64
    }
}
