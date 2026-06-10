import Foundation
import Testing
@testable import PacerCore

@Suite("StorageInspector")
struct StorageInspectorTests {

    /// Make a unique temp directory; caller removes it.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    @Test func sumsAndCountsMatchingFilesRecursively() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let sub = root.appendingPathComponent("project-a")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        try write(1000, to: root.appendingPathComponent("a.jsonl"))
        try write(2000, to: sub.appendingPathComponent("b.jsonl"))
        try write(500, to: sub.appendingPathComponent("notes.txt")) // excluded by filter

        let result = StorageInspector.directoryAllocatedSize(root) {
            $0.pathExtension == "jsonl"
        }

        // Two .jsonl files, recursively. Allocated size is block-rounded
        // (≥ logical), so assert the count exactly and the bytes as a
        // lower bound.
        #expect(result.count == 2)
        #expect(result.bytes >= 3000)
    }

    @Test func unfilteredWalkCountsEverything() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(10, to: root.appendingPathComponent("a.jsonl"))
        try write(10, to: root.appendingPathComponent("b.txt"))

        let result = StorageInspector.directoryAllocatedSize(root)
        #expect(result.count == 2)
    }

    @Test func missingDirectoryIsZero() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-does-not-exist-\(UUID().uuidString)")
        let result = StorageInspector.directoryAllocatedSize(missing)
        #expect(result.bytes == 0)
        #expect(result.count == 0)
    }

    @Test func missingFileIsZero() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).sqlite")
        #expect(StorageInspector.fileAllocatedSize(missing) == 0)
    }

    @Test func snapshotSumsDatabaseSidecarsAndClaudeLogs() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Fake store + WAL/SHM sidecars.
        let store = root.appendingPathComponent("pacer.sqlite")
        try write(4000, to: store)
        try write(1000, to: URL(fileURLWithPath: store.path + "-wal"))
        try write(100, to: URL(fileURLWithPath: store.path + "-shm"))

        // Fake logs dir.
        let logs = root.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try write(2000, to: logs.appendingPathComponent("pacer.log"))

        // Fake Claude projects dir with one jsonl + one non-jsonl.
        let claude = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try write(5000, to: claude.appendingPathComponent("session.jsonl"))
        try write(9999, to: claude.appendingPathComponent("ignore.bin"))

        let snap = StorageInspector.snapshot(
            storeURL: store,
            logsDirectory: logs,
            claudeProjectsDirectories: [claude]
        )

        #expect(snap.pacerDatabaseBytes >= 5100)        // store + wal + shm
        #expect(snap.pacerLogsBytes >= 2000)
        #expect(snap.claudeLogsBytes >= 5000)
        #expect(snap.claudeLogFileCount == 1)           // only the .jsonl
        #expect(snap.pacerTotalBytes == snap.pacerDatabaseBytes + snap.pacerLogsBytes)
    }

    @Test func snapshotWithNilStoreReportsZeroDatabase() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let snap = StorageInspector.snapshot(
            storeURL: nil,
            logsDirectory: logs,
            claudeProjectsDirectories: []
        )
        #expect(snap.pacerDatabaseBytes == 0)
        #expect(snap.claudeLogFileCount == 0)
    }
}
