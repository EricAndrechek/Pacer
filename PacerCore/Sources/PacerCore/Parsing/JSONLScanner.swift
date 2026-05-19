import Foundation

/// Walks a Claude Code `projects/` directory tree, streams every
/// `*.jsonl` file from a per-file byte-offset cursor, and emits parsed
/// entries with cross-file deduplication applied.
///
/// **Why per-file cursors:** Claude Code writes JSONL line-by-line while
/// a session is active. Without offset tracking, every FSEvents trigger
/// re-parses the whole active file (hundreds of lines, thousands of
/// dedup-set lookups), which would peg the daemon at 100% CPU during
/// any active coding session. Cursors make a "one new line arrived"
/// scan touch ~one line.
///
/// The cursor is `(byteOffset, lastSeenMtime)`. A file is fast-skipped
/// (no open, no read) when both match the live values. Files past
/// their cursor get opened and read from the saved offset to EOF; the
/// new offset persists for the next scan. Truncation (file shorter
/// than cursor.byteOffset) resets the cursor to 0 — a deliberately
/// rare path; JSONL writes are append-only.
public actor JSONLScanner {

    /// One file's resume state. Caller (ScanCoordinator) loads the
    /// known cursors before each scan and persists the updated set
    /// afterwards. Storage lives in the SwiftData store as
    /// `JSONLFileCursor` rows.
    public struct CursorState: Sendable, Equatable {
        public var byteOffset: Int64
        public var lastSeenMtime: Date

        public init(byteOffset: Int64, lastSeenMtime: Date) {
            self.byteOffset = byteOffset
            self.lastSeenMtime = lastSeenMtime
        }
    }

    public struct ScanProgress: Sendable {
        public let filesScanned: Int
        public let filesSkipped: Int
        public let entriesParsed: Int
        public let entriesAccepted: Int
        public let duplicatesDropped: Int
    }

    public struct ScanResult: Sendable {
        public let progress: ScanProgress
        /// Updated cursors for files that were actually opened this
        /// scan. Files that were fast-skipped are NOT in this dict —
        /// their existing cursor is still authoritative.
        public let updatedCursors: [String: CursorState]
    }

    private struct Candidate {
        let url: URL
        let path: String
        let size: Int64
        let mtime: Date
        let cursor: CursorState?
    }

    public init() {}

    /// Scan one or more roots, streaming new `ParsedUsageEntry` values
    /// to the caller. The caller passes in the known cursors and is
    /// responsible for persisting the returned `updatedCursors`.
    ///
    /// `aliases` is the user-defined project-path remap applied at
    /// parse time. The default `[:]` keeps the worktree-stripping
    /// canonicalization but applies no user remaps — fine for tests
    /// and for any caller that hasn't loaded aliases yet.
    public func scan(
        roots: [ClaudePathResolver.ResolvedRoot],
        cursors: [String: CursorState] = [:],
        aliases: [String: String] = [:],
        emit: @Sendable (ParsedUsageEntry) async -> Void
    ) async throws -> ScanResult {
        let candidates = collectCandidates(roots: roots, cursors: cursors)
        // Sort by mtime ascending. Older files first means cross-file
        // dedup is deterministic: when two files share a dedupKey
        // (resumed sessions replay turns into a new file), the older
        // file's instance gets emitted first. Order is cosmetic only —
        // the SamplePersister's DB-backed Set catches subsequent
        // duplicates regardless.
        let sorted = candidates.sorted { $0.mtime < $1.mtime }

        var seen = Set<String>()
        var filesScanned = 0
        var filesSkipped = 0
        var entriesParsed = 0
        var entriesAccepted = 0
        var duplicatesDropped = 0
        var updatedCursors: [String: CursorState] = [:]

        for c in sorted {
            // Fast-skip: nothing changed since last scan.
            if let cur = c.cursor,
               cur.byteOffset == c.size,
               cur.lastSeenMtime == c.mtime {
                filesSkipped += 1
                continue
            }

            // Determine starting offset. Truncation (file smaller than
            // saved cursor) → reset to 0. Otherwise resume from cursor,
            // or 0 for a brand-new file.
            let startOffset: Int64 = {
                if let cur = c.cursor, cur.byteOffset <= c.size {
                    return cur.byteOffset
                }
                return 0
            }()

            filesScanned += 1
            do {
                var bytesConsumed: Int64 = 0
                try await readNewLines(
                    from: c.url,
                    startingAt: startOffset
                ) { lineData in
                    guard let entry = JSONLLineParser.parse(line: lineData, aliases: aliases) else { return }
                    entriesParsed += 1
                    if let key = entry.dedupKey {
                        if !seen.insert(key).inserted {
                            duplicatesDropped += 1
                            return
                        }
                    }
                    entriesAccepted += 1
                    await emit(entry)
                } byteCounter: { delta in
                    bytesConsumed += delta
                }

                // Cursor advances only by complete lines we consumed.
                // A trailing partial write (line started, no newline yet)
                // is left in the file; the next scan picks it up.
                let newOffset = startOffset + bytesConsumed
                updatedCursors[c.path] = CursorState(
                    byteOffset: newOffset,
                    lastSeenMtime: c.mtime
                )
            } catch {
                // Per ccusage: a single unreadable file shouldn't poison
                // the scan. Don't update its cursor — next scan retries.
                Log.write("JSONLScanner", "skipping \(c.url.lastPathComponent): \(error)")
                continue
            }
        }

        return ScanResult(
            progress: ScanProgress(
                filesScanned: filesScanned,
                filesSkipped: filesSkipped,
                entriesParsed: entriesParsed,
                entriesAccepted: entriesAccepted,
                duplicatesDropped: duplicatesDropped
            ),
            updatedCursors: updatedCursors
        )
    }

    // MARK: - Internal

    nonisolated private func collectCandidates(
        roots: [ClaudePathResolver.ResolvedRoot],
        cursors: [String: CursorState]
    ) -> [Candidate] {
        let fm = FileManager.default
        var seenPaths = Set<String>()
        var out: [Candidate] = []
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root.projectsDirectory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else { continue }

            while let next = enumerator.nextObject() as? URL {
                guard next.pathExtension == "jsonl" else { continue }
                guard let values = try? next.resourceValues(forKeys: resourceKeys),
                      values.isRegularFile == true,
                      let mtime = values.contentModificationDate,
                      let size = values.fileSize
                else { continue }

                let standardized = next.standardizedFileURL
                let path = standardized.path
                guard !seenPaths.contains(path) else { continue }
                seenPaths.insert(path)

                out.append(Candidate(
                    url: standardized,
                    path: path,
                    size: Int64(size),
                    mtime: mtime,
                    cursor: cursors[path]
                ))
            }
        }
        return out
    }

    /// Open the file, seek to `offset`, read chunked, deliver each
    /// complete line (data between newlines) to `lineHandler`. Reports
    /// bytes consumed (through and including the trailing `\n`) via
    /// `byteCounter` so the caller can compute the new cursor offset.
    ///
    /// A trailing partial line (bytes after the last `\n`) is NOT
    /// delivered and NOT counted — it stays in the file for the next
    /// scan to pick up. This is critical for live-write correctness:
    /// without it, a half-written line would be parsed as garbage and
    /// then re-parsed (doubled) once it completes.
    ///
    /// Stays actor-isolated (not `nonisolated`) so the handler closures
    /// can mutate actor-local state without tripping Swift 6's
    /// `@Sendable` capture check.
    private func readNewLines(
        from url: URL,
        startingAt offset: Int64,
        lineHandler: (Data) async -> Void,
        byteCounter: (Int64) -> Void
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if offset > 0 {
            try handle.seek(toOffset: UInt64(offset))
        }
        var pending: [UInt8] = []
        let chunkSize = 64 * 1024
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            for byte in chunk {
                if byte == 0x0A {
                    if !pending.isEmpty {
                        await lineHandler(Data(pending))
                    }
                    byteCounter(Int64(pending.count + 1))
                    pending.removeAll(keepingCapacity: true)
                } else {
                    pending.append(byte)
                }
            }
        }
        // Trailing partial line (no terminator) is intentionally left
        // unconsumed.
    }
}
