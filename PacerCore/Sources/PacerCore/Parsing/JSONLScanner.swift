import Foundation

/// Walks a Claude Code `projects/` directory tree, streams every
/// `*.jsonl` file line-by-line, and emits parsed entries with cross-file
/// deduplication applied. The scan is filesystem-aware (sorts files by
/// earliest contained timestamp so dedup is deterministic) and memory-
/// safe (uses `URL.lines` async iteration so 10MB+ session transcripts
/// don't load into memory).
public actor JSONLScanner {

    public struct ScanProgress: Sendable {
        public let filesScanned: Int
        public let entriesParsed: Int
        public let entriesAccepted: Int
        public let duplicatesDropped: Int
    }

    private struct FileWithStartTimestamp: Sendable {
        let url: URL
        let firstTimestamp: Date
    }

    /// Scan one or more roots, streaming `ParsedUsageEntry` values to the
    /// caller in chronological order. The caller is responsible for
    /// aggregating, persisting, or further filtering.
    ///
    /// `mtimeAfter`, when non-nil, is a fast-path for "today only" or
    /// incremental scans — files whose mtime is older than the cutoff
    /// are skipped entirely without opening them. This is what makes a
    /// 60-second poll cheap on a 500MB+ history (typical cost ~20 ms
    /// for the active-day fast path on the user's dataset).
    public func scan(
        roots: [ClaudePathResolver.ResolvedRoot],
        mtimeAfter cutoff: Date? = nil,
        emit: @Sendable (ParsedUsageEntry) async -> Void
    ) async throws -> ScanProgress {
        let files = try await collectAndSortFiles(roots: roots, mtimeAfter: cutoff)
        var seen = Set<String>()
        var filesScanned = 0
        var entriesParsed = 0
        var entriesAccepted = 0
        var duplicatesDropped = 0

        for file in files {
            filesScanned += 1
            do {
                for try await line in file.url.lines {
                    guard let entry = JSONLLineParser.parse(line: line) else { continue }
                    entriesParsed += 1
                    if let key = entry.dedupKey {
                        if !seen.insert(key).inserted {
                            duplicatesDropped += 1
                            continue
                        }
                    }
                    entriesAccepted += 1
                    await emit(entry)
                }
            } catch {
                // Per ccusage: a single unreadable file shouldn't poison
                // the scan. Log via stderr in debug builds, continue.
                FileHandle.standardError.write(
                    Data("[JSONLScanner] skipping \(file.url.lastPathComponent): \(error)\n".utf8)
                )
                continue
            }
        }

        return ScanProgress(
            filesScanned: filesScanned,
            entriesParsed: entriesParsed,
            entriesAccepted: entriesAccepted,
            duplicatesDropped: duplicatesDropped
        )
    }

    private func collectAndSortFiles(
        roots: [ClaudePathResolver.ResolvedRoot],
        mtimeAfter cutoff: Date?
    ) async throws -> [FileWithStartTimestamp] {
        let fm = FileManager.default
        var seenPaths = Set<String>()
        var withTimestamps: [FileWithStartTimestamp] = []

        for root in roots {
            let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
            // FileManager.DirectoryEnumerator's iterator is unavailable
            // in async contexts under Swift 6 strict concurrency, so we
            // drain it synchronously into an array first.
            let urls = collectURLs(under: root.projectsDirectory, keys: resourceKeys, fileManager: fm)

            for url in urls {
                guard url.pathExtension == "jsonl" else { continue }
                guard let resourceValues = try? url.resourceValues(forKeys: resourceKeys),
                    resourceValues.isRegularFile == true
                else { continue }

                if let cutoff,
                   let mtime = resourceValues.contentModificationDate,
                   mtime < cutoff {
                    continue
                }

                let standardized = url.standardizedFileURL
                let pathKey = standardized.path
                guard !seenPaths.contains(pathKey) else { continue }
                seenPaths.insert(pathKey)

                // Sort key: timestamp of the first parseable assistant
                // line. ccusage's `sortFilesByTimestamp` does this so
                // dedup is deterministic across resumed-session files.
                // If we can't find a timestamp (e.g. the file has no
                // assistant turns yet), fall back to mtime so the file
                // still participates.
                let earliest = await firstAssistantTimestamp(in: standardized)
                    ?? resourceValues.contentModificationDate
                    ?? Date.distantPast
                withTimestamps.append(.init(url: standardized, firstTimestamp: earliest))
            }
        }

        return withTimestamps.sorted { $0.firstTimestamp < $1.firstTimestamp }
    }

    private func firstAssistantTimestamp(in file: URL) async -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            for try await line in file.lines {
                guard let entry = JSONLLineParser.parse(line: line) else { continue }
                return entry.timestamp
            }
        } catch {
            return nil
        }
        return nil
    }

    public init() {}

    nonisolated private func collectURLs(
        under directory: URL,
        keys: Set<URLResourceKey>,
        fileManager: FileManager
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        while let next = enumerator.nextObject() as? URL {
            urls.append(next)
        }
        return urls
    }
}
