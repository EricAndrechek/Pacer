import Foundation
import PacerCore

/// Bulk-reads Claude Code transcripts with DuckDB and hands back the same
/// `ParsedUsageEntry` values the Swift line parser produces.
///
/// **Why this exists.** A first launch has to chew through the user's entire
/// history, and measured on a real 1,697-file corpus that is ~50 s of which
/// **70% is JSON parsing** — a new user watching Pacer apparently hang. DuckDB
/// reads the same corpus in ~2.4 s. So the parse moves; nothing downstream
/// does. The entries flow into the ordinary `SamplePersister`, which keeps
/// dedup, canonicalization, cost mode, and every rollup on exactly one code
/// path, so a bulk import and a live scan cannot disagree about what a row
/// means.
///
/// **What it deliberately does not do.** It is not a replacement for the live
/// scan. The scanner is FSEvents-hinted with per-file byte cursors and touches
/// only changed bytes (33-80 ms a cycle, ~0% idle CPU); DuckDB has no
/// incremental cursor and re-reads whole files. This is for the cold path —
/// first launch, and re-deriving history when a parsing rule changes.
struct ArchiveImporter: BulkTranscriptImporter {

    enum ImportError: Error {
        case openFailed
        case queryFailed(String)
    }

    /// Worker threads the import may use. DuckDB's default is one per core,
    /// and uncapped the import was the heaviest thing Pacer ever does: on a
    /// real 13 GB transcript tree the process peaked at 10.7 GB footprint,
    /// on a user's first launch of a new build, while they work. Two threads
    /// keep it near two cores; the whole upgrade is minutes either way, and
    /// a menu-bar app that spins the fans is the worse trade (#326).
    static let threads = 2
    /// What DuckDB's buffer manager may hold before it spills to
    /// `temp_directory` (its default is 80% of physical memory).
    ///
    /// Sized from measurement, not wished smaller. On that tree the query
    /// needs ~0.9 GB at two threads — it fails at 768 MB and passes at 1 GB —
    /// almost all of it parsing, which can't spill. A cap below that is
    /// worse than none: the import fails within a second and the upgrade
    /// falls back to the line parser, minutes slower. 512 MB, the first
    /// figure tried, did exactly that. This leaves headroom for histories
    /// with larger lines.
    static let memoryLimit = "1536MB"

