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
enum ArchiveImporter {

    struct Result {
        var entries: [ParsedUsageEntry]
        /// Byte length + mtime per file at read time, so the live scanner can
        /// resume from the end of what was imported instead of re-reading it
        /// all on the very next cycle.
        var fileMarks: [String: (size: Int64, mtime: Date)]
        var seconds: Double
    }

    enum ImportError: Error {
        case openFailed
        case queryFailed(String)
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
    /// exactly once in each language, and the differential test pins them
    /// together — the six token totals must match the Swift path to the token.
    ///
    /// The rule mirrors `ParsedUsageEntry.supersedes`: prefer the *finished*
    /// message (`stop_reason` present — Claude Code appends the same turn
    /// several times while streaming and only the last copy carries the real
    /// `output_tokens`), then the largest output. Rows with no dedup key fall
    /// through untouched, exactly as the Swift path leaves them.
    private static func extractionSQL(globs: [String]) -> String {
        let sources = globs.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ", ")
        return """
        WITH lines AS (
            SELECT json AS j FROM read_ndjson_objects([\(sources)],
                ignore_errors = true, maximum_object_size = 67108864)
        ),
        turns AS (
        SELECT
            json_extract_string(j, '$.timestamp')                        AS ts,
            json_extract_string(j, '$.message.model')                    AS model,
            COALESCE(TRY_CAST(json_extract(j, '$.message.usage.input_tokens')  AS BIGINT), 0) AS input_tokens,
            COALESCE(TRY_CAST(json_extract(j, '$.message.usage.output_tokens') AS BIGINT), 0) AS output_tokens,
            COALESCE(TRY_CAST(json_extract(j, '$.message.usage.cache_read_input_tokens') AS BIGINT), 0) AS cache_read,
            COALESCE(TRY_CAST(json_extract(j, '$.message.usage.cache_creation.ephemeral_5m_input_tokens') AS BIGINT), 0) AS explicit_5m,
            COALESCE(TRY_CAST(json_extract(j, '$.message.usage.cache_creation.ephemeral_1h_input_tokens') AS BIGINT), 0) AS explicit_1h,
            COALESCE(TRY_CAST(json_extract(j, '$.message.usage.cache_creation_input_tokens') AS BIGINT), 0) AS summed_cc,
            TRY_CAST(json_extract(j, '$.costUSD') AS DOUBLE)             AS source_cost,
            json_extract_string(j, '$.message.id')                       AS message_id,
            json_extract_string(j, '$.requestId')                        AS request_id,
            json_extract_string(j, '$.sessionId')                        AS session_id,
            json_extract_string(j, '$.cwd')                              AS cwd,
            json_extract_string(j, '$.version')                          AS cc_version,
            json_extract_string(j, '$.message.stop_reason') IS NOT NULL  AS is_complete,
            COALESCE(TRY_CAST(json_extract(j, '$.isApiErrorMessage') AS BOOLEAN), false) AS api_error
        FROM lines
        WHERE json_extract_string(j, '$.type') = 'assistant'
          AND json_extract_string(j, '$.message.model') IS NOT NULL
          AND json_extract_string(j, '$.message.model') <> ''
          AND json_extract_string(j, '$.message.model') <> '\(JSONLLineParser.syntheticModelSentinel)'
          AND json_extract_string(j, '$.timestamp') IS NOT NULL
        ),
        ranked AS (
            SELECT *, CASE
                -- No dedup key ⇒ never a duplicate, same as the Swift path.
                WHEN message_id IS NULL OR request_id IS NULL THEN 1
                ELSE ROW_NUMBER() OVER (
                    PARTITION BY message_id || ':' || request_id
                    -- `supersedes`, expressed as an ordering: finished first,
                    -- then largest output. Timestamp last so the choice is
                    -- total and file order can never change the result.
                    ORDER BY is_complete DESC, output_tokens DESC, ts ASC)
            END AS rn
            FROM turns
        )
        -- Explicit projection, in the exact order the Swift reader indexes
        -- its columns. Never `SELECT *` here: the reader addresses columns
        -- positionally, so a reordering would silently misread every row.
        SELECT ts, model, input_tokens, output_tokens, cache_read,
               explicit_5m, explicit_1h, summed_cc, source_cost,
               message_id, request_id, session_id, cwd, cc_version,
               is_complete, api_error
        FROM ranked WHERE rn = 1
        """
    }

    /// Import every transcript under `roots` (each root being a `projects/`
    /// directory). `aliases` is threaded through so project paths canonicalize
    /// identically to the live path.
    static func importAll(roots: [URL], aliases: [String: String] = [:]) throws -> Result {
        let started = Date()
        var db: duckdb_database?
        var con: duckdb_connection?
        // An in-memory database: this is a pure parse, nothing is persisted
        // here. The archive is a separate concern.
        guard duckdb_open(nil, &db) == DuckDBSuccess,
              duckdb_connect(db, &con) == DuckDBSuccess else { throw ImportError.openFailed }
        defer { duckdb_disconnect(&con); duckdb_close(&db) }

        let globs = roots.map { $0.appendingPathComponent("**/*.jsonl").path }
        var result = duckdb_result()
        let sql = extractionSQL(globs: globs)
        guard sql.withCString({ duckdb_query(con, $0, &result) }) == DuckDBSuccess else {
            let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown"
            duckdb_destroy_result(&result)
            throw ImportError.queryFailed(message)
        }
        defer { duckdb_destroy_result(&result) }

        var entries: [ParsedUsageEntry] = []
        entries.reserveCapacity(64 * 1024)

        // Vectorized read. The row-at-a-time accessors are deprecated and
        // allocate per value; at ~150k rows × 16 columns that difference is
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

                entries.append(ParsedUsageEntry(
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
                    projectPath: rawCwd.map {
                        ProjectPathCanonicalizer.canonicalize($0, aliases: aliases) },
                    originalProjectPath: rawCwd,
                    claudeCodeVersion: version.string(row),
                    isApiErrorMessage: apiError.bool(row),
                    isComplete: complete.bool(row)))
            }
        }

        // Entries must reach the persister in time order: `supersedes` breaks
        // ties on output size, but the rollups' pending-sample lists and the
        // session recomputer both assume ascending arrival.
        entries.sort { $0.timestamp < $1.timestamp }

        return Result(entries: entries,
                      fileMarks: fileMarks(roots: roots),
                      seconds: Date().timeIntervalSince(started))
    }

    /// Size + mtime for every transcript we just read, so the caller can seed
    /// the live scanner's cursors. Without this the next scan re-reads all
    /// 1.8 GB and the import saves nothing.
    private static func fileMarks(roots: [URL]) -> [String: (size: Int64, mtime: Date)] {
        var marks: [String: (size: Int64, mtime: Date)] = [:]
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
                marks[url.path] = (Int64(size), mtime)
            }
        }
        return marks
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
