import Foundation
import Testing
@testable import PacerCore

/// Regression tests for the per-file cursor behavior introduced when
/// the daemon was eating 100% CPU because every FSEvent re-parsed
/// active files from byte 0. The invariants below are what we
/// guarantee against re-introducing that bug:
///
///   - A file unchanged since its last scan is fast-skipped (no open).
///   - A file with new bytes appended only emits the appended lines.
///   - Cursors persist across scan calls (caller-managed dictionary).
///   - Truncation (file shrunk below cursor) resets to offset 0.
///   - A trailing partial line (no terminating `\n`) is NOT consumed
///     and gets picked up on the next scan once it completes.

private func writeJSONL(lines: [String], to url: URL, terminating: Bool = true) throws {
    var body = lines.joined(separator: "\n")
    if terminating { body += "\n" }
    try body.write(to: url, atomically: false, encoding: .utf8)
}

private func appendJSONL(lines: [String], to url: URL, terminating: Bool = true) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    var body = lines.joined(separator: "\n")
    if terminating { body += "\n" }
    if let data = body.data(using: .utf8) {
        handle.write(data)
    }
}

private func makeRoot() throws -> (root: URL, projects: URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pacer-cursor-\(UUID().uuidString)")
    let projects = root.appendingPathComponent("projects/-test")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    return (root, projects)
}

private func resolved(root: URL) throws -> [ClaudePathResolver.ResolvedRoot] {
    try ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path]).resolve()
}