    /// An in-memory database, capped (see `threads`, `memoryLimit`). The
    /// import is a pure parse — nothing is persisted here, the archive is a
    /// separate concern — but an in-memory database cannot spill without a
    /// `temp_directory`, and one that cannot spill fails at the cap instead
    /// of slowing down. The caller removes `spill` afterwards.
    static func openDatabase(spillingTo spill: URL) throws -> duckdb_database? {
        var config: duckdb_config?
        guard duckdb_create_config(&config) == DuckDBSuccess else { throw ImportError.openFailed }
        defer { duckdb_destroy_config(&config) }
        let settings = [
            ("threads", String(threads)),
            ("memory_limit", memoryLimit),
            ("temp_directory", spill.path),
        ]
        for (name, value) in settings {
            let set = name.withCString { n in value.withCString { v in duckdb_set_config(config, n, v) } }
            guard set == DuckDBSuccess else { throw ImportError.queryFailed("config \(name)=\(value)") }
        }
        var db: duckdb_database?
        var message: UnsafeMutablePointer<CChar>?
        guard duckdb_open_ext(nil, &db, config, &message) == DuckDBSuccess else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            duckdb_free(message)
            throw ImportError.queryFailed("open: \(detail)")
        }
        return db
    }

    /// The extraction, mirroring `JSONLLineParser` rule for rule.
    ///
    /// Reads lines as raw JSON objects rather than letting DuckDB infer a
    /// schema — 1,697 files written by many Claude Code versions do not share
    /// one, and an inferred union would both cost memory and silently change
    /// shape as the user's history grows.
    ///
    /// Dedup happens here, in SQL, rather than downstream. That is a
    /// deliberate exception to "one implementation, not two", and it is worth
    /// it: handing the persister every copy meant 149,395 inserts and 17,786
    /// fetch-and-upgrade round-trips instead of 54,046 clean inserts, and the
    /// persist phase dominated the import. The rule is small enough to state
    /// exactly once in each language — `ParsedUsageEntry.isKept` and the
    /// ORDER BY below — and `IngestParityTests` pins them together on every
    /// row the two paths leave, not only on the six token totals.
    ///
    /// The ordering is `ParsedUsageEntry.isKept`, the rule the line scanner
    /// keeps a copy by, written as SQL: the *finished* message first
    /// (`stop_reason` present — Claude Code appends the same turn several
    /// times while streaming and only the last copy carries the real
    /// `output_tokens`), then the largest output, then the earliest instant,
    /// then the file path. Rows with no dedup key fall through untouched,
    /// exactly as the Swift path leaves them. The rows still pass through
    /// `CopySelection` on the way out, which keeps one per key whatever this
    /// returns; it is what ranks multi-call responses (below).
    ///
    /// `projectsDirectories` are the roots' `projects/` folders, read the way
    /// the line scanner walks them: every `*.jsonl` beneath, except under a
    /// hidden name. DuckDB's glob, unlike `FileManager`'s `.skipsHiddenFiles`,
    /// matches dot-files and descends into dot-directories, so without the
    /// filter a transcript there would be read by one path and not the other.
    static func extractionSQL(projectsDirectories: [String]) -> String {
        func quoted(_ s: String) -> String { "'\(s.replacingOccurrences(of: "'", with: "''"))'" }
        let sources = projectsDirectories.map { quoted($0 + "/**/*.jsonl") }.joined(separator: ", ")
        // The part of each file's path below its root, from its leading
        // slash, for the hidden-name test: the roots themselves live under
        // `~/.claude`. `replace` rather than `substr`, which counts characters
        // where Swift would count bytes.
        let relative = projectsDirectories.isEmpty ? "fname" : "CASE "
            + projectsDirectories.map {
                "WHEN starts_with(fname, \(quoted($0 + "/"))) THEN replace(fname, \(quoted($0 + "/")), '/')"
            }.joined(separator: " ") + " ELSE fname END"
        return """
        WITH lines AS (
            SELECT json AS j, filename AS fname FROM read_ndjson_objects([\(sources)],
                ignore_errors = true, maximum_object_size = 67108864, filename = true)
            -- Before any parsing: an assistant line's `type` is the string
            -- "assistant", so a line without those bytes can't be one. Four
            -- fifths of the bytes are user lines (tool results, up to MBs),
            -- and parsing them only to discard them was most of the work.
            WHERE contains(json, '"assistant"')
              AND NOT contains(\(relative), '/.')
        ),
        -- Each line parsed twice, not once per field. DuckDB parses the
        -- document again for every `json_extract`, and with ~22 per line the
        -- query needed a 2 GB memory limit at two threads (1 GB with this).
        -- The list forms return exactly what the single-path calls did,
        -- field by field.
        parsed AS (
            SELECT
                json_extract_string(j, ['$.type', '$.timestamp', '$.message.model', '$.message.id',
                                        '$.requestId', '$.sessionId', '$.cwd', '$.version',
                                        '$.message.stop_reason', '$.entrypoint',
                                        '$.message.usage.speed', '$.message.usage.inference_geo']) AS s,
                json_extract(j, ['$.message.usage.input_tokens', '$.message.usage.output_tokens',
                                 '$.message.usage.cache_read_input_tokens',
                                 '$.message.usage.cache_creation.ephemeral_5m_input_tokens',
                                 '$.message.usage.cache_creation.ephemeral_1h_input_tokens',
                                 '$.message.usage.cache_creation_input_tokens',
                                 '$.costUSD', '$.isApiErrorMessage', '$.message.usage.iterations']) AS x,
                fname
            FROM lines
        ),
        turns AS (
        SELECT
            s[2]                                                         AS ts,
            s[3]                                                         AS model,
            COALESCE(TRY_CAST(x[1] AS BIGINT), 0)                        AS input_tokens,
            COALESCE(TRY_CAST(x[2] AS BIGINT), 0)                        AS output_tokens,
            COALESCE(TRY_CAST(x[3] AS BIGINT), 0)                        AS cache_read,
            COALESCE(TRY_CAST(x[4] AS BIGINT), 0)                        AS explicit_5m,
            COALESCE(TRY_CAST(x[5] AS BIGINT), 0)                        AS explicit_1h,
            COALESCE(TRY_CAST(x[6] AS BIGINT), 0)                        AS summed_cc,
            TRY_CAST(x[7] AS DOUBLE)                                     AS source_cost,
            s[4]                                                         AS message_id,
            s[5]                                                         AS request_id,
            s[6]                                                         AS session_id,
            s[7]                                                         AS cwd,
            s[8]                                                         AS cc_version,
            s[9] IS NOT NULL                                             AS is_complete,
            COALESCE(TRY_CAST(x[8] AS BOOLEAN), false)                   AS api_error,
            s[10]                                                        AS entrypoint,
            s[11]                                                        AS speed,
            s[12]                                                        AS inference_geo,
            -- Only multi-call responses need the per-iteration split (#218);
            -- everything else stays on the top-level fields, as before.
            CASE WHEN json_array_length(x[9]) > 1 THEN CAST(x[9] AS VARCHAR) END AS iterations,
            fname
        FROM parsed
        WHERE s[1] = 'assistant'
          AND s[3] IS NOT NULL
          AND s[3] <> ''
          AND s[3] <> '\(JSONLLineParser.syntheticModelSentinel)'
          AND s[2] IS NOT NULL
        ),
        ranked AS (
            SELECT *, CASE
                -- No dedup key ⇒ never a duplicate, same as the Swift path.
                WHEN message_id IS NULL OR request_id IS NULL THEN 1
                -- A multi-call response is split into one entry per call
                -- (#218), and the line scanner keeps a copy per CALL. Ranking
                -- its lines here would pick every call from one line, by the
                -- final call's numbers, where the line scanner can pick each
                -- call's copy from a different line. So all of its lines go
                -- through, and `CopySelection` ranks the calls after the
                -- split, by the same code the line scanner uses.
                WHEN bool_or(iterations IS NOT NULL)
                    OVER (PARTITION BY message_id || ':' || request_id) THEN 1
                ELSE ROW_NUMBER() OVER (
                    PARTITION BY message_id || ':' || request_id
                    -- `ParsedUsageEntry.isKept` as an ordering: finished first,
                    -- then largest output, then the earliest, then the file.
                    -- The instant, not the text: a line without fractional
                    -- seconds sorts after one with them at the same second as
                    -- text, and offsets don't sort as text at all. The file
                    -- breaks what is left: the same message replayed into
                    -- several transcripts (subagent sidechains, resumed
                    -- sessions) ties on all the rest, and without it which
                    -- copy won depended on how DuckDB's threads happened to
                    -- read the files — 875 of 386k rows differed between 2
                    -- and 4 threads on a real corpus. DuckDB compares text by
                    -- bytes, as `isKept` does.
                    ORDER BY is_complete DESC, output_tokens DESC,
                             TRY_CAST(ts AS TIMESTAMPTZ) ASC NULLS LAST, ts ASC, fname ASC)
            END AS rn
            FROM turns
        )
        -- Explicit projection, in the exact order the Swift reader indexes
        -- its columns. Never `SELECT *` here: the reader addresses columns
        -- positionally, so a reordering would silently misread every row.
        SELECT ts, model, input_tokens, output_tokens, cache_read,
               explicit_5m, explicit_1h, summed_cc, source_cost,
               message_id, request_id, session_id, cwd, cc_version,
               is_complete, api_error, entrypoint, fname,
               speed, inference_geo, iterations
        FROM ranked WHERE rn = 1
        """
    }

    /// Import every transcript under `roots` (each root being a `projects/`
    /// directory). `aliases` is threaded through so project paths canonicalize
    /// identically to the live path.
    func importAll(roots: [ClaudePathResolver.ResolvedRoot], aliases: [String: String] = [:]) throws -> BulkImportResult {
        let started = Date()
        let spill = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-import-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: spill) }
        var db = try Self.openDatabase(spillingTo: spill)
        var con: duckdb_connection?
        defer { duckdb_close(&db) }
        guard duckdb_connect(db, &con) == DuckDBSuccess else { throw ImportError.openFailed }
        defer { duckdb_disconnect(&con) }

        // Marked BEFORE the read. Taken after it, as they were, a turn a live
        // session appended between DuckDB reading its file and the mark was
        // inside the mark but not the import, and the next incremental scan
        // fast-skipped it: lost until the next full scan. Marked first, the
        // live scanner resumes at or before everything the import may have
        // missed, and re-reads cost nothing (the persister rejects them by key).
        let marks = Self.fileMarks(roots: roots.map(\.projectsDirectory))
        let marked = Date()

        var result = duckdb_result()
        let sql = Self.extractionSQL(projectsDirectories: roots.map(\.projectsDirectory.path))
        guard sql.withCString({ duckdb_query(con, $0, &result) }) == DuckDBSuccess else {
            let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown"
            duckdb_destroy_result(&result)
            throw ImportError.queryFailed(message)
        }
        defer { duckdb_destroy_result(&result) }
        let queried = Date()

        // One copy per key, by the line scanner's own rule. The query has
        // already ranked every key but a multi-call response's, so for the
        // rest this keeps the one row it is handed.
        var kept = CopySelection()
        kept.reserveCapacity(64 * 1024)
        // One string per file, not per row: `CopySelection` holds the file
        // of every kept copy, and DuckDB hands back a fresh copy of the path
        // on each of ~400k rows.
        var fileNames: [String: String] = [:]
        var rootByFile: [String: ClaudePathResolver.ResolvedRoot?] = [:]
        // Each row's project, by root and cwd: canonicalizing is two regex
        // searches, run per row on a few hundred distinct answers. The
        // aliases are fixed for the import, so one answer per (root, cwd)
        // is the same answer.
        var projectByRootAndCwd: [String: [String: String?]] = [:]

        // Vectorized read. The row-at-a-time accessors are deprecated and
        // allocate per value; at ~150k rows × 17 columns that difference is
        // the whole point of moving the parse here in the first place.
        let chunkCount = duckdb_result_chunk_count(result)
        for chunkIndex in 0..<chunkCount {
            guard let chunk = duckdb_result_get_chunk(result, chunkIndex) else { continue }
            defer { var c: duckdb_data_chunk? = chunk; duckdb_destroy_data_chunk(&c) }
            let rows = Int(duckdb_data_chunk_get_size(chunk))
            guard rows > 0 else { continue }

            let ts = Column(chunk, 0), model = Column(chunk, 1)
            let input = Column(chunk, 2), output = Column(chunk, 3), cacheRead = Column(chunk, 4)
            let cc5m = Column(chunk, 5), cc1h = Column(chunk, 6), summedCC = Column(chunk, 7)
            let cost = Column(chunk, 8)
            let messageId = Column(chunk, 9), requestId = Column(chunk, 10)
            let sessionId = Column(chunk, 11), cwd = Column(chunk, 12), version = Column(chunk, 13)
            let complete = Column(chunk, 14), apiError = Column(chunk, 15)
            let entrypoint = Column(chunk, 16), fileName = Column(chunk, 17)
            let speed = Column(chunk, 18), inferenceGeo = Column(chunk, 19)
            let iterations = Column(chunk, 20)

            for row in 0..<rows {
                guard let timestampText = ts.string(row),
                      let timestamp = JSONLLineParser.parseTimestampForImport(timestampText),
                      let modelName = model.string(row)
                else { continue }

                // Same legacy-sum fallback the Swift breakdown applies: when
                // neither explicit tier is present, an older line's summed
                // cache_creation counts as the cheaper 5m tier so we never
                // over-estimate cost on historical data.
                let explicit5m = cc5m.int64(row), explicit1h = cc1h.int64(row)
                let summed = summedCC.int64(row)
                let useLegacySum = explicit5m == 0 && explicit1h == 0 && summed > 0

                let dedupKey: String? = {
                    guard let mid = messageId.string(row), let rid = requestId.string(row)
                    else { return nil }
                    return "\(mid):\(rid)"
                }()
                let rawCwd = cwd.string(row)
                var file = fileName.string(row) ?? ""
                if let known = fileNames[file] { file = known } else { fileNames[file] = file }
                // The root the line parser would have stamped (see
                // `rootPath(forFile:among:)`), without which a pinned
                // profile's turns are attributed by the default login's
                // trail. One lookup per file, not per row.
                let root: ClaudePathResolver.ResolvedRoot? = {
                    if let known = rootByFile[file] { return known }
                    let found = ClaudePathResolver.ResolvedRoot.root(forFile: file, among: roots)
                    rootByFile[file] = .some(found)
                    return found
                }()

                let base = ParsedUsageEntry(
                    timestamp: timestamp,
                    model: modelName,
                    breakdown: TokenBreakdown(
                        inputTokens: input.int64(row),
                        outputTokens: output.int64(row),
                        cacheReadTokens: cacheRead.int64(row),
                        cacheCreation5mTokens: useLegacySum ? summed : explicit5m,
                        cacheCreation1hTokens: useLegacySum ? 0 : explicit1h),
                    storedCostUSD: cost.double(row),
                    dedupKey: dedupKey,
                    sessionId: sessionId.string(row),
                    // Through the root, so a root with a fixed project (Claude
                    // Desktop's agent mode) is counted as the line parser
                    // counts it.
                    projectPath: {
                        let rootKey = root?.root.path ?? "", cwdKey = rawCwd ?? "\u{0}"
                        if let known = projectByRootAndCwd[rootKey]?[cwdKey] { return known }
                        let path = root.map { $0.projectPath(forCwd: rawCwd, aliases: aliases) }
                            ?? rawCwd.map { ProjectPathCanonicalizer.canonicalize($0, aliases: aliases) }
                        projectByRootAndCwd[rootKey, default: [:]][cwdKey] = .some(path)
                        return path
                    }(),
                    originalProjectPath: rawCwd,
                    claudeCodeVersion: version.string(row),
                    rootPath: root?.root.path,
                    entrypoint: entrypoint.string(row),
                    isApiErrorMessage: apiError.bool(row),
                    isComplete: complete.bool(row),
                    speed: speed.string(row),
                    inferenceGeo: inferenceGeo.string(row))
                // The same per-iteration split the line parser makes, by the
                // same code, so the two ingest paths agree.
                for entry in JSONLLineParser.expand(base, iterationsJSON: iterations.string(row)) {
                    kept.offer(entry, from: file)
                }
            }
        }

        // Entries must reach the persister in time order: the rollups'
        // pending-sample lists and the session recomputer both assume
        // ascending arrival.
        var entries = kept.takeEntries()
        entries.sort { $0.timestamp < $1.timestamp }
        Log.write("ArchiveImporter", String(
            format: "marks %.1f s · query %.1f s · rows %.1f s (%d threads, %@ cap)",
            marked.timeIntervalSince(started), queried.timeIntervalSince(marked),
            Date().timeIntervalSince(queried), Self.threads, Self.memoryLimit))

        return BulkImportResult(entries: entries,
                                fileMarks: marks,
                                seconds: Date().timeIntervalSince(started))
    }

    /// Where the live scanner should resume each transcript, so the caller
    /// can seed its cursors. Without this the next scan re-reads all 1.8 GB
    /// and the import saves nothing.
    ///
    /// The offset is the end of the last complete line, not the size: the
    /// scanner's own cursors only ever advance by whole lines, and a mark in
    /// the middle of a line still being written would have it resume
    /// mid-line and drop the rest of that line as garbage.
    static func fileMarks(roots: [URL]) -> [String: BulkImportResult.FileMark] {
        var marks: [String: BulkImportResult.FileMark] = [:]
        let fm = FileManager.default
        for root in roots {
            guard let walker = fm.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize,
                      let mtime = values.contentModificationDate else { continue }
                marks[url.path] = BulkImportResult.FileMark(
                    size: endOfLastLine(url, size: Int64(size)), mtime: mtime)
            }
        }
        return marks
    }

    /// The offset just past the last `\n` in the first `size` bytes of the
    /// file, or `size` if it can't be read. One small read per file: almost
    /// every transcript ends in a newline.
    static func endOfLastLine(_ url: URL, size: Int64) -> Int64 {
        guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return size }
        defer { try? handle.close() }
        var end = size
        var step: Int64 = 4 * 1024   // almost always enough; widens for a long line
        while end > 0 {
            let start = max(0, end - step)
            step = 64 * 1024
            guard (try? handle.seek(toOffset: UInt64(start))) != nil,
                  let chunk = try? handle.read(upToCount: Int(end - start)),
                  chunk.count == Int(end - start) else { return size }
            if let newline = chunk.lastIndex(of: 0x0A) {
                return start + Int64(chunk.distance(from: chunk.startIndex, to: newline)) + 1
            }
            end = start
        }
        return 0
    }

    /// One column of a DuckDB result chunk, with the validity mask applied.
    ///
    /// DuckDB hands back a raw pointer per column plus a bitmask of which rows
    /// are non-NULL; reading the data without consulting the mask yields
    /// garbage for NULL rows rather than an error, which is exactly the sort
    /// of silent wrongness this whole exercise is trying to avoid.
    private struct Column {
        private let data: UnsafeMutableRawPointer?
        private let validity: UnsafeMutablePointer<UInt64>?

        init(_ chunk: duckdb_data_chunk, _ index: Int) {
            let vector = duckdb_data_chunk_get_vector(chunk, UInt64(index))
            self.data = duckdb_vector_get_data(vector)
            self.validity = duckdb_vector_get_validity(vector)
        }

        private func isValid(_ row: Int) -> Bool {
            guard let validity else { return true }   // no mask ⇒ no NULLs
            return duckdb_validity_row_is_valid(validity, UInt64(row))
        }

        func int64(_ row: Int) -> Int64 {
            guard isValid(row), let data else { return 0 }
            return data.assumingMemoryBound(to: Int64.self)[row]
        }

        func double(_ row: Int) -> Double? {
            guard isValid(row), let data else { return nil }
            return data.assumingMemoryBound(to: Double.self)[row]
        }

        func bool(_ row: Int) -> Bool {
            guard isValid(row), let data else { return false }
            return data.assumingMemoryBound(to: Bool.self)[row]
        }

        /// DuckDB stores short strings inline in the 16-byte struct and longer
        /// ones behind a pointer; both carry an explicit length and neither is
        /// NUL-terminated, so the length has to be honoured.
        func string(_ row: Int) -> String? {
            guard isValid(row), let data else { return nil }
            var value = data.assumingMemoryBound(to: duckdb_string_t.self)[row]
            let length = Int(duckdb_string_t_length(value))
            guard length > 0 else { return "" }
            if duckdb_string_is_inlined(value) {
                return withUnsafeBytes(of: &value.value.inlined.inlined) { raw in
                    String(decoding: raw.prefix(length), as: UTF8.self)
                }
            }
            guard let pointer = duckdb_string_t_data(&value) else { return nil }
            return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length),
                          as: UTF8.self)
        }
    }
}
