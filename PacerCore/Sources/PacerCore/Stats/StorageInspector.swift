import Foundation

/// On-disk footprint of the data Pacer touches: its own derived store
/// and logs, plus the raw Claude Code JSONL transcripts it reads from.
/// All sizes are *allocated* bytes (on-disk blocks, what Finder/`du`
/// report) rather than logical length, so the numbers match what a user
/// sees elsewhere.
public struct StorageSnapshot: Sendable, Equatable {
    /// `pacer.sqlite` + its `-wal` / `-shm` sidecars.
    public let pacerDatabaseBytes: Int64
    /// Everything under `~/Library/Logs/Pacer`.
    public let pacerLogsBytes: Int64
    /// Sum of `*.jsonl` under Claude Code's `projects/` dir(s). This is
    /// Claude's data, shown for context — Pacer reads it, never writes
    /// or deletes it.
    public let claudeLogsBytes: Int64
    /// How many `*.jsonl` files that sum covered.
    public let claudeLogFileCount: Int

    /// What Pacer itself is responsible for on disk.
    public var pacerTotalBytes: Int64 { pacerDatabaseBytes + pacerLogsBytes }

    public init(
        pacerDatabaseBytes: Int64,
        pacerLogsBytes: Int64,
        claudeLogsBytes: Int64,
        claudeLogFileCount: Int
    ) {
        self.pacerDatabaseBytes = pacerDatabaseBytes
        self.pacerLogsBytes = pacerLogsBytes
        self.claudeLogsBytes = claudeLogsBytes
        self.claudeLogFileCount = claudeLogFileCount
    }
}

/// Measures the on-disk size of files and directory trees. The size
/// helpers are pure file-system reads (no SwiftData, no app state) so
/// they unit-test against a temp dir; the resolving `snapshot(...)`
/// orchestration takes already-resolved URLs from the caller for the
/// same reason. All of it is synchronous and can walk a large tree
/// (Claude's logs run to gigabytes) — call it off the main actor.
public enum StorageInspector {

    /// Allocated on-disk size of a single file, or 0 if it's missing /
    /// unreadable. Prefers `totalFileAllocatedSize` (includes resource
    /// forks / metadata blocks) and falls back to `fileAllocatedSize`.
    public static func fileAllocatedSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(
            forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        )
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    /// Recursively sum the allocated size of regular files under
    /// `directory` whose URL passes `include`, and count how many
    /// matched. A missing directory yields `(0, 0)`. The `include`
    /// predicate is applied per file so callers can scope to e.g. one
    /// extension without a second walk.
    public static func directoryAllocatedSize(
        _ directory: URL,
        include: (URL) -> Bool = { _ in true }
    ) -> (bytes: Int64, count: Int) {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        var bytes: Int64 = 0
        var count = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, include(url) else { continue }
            bytes += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            count += 1
        }
        return (bytes, count)
    }

    /// Build a full snapshot from already-resolved locations. The caller
    /// owns resolution (`PacerStore.storeURL()`, the logs path, the
    /// Claude roots) so this stays a pure measurement step.
    ///
    /// - Parameters:
    ///   - storeURL: the live `pacer.sqlite`. nil → database reported as
    ///     0 (App Group container unavailable).
    ///   - logsDirectory: `~/Library/Logs/Pacer`.
    ///   - claudeProjectsDirectories: each resolved Claude `projects/`
    ///     dir; their `*.jsonl` are summed across all of them.
    public static func snapshot(
        storeURL: URL?,
        logsDirectory: URL,
        claudeProjectsDirectories: [URL]
    ) -> StorageSnapshot {
        var databaseBytes: Int64 = 0
        if let storeURL {
            // The WAL/SHM sidecars are `pacer.sqlite-wal` / `-shm` —
            // a suffix on the whole filename, not a path extension.
            databaseBytes += fileAllocatedSize(storeURL)
            databaseBytes += fileAllocatedSize(URL(fileURLWithPath: storeURL.path + "-wal"))
            databaseBytes += fileAllocatedSize(URL(fileURLWithPath: storeURL.path + "-shm"))
        }

        let logs = directoryAllocatedSize(logsDirectory)

        var claudeBytes: Int64 = 0
        var claudeCount = 0
        for dir in claudeProjectsDirectories {
            let result = directoryAllocatedSize(dir) { $0.pathExtension == "jsonl" }
            claudeBytes += result.bytes
            claudeCount += result.count
        }

        return StorageSnapshot(
            pacerDatabaseBytes: databaseBytes,
            pacerLogsBytes: logs.bytes,
            claudeLogsBytes: claudeBytes,
            claudeLogFileCount: claudeCount
        )
    }
}
