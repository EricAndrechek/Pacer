import Foundation
import Darwin

/// Reads CPU + RSS for the *current* process via `proc_pidinfo`. We use
/// this from PacerDaemon to write a heartbeat row into the App Group
/// store; the GUI reads that row instead of shelling out to `pgrep`/`ps`,
/// which on macOS Sequoia (15+) trigger the "Pacer.app would like to
/// access data from other apps" TCC prompt because they enumerate
/// other processes.
///
/// `proc_pidinfo(getpid(), ...)` is allowed without any TCC grant —
/// the restriction only applies to inspecting processes you don't own.
public enum SelfResourceProbe {

    public struct Snapshot: Sendable, Equatable {
        public let pid: Int32
        public let rssBytes: Int64
        /// User + system CPU time consumed by this process, in seconds.
        /// Monotonic — callers compute deltas to derive CPU%.
        public let cpuTotalSeconds: Double
        public let timestamp: Date

        public init(pid: Int32, rssBytes: Int64, cpuTotalSeconds: Double, timestamp: Date) {
            self.pid = pid
            self.rssBytes = rssBytes
            self.cpuTotalSeconds = cpuTotalSeconds
            self.timestamp = timestamp
        }
    }

    /// One-shot capture. Returns nil only on a kernel error, which we
    /// have not observed in practice — callers can treat nil as "no
    /// data this tick" and try again.
    public static func capture(now: Date = Date()) -> Snapshot? {
        var info = proc_taskinfo()
        let bufferSize = MemoryLayout<proc_taskinfo>.size
        let bytes = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(getpid(), Int32(PROC_PIDTASKINFO), 0, UnsafeMutableRawPointer(ptr), Int32(bufferSize))
        }
        guard bytes == Int32(bufferSize) else { return nil }
        // pti_total_user/system are nanoseconds.
        let cpuSeconds = Double(info.pti_total_user + info.pti_total_system) / 1_000_000_000
        return Snapshot(
            pid: getpid(),
            rssBytes: Int64(info.pti_resident_size),
            cpuTotalSeconds: cpuSeconds,
            timestamp: now
        )
    }

    /// Compute CPU% (as percent of one core, matching `ps` reporting on
    /// macOS) from two snapshots taken some interval apart. nil if the
    /// interval is non-positive (clock skew, identical timestamps).
    public static func cpuPercent(from previous: Snapshot, to current: Snapshot) -> Double? {
        let dt = current.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0 else { return nil }
        let dCpu = current.cpuTotalSeconds - previous.cpuTotalSeconds
        return (dCpu / dt) * 100
    }
}

/// JSON-encoded summary written by the daemon into `ClaudeCodeMeta`
/// under `ClaudeCodeMetaKey.daemonStats`. The GUI's Debug tab decodes
/// this to render the resource panel without touching subprocess
/// tools (no TCC prompt) and without standing up a dedicated SwiftData
/// model (one rapidly-overwritten row would be a poor fit).
///
/// `cpuPercent` is nil on the first heartbeat (no previous sample to
/// diff against) and on transient errors; treat as "—".
public struct DaemonStats: Codable, Sendable, Equatable {
    public let pid: Int32
    public let rssBytes: Int64
    public let cpuPercent: Double?
    public let timestamp: Date

    public init(pid: Int32, rssBytes: Int64, cpuPercent: Double?, timestamp: Date) {
        self.pid = pid
        self.rssBytes = rssBytes
        self.cpuPercent = cpuPercent
        self.timestamp = timestamp
    }

    /// Encoder/decoder pair shared by daemon writers and GUI readers,
    /// pinned to ISO-8601 dates so the meta row stays human-readable in
    /// the SQLite store.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func encoded() throws -> String {
        let data = try Self.encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(from string: String) -> DaemonStats? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(DaemonStats.self, from: data)
    }
}
