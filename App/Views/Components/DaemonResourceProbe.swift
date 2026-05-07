import Foundation

/// Probes external state about the daemon — its current CPU/RSS via
/// `ps`, plus the on-disk SwiftData store size — for the Debug tab's
/// resource panel. Pure-function helpers so the view layer stays
/// declarative and testable.
///
/// Pacer.app is not sandboxed (the App Group + Keychain access design
/// requires Developer ID distribution rather than Mac App Store), so
/// shelling out to `/bin/ps` is allowed. If we ever sandbox, this
/// fails open and the resource panel just shows "—".
enum DaemonResourceProbe {

    struct Snapshot {
        var pid: Int?
        var cpuPercent: Double?    // as reported by ps; ratio of one core (>100% on multi-core saturating loops)
        var rssBytes: Int64?
        var storeSizeBytes: Int64?
        var walSizeBytes: Int64?
        var capturedAt: Date = .init()
    }

    /// Find the running PacerDaemon (if any) and read its CPU/RSS.
    /// Filters by argv[0] containing `PacerDaemon` so a
    /// `Build/Products/Debug/PacerDaemon` (Xcode-launched) and
    /// `/Applications/Pacer.app/.../PacerDaemon` (production-installed)
    /// both match.
    static func capture(storePath: String?, walPath: String?) -> Snapshot {
        var snap = Snapshot()
        if let pid = pidOfDaemon() {
            snap.pid = pid
            if let (cpu, rss) = readPsStats(pid: pid) {
                snap.cpuPercent = cpu
                snap.rssBytes = rss
            }
        }
        if let path = storePath {
            snap.storeSizeBytes = sizeOfFile(at: path)
        }
        if let path = walPath {
            snap.walSizeBytes = sizeOfFile(at: path)
        }
        return snap
    }

    private static func pidOfDaemon() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "PacerDaemon$"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // pgrep can return multiple PIDs separated by newlines; pick
        // the smallest (oldest)? No — pick the first that's actually
        // a PacerDaemon, not a Pacer.app process. We already filtered
        // with $-anchored regex so any of them is a daemon. Take first.
        for line in text.split(separator: "\n") {
            if let pid = Int(line.trimmingCharacters(in: .whitespaces)) {
                return pid
            }
        }
        return nil
    }

    private static func readPsStats(pid: Int) -> (cpu: Double, rss: Int64)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "%cpu=,rss=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ").filter { !$0.isEmpty }
        guard parts.count >= 2,
              let cpu = Double(parts[0]),
              let rssKB = Int64(parts[1])
        else { return nil }
        // ps reports RSS in kilobytes on macOS.
        return (cpu, rssKB * 1024)
    }

    private static func sizeOfFile(at path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.size] as? Int64
    }
}