private func line(messageId: String, requestId: String, timestamp: String = "2026-04-30T12:00:00.000Z") -> String {
    let dict: [String: Any] = [
        "type": "assistant",
        "timestamp": timestamp,
        "requestId": requestId,
        "message": [
            "id": messageId,
            "model": "claude-opus-4-7",
            "usage": [
                "input_tokens": 1, "output_tokens": 1,
                "cache_read_input_tokens": 0,
                "cache_creation": [
                    "ephemeral_5m_input_tokens": 0,
                    "ephemeral_1h_input_tokens": 0,
                ],
            ],
        ] as [String: Any]
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
}

private actor Collector {
    private(set) var entries: [ParsedUsageEntry] = []
    func add(_ e: ParsedUsageEntry) { entries.append(e) }
    func count() -> Int { entries.count }
    func dedupKeys() -> [String?] { entries.map(\.dedupKey) }
}

@Test func firstScanEstablishesCursors() async throws {
    let (root, projects) = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = projects.appendingPathComponent("session-a.jsonl")
    try writeJSONL(lines: [line(messageId: "m1", requestId: "r1")], to: url)

    let scanner = JSONLScanner()
    let collector = Collector()
    let result = try await scanner.scan(roots: try resolved(root: root)) { entry in
        await collector.add(entry)
    }

    #expect(result.progress.filesScanned == 1)
    #expect(result.progress.filesSkipped == 0)
    #expect(result.progress.entriesAccepted == 1)
    #expect(result.updatedCursors[url.standardizedFileURL.path] != nil)
    let cursor = result.updatedCursors[url.standardizedFileURL.path]!
    #expect(cursor.byteOffset > 0)
}

@Test func unchangedFileIsFastSkipped() async throws {
    let (root, projects) = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = projects.appendingPathComponent("session-a.jsonl")
    try writeJSONL(lines: [line(messageId: "m1", requestId: "r1")], to: url)

    let scanner = JSONLScanner()

    // First scan establishes a cursor.
    let first = try await scanner.scan(roots: try resolved(root: root)) { _ in }
    let cursors = first.updatedCursors

    // Second scan with the cursors → file unchanged → skipped, nothing emitted.
    let collector = Collector()
    let second = try await scanner.scan(roots: try resolved(root: root), cursors: cursors) { entry in
        await collector.add(entry)
    }

    #expect(second.progress.filesScanned == 0)
    #expect(second.progress.filesSkipped == 1)
    #expect(second.progress.entriesAccepted == 0)
    #expect(await collector.count() == 0)
    // Skipped files don't appear in updatedCursors — caller keeps the prior cursor.
    #expect(second.updatedCursors[url.standardizedFileURL.path] == nil)
}

@Test func appendOnlyEmitsNewLines() async throws {
    let (root, projects) = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = projects.appendingPathComponent("session-a.jsonl")
    try writeJSONL(lines: [
        line(messageId: "m1", requestId: "r1"),
        line(messageId: "m2", requestId: "r2"),
    ], to: url)

    let scanner = JSONLScanner()

    // First scan reads both lines.
    var cursors: [String: JSONLScanner.CursorState] = [:]
    let first = try await scanner.scan(roots: try resolved(root: root)) { _ in }
    cursors = first.updatedCursors
    #expect(first.progress.entriesAccepted == 2)

    // Append a third line. mtime advances; size advances.
    // Sleep a fraction so mtime resolution doesn't stick at the same instant.
    try await Task.sleep(nanoseconds: 50_000_000)
    try appendJSONL(lines: [line(messageId: "m3", requestId: "r3")], to: url)

    let collector = Collector()
    let second = try await scanner.scan(roots: try resolved(root: root), cursors: cursors) { entry in
        await collector.add(entry)
    }
    cursors = cursors.merging(second.updatedCursors) { _, new in new }

    #expect(second.progress.filesScanned == 1)
    #expect(second.progress.filesSkipped == 0)
    // Critical assertion: only the appended line is parsed, not all 3.
    #expect(second.progress.entriesAccepted == 1)
    #expect(await collector.dedupKeys() == ["m3:r3"])
}

@Test func partialTrailingLineIsDeferred() async throws {
    let (root, projects) = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = projects.appendingPathComponent("session-a.jsonl")

    // Write a complete first line, then a partial second line (no trailing \n).
    let l1 = line(messageId: "m1", requestId: "r1")
    let l2 = line(messageId: "m2", requestId: "r2")
    let body = l1 + "\n" + String(l2.prefix(l2.count - 5))  // truncated, no \n
    try body.write(to: url, atomically: false, encoding: .utf8)

    let scanner = JSONLScanner()
    let firstCollector = Collector()
    let first = try await scanner.scan(roots: try resolved(root: root)) { entry in
        await firstCollector.add(entry)
    }
    var cursors = first.updatedCursors
    // Only the complete line was emitted.
    #expect(await firstCollector.count() == 1)
    #expect(await firstCollector.dedupKeys() == ["m1:r1"])
    // The cursor sits AT the end of the complete line, not at EOF.
    let cursor1 = cursors[url.standardizedFileURL.path]!
    #expect(cursor1.byteOffset == Int64((l1 + "\n").utf8.count))

    // Now finish the second line (rewrite the file with both complete).
    try await Task.sleep(nanoseconds: 50_000_000)
    try writeJSONL(lines: [l1, l2], to: url)

    let secondCollector = Collector()
    let second = try await scanner.scan(roots: try resolved(root: root), cursors: cursors) { entry in
        await secondCollector.add(entry)
    }
    // Resumed from cursor1, picked up the now-complete line 2 only.
    #expect(await secondCollector.count() == 1)
    #expect(await secondCollector.dedupKeys() == ["m2:r2"])
    cursors = cursors.merging(second.updatedCursors) { _, new in new }
    let cursor2 = cursors[url.standardizedFileURL.path]!
    #expect(cursor2.byteOffset == Int64((l1 + "\n" + l2 + "\n").utf8.count))
}

@Test func truncationResetsCursor() async throws {
    let (root, projects) = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = projects.appendingPathComponent("session-a.jsonl")
    try writeJSONL(lines: [
        line(messageId: "m1", requestId: "r1"),
        line(messageId: "m2", requestId: "r2"),
    ], to: url)

    let scanner = JSONLScanner()
    let first = try await scanner.scan(roots: try resolved(root: root)) { _ in }
    var cursors = first.updatedCursors
    let cursor1 = cursors[url.standardizedFileURL.path]!

    // Truncate: rewrite a shorter file. mtime advances.
    try await Task.sleep(nanoseconds: 50_000_000)
    try writeJSONL(lines: [line(messageId: "m99", requestId: "r99")], to: url)

    let collector = Collector()
    let second = try await scanner.scan(roots: try resolved(root: root), cursors: cursors) { entry in
        await collector.add(entry)
    }
    cursors = cursors.merging(second.updatedCursors) { _, new in new }

    // The new file is shorter than cursor1.byteOffset → reset to 0,
    // re-read from start, emit the single line.
    #expect(second.progress.filesScanned == 1)
    #expect(second.progress.entriesAccepted == 1)
    #expect(await collector.dedupKeys() == ["m99:r99"])
    let cursor2 = cursors[url.standardizedFileURL.path]!
    #expect(cursor2.byteOffset < cursor1.byteOffset)
}

@Test func newFileWithoutCursorReadsFromStart() async throws {
    let (root, projects) = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url1 = projects.appendingPathComponent("session-a.jsonl")
    try writeJSONL(lines: [line(messageId: "a1", requestId: "ra1")], to: url1)

    let scanner = JSONLScanner()
    let first = try await scanner.scan(roots: try resolved(root: root)) { _ in }
    var cursors = first.updatedCursors

    // Wait so mtime resolution captures the new file as newer than url1.
    try await Task.sleep(nanoseconds: 50_000_000)

    // A second file appears between scans — no cursor for it.
    let url2 = projects.appendingPathComponent("session-b.jsonl")
    try writeJSONL(lines: [line(messageId: "b1", requestId: "rb1")], to: url2)

    let collector = Collector()
    let second = try await scanner.scan(roots: try resolved(root: root), cursors: cursors) { entry in
        await collector.add(entry)
    }
    cursors = cursors.merging(second.updatedCursors) { _, new in new }

    // url1 unchanged → skipped. url2 fresh → read from offset 0.
    #expect(second.progress.filesScanned == 1)
    #expect(second.progress.filesSkipped == 1)
    #expect(await collector.dedupKeys() == ["b1:rb1"])
}
