import Foundation
import PacerCore

/// Append-only columnar store of every billable turn Pacer has ever seen.
///
/// Pacer never deletes raw data — that's what makes it possible to evaluate
/// prediction models against real history, build metrics nobody has designed
/// yet, and recompute values that old code got wrong. SwiftData can hold that
/// forever too, just expensively: measured on a real store, the same rows cost
/// **99.7 MB there against 13.0 MB here**, and projected five years out,
/// **1,460 MB against 180 MB**. The difference is structural rather than
/// clever — 75% of a row is strings, nearly all of them low-cardinality
/// repeats (60 distinct project paths, 8 models) that columnar dictionary
/// encoding collapses for free.
///
/// ## What this is not, yet
///
/// This writes a second copy. The storage win only arrives once SwiftData
/// stops holding the full history and keeps a recent window plus rollups —
/// and it can't do that until something else holds the rest, which is why the
/// archive has to exist first. Until then the cost is ~13 MB of duplication
/// and the benefit is that the raw truth is queryable analytically.
///
/// ## Rules
///
/// - **Append-only.** Rows are facts about what was observed. Anything derived
///   — canonicalized project paths, prices — belongs in a view over this, not
///   a rewrite of it. Columnar stores have no cheap `UPDATE` anyway, so the
///   format enforces the discipline.
/// - **The store is still the system of record.** Every write here is
///   verifiable against SwiftData (`make verify-data`), and on any
///   disagreement SwiftData wins.
/// - **Failures are non-fatal.** The archive is additive; if it can't be
///   opened or written, Pacer logs and carries on. Nothing user-visible reads
///   it yet.
///
/// DuckDB takes an exclusive per-process file lock, so only the app may open
/// this — never the widget extension, which links neither DuckDB nor this
/// file. See `docs/duckdb-archive.md`.
final class RawArchive {

    enum ArchiveError: Error {
        case openFailed(String)
        case queryFailed(String)
    }

    private var db: duckdb_database?
    private var con: duckdb_connection?

    /// Opens (creating if needed) the archive beside the SwiftData store.
    init(url: URL) throws {
        var message: UnsafeMutablePointer<CChar>?
        let opened = url.path.withCString { duckdb_open_ext($0, &db, nil, &message) }
        guard opened == DuckDBSuccess else {
            let detail = message.map { String(cString: $0) } ?? "unknown"
            duckdb_free(message)
            throw ArchiveError.openFailed(detail)
        }
        guard duckdb_connect(db, &con) == DuckDBSuccess else {
            throw ArchiveError.openFailed("connect")
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS turn(
                sampled_at TIMESTAMP NOT NULL,
                date VARCHAR NOT NULL,
                local_hour INTEGER NOT NULL,
                model VARCHAR NOT NULL,
                input_tokens BIGINT NOT NULL,
                output_tokens BIGINT NOT NULL,
                cache_read BIGINT NOT NULL,
                cache_creation_5m BIGINT NOT NULL,
                cache_creation_1h BIGINT NOT NULL,
                source_cost DOUBLE,
                dedup_key VARCHAR,
                session_id VARCHAR,
                -- The RAW cwd, never the canonicalized path. Canonicalization
                -- depends on the alias graph, which changes; storing its
                -- output would bake a decision into a table that must only
                -- hold observations.
                original_project_path VARCHAR,
                cc_version VARCHAR)
            """)
    }

    deinit {
        duckdb_disconnect(&con)
        duckdb_close(&db)
    }

    // MARK: - Writing

    /// Append turns. Caller guarantees these are new — dedup happens upstream
    /// in `SamplePersister`, and re-running it here would mean a second
    /// implementation of the rule that decides what a duplicate is.
    func append(_ rows: [ArchiveRow]) throws {
        guard !rows.isEmpty else { return }
        var appender: duckdb_appender?
        guard duckdb_appender_create(con, nil, "turn", &appender) == DuckDBSuccess else {
            throw ArchiveError.queryFailed("appender_create")
        }
        defer { duckdb_appender_destroy(&appender) }

        for row in rows {
            duckdb_append_timestamp(appender, duckdb_timestamp(
                micros: Int64(row.sampledAt.timeIntervalSince1970 * 1_000_000)))
            appendText(appender, row.date)
            duckdb_append_int32(appender, Int32(row.localHour))
            appendText(appender, row.model)
            duckdb_append_int64(appender, row.breakdown.inputTokens)
            duckdb_append_int64(appender, row.breakdown.outputTokens)
            duckdb_append_int64(appender, row.breakdown.cacheReadTokens)
            duckdb_append_int64(appender, row.breakdown.cacheCreation5mTokens)
            duckdb_append_int64(appender, row.breakdown.cacheCreation1hTokens)
            if let cost = row.sourceCostUSD { duckdb_append_double(appender, cost) }
            else { duckdb_append_null(appender) }
            appendText(appender, row.dedupKey)
            appendText(appender, row.sessionId)
            appendText(appender, row.originalProjectPath)
            appendText(appender, row.ccVersion)
            duckdb_appender_end_row(appender)
        }
        guard duckdb_appender_close(appender) == DuckDBSuccess else {
            throw ArchiveError.queryFailed("appender_close")
        }
    }

    // MARK: - Reading

    struct Totals: Equatable {
        var rows: Int64 = 0
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cc5m: Int64 = 0
        var cc1h: Int64 = 0
    }

    /// Sums for verifying against SwiftData. `CAST(... AS BIGINT)` because
    /// `SUM(BIGINT)` yields HUGEINT, which the C scalar accessor can't read —
    /// the same trap that made an early spike report a phantom mismatch.
    /// - Parameter beforeDate: only count turns whose local `date` sorts
    ///   before this `YYYY-MM-DD` string. Day-bounded rather than
    ///   instant-bounded so the store side can be answered from
    ///   `DailyAggregate` — comparing whole days is the difference between a
    ///   200-row read and materializing every sample.
    func totals(beforeDate: String? = nil) throws -> Totals {
        // Safe to interpolate: callers pass a formatted date, and the column
        // is compared as text. Quoted defensively all the same.
        let filter = beforeDate.map { " WHERE date < '\($0.replacingOccurrences(of: "'", with: ""))'" } ?? ""
        var t = Totals()
        t.rows = try scalar("SELECT COUNT(*) FROM turn" + filter)
        t.input = try scalar("SELECT CAST(COALESCE(SUM(input_tokens),0) AS BIGINT) FROM turn" + filter)
        t.output = try scalar("SELECT CAST(COALESCE(SUM(output_tokens),0) AS BIGINT) FROM turn" + filter)
        t.cacheRead = try scalar("SELECT CAST(COALESCE(SUM(cache_read),0) AS BIGINT) FROM turn" + filter)
        t.cc5m = try scalar("SELECT CAST(COALESCE(SUM(cache_creation_5m),0) AS BIGINT) FROM turn" + filter)
        t.cc1h = try scalar("SELECT CAST(COALESCE(SUM(cache_creation_1h),0) AS BIGINT) FROM turn" + filter)
        return t
    }

    /// Newest turn already archived, so the caller knows where to resume.
    func watermark() throws -> Date? {
        let micros = try scalar(
            "SELECT COALESCE(CAST(EPOCH_US(MAX(sampled_at)) AS BIGINT), -1) FROM turn")
        return micros < 0 ? nil : Date(timeIntervalSince1970: Double(micros) / 1_000_000)
    }

    /// Dedup keys already archived at or after `since`, so a caller can tell
    /// which store turns are genuinely missing rather than merely older than
    /// the newest thing archived.
    ///
    /// Bounded by the caller's window rather than scanning the whole table —
    /// this runs periodically, and a columnar scan of one string column over
    /// a month of turns is cheap where a scan of five years would not be.
    func dedupKeys(since: Date) throws -> Set<String> {
        var result = duckdb_result()
        let micros = Int64(since.timeIntervalSince1970 * 1_000_000)
        let sql = """
            SELECT dedup_key FROM turn
            WHERE dedup_key IS NOT NULL
              AND sampled_at >= make_timestamp(\(micros))
            """
        let ok = sql.withCString { duckdb_query(con, $0, &result) } == DuckDBSuccess
        defer { duckdb_destroy_result(&result) }
        guard ok else {
            throw ArchiveError.queryFailed(
                duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown")
        }

        var keys: Set<String> = []
        // Vectorized chunk reads. The per-value accessors are deprecated and
        // slow enough to eat the point of doing this at all.
        while let chunk = duckdb_fetch_chunk(result) {
            defer { var c: duckdb_data_chunk? = chunk; duckdb_destroy_data_chunk(&c) }
            let count = Int(duckdb_data_chunk_get_size(chunk))
            guard count > 0 else { continue }
            let vector = duckdb_data_chunk_get_vector(chunk, 0)
            guard let data = duckdb_vector_get_data(vector) else { continue }
            let validity = duckdb_vector_get_validity(vector)
            let strings = data.assumingMemoryBound(to: duckdb_string_t.self)
            for row in 0..<count {
                if let validity, !duckdb_validity_row_is_valid(validity, UInt64(row)) { continue }
                var value = strings[row]
                let length = Int(duckdb_string_t_length(value))
                guard length > 0 else { continue }
                if duckdb_string_is_inlined(value) {
                    withUnsafeBytes(of: &value.value.inlined.inlined) { raw in
                        keys.insert(String(decoding: raw.prefix(length), as: UTF8.self))
                    }
                } else if let pointer = duckdb_string_t_data(&value) {
                    keys.insert(String(
                        decoding: UnsafeRawBufferPointer(start: pointer, count: length),
                        as: UTF8.self))
                }
            }
        }
        return keys
    }

    /// Collapse turns held more than once, keeping the copy with the most
    /// output tokens — the same rule the store's repair uses.
    ///
    /// Sits uneasily with "append-only", so: append-only is a rule about not
    /// rewriting *observations*. Two rows describing one turn aren't two
    /// observations, they're one bookkeeping error, and this file's own
    /// contract already says the store is the system of record and wins on
    /// any disagreement. When the store collapses a duplicate, an archive
    /// that kept both would be permanently, visibly wrong.
    ///
    /// Returns the number of rows removed. Checks first and executes nothing
    /// when there is nothing to do, so the common path issues no DELETE at
    /// all.
    @discardableResult
    func collapseDuplicates() throws -> Int64 {
        let duplicated = try scalar("""
            SELECT COUNT(*) FROM (
                SELECT dedup_key FROM turn
                WHERE dedup_key IS NOT NULL
                GROUP BY dedup_key HAVING COUNT(*) > 1)
            """)
        guard duplicated > 0 else { return 0 }

        let before = try scalar("SELECT COUNT(*) FROM turn")
        try exec("""
            DELETE FROM turn WHERE rowid IN (
                SELECT rowid FROM (
                    SELECT rowid, row_number() OVER (
                        PARTITION BY dedup_key
                        ORDER BY output_tokens DESC, sampled_at ASC, rowid ASC) AS rn
                    FROM turn WHERE dedup_key IS NOT NULL)
                WHERE rn > 1)
            """)
        return before - (try scalar("SELECT COUNT(*) FROM turn"))
    }

    /// Best `output_tokens` archived per dedup key, at or after `since`.
    ///
    /// Presence alone isn't enough to tell whether a turn is faithfully
    /// archived: a streamed message is written partial and UPGRADED in place
    /// in the store when its finished copy arrives, so a key can be present
    /// and still be wrong. The archive can't see that mutation, so the caller
    /// compares values.
    func outputByDedupKey(since: Date?) throws -> [String: Int64] {
        var result = duckdb_result()
        let filter = since.map {
            " AND sampled_at >= make_timestamp(\(Int64($0.timeIntervalSince1970 * 1_000_000)))"
        } ?? ""
        let sql = """
            SELECT dedup_key, MAX(output_tokens) FROM turn
            WHERE dedup_key IS NOT NULL\(filter) GROUP BY dedup_key
            """
        let ok = sql.withCString { duckdb_query(con, $0, &result) } == DuckDBSuccess
        defer { duckdb_destroy_result(&result) }
        guard ok else {
            throw ArchiveError.queryFailed(
                duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown")
        }

        var out: [String: Int64] = [:]
        while let chunk = duckdb_fetch_chunk(result) {
            defer { var c: duckdb_data_chunk? = chunk; duckdb_destroy_data_chunk(&c) }
            let count = Int(duckdb_data_chunk_get_size(chunk))
            guard count > 0,
                  let keyData = duckdb_vector_get_data(duckdb_data_chunk_get_vector(chunk, 0)),
                  let valData = duckdb_vector_get_data(duckdb_data_chunk_get_vector(chunk, 1))
            else { continue }
            let keys = keyData.assumingMemoryBound(to: duckdb_string_t.self)
            let values = valData.assumingMemoryBound(to: Int64.self)
            for row in 0..<count {
                var value = keys[row]
                let length = Int(duckdb_string_t_length(value))
                guard length > 0 else { continue }
                let key: String
                if duckdb_string_is_inlined(value) {
                    key = withUnsafeBytes(of: &value.value.inlined.inlined) { raw in
                        String(decoding: raw.prefix(length), as: UTF8.self)
                    }
                } else if let pointer = duckdb_string_t_data(&value) {
                    key = String(decoding: UnsafeRawBufferPointer(start: pointer, count: length),
                                 as: UTF8.self)
                } else { continue }
                out[key] = values[row]
            }
        }
        return out
    }

    /// Read whole turns back out for one local date.
    ///
    /// Until this existed the archive was **write-only**: it could report how
    /// many turns it held and what they summed to, but not hand one back. That
    /// makes it a checksum, not a record — and it is the reason trimming
    /// SwiftData was never safe to attempt. A trim you cannot undo is a
    /// deletion; a trim you can undo is a cache eviction.
    ///
    /// Bounded by date deliberately: restoring is a targeted operation (this
    /// day looks wrong / I want this range back), and an unbounded read would
    /// materialize five years of turns to answer it.
    func turns(onDate date: String) throws -> [ArchiveRow] {
        var result = duckdb_result()
        let safe = date.replacingOccurrences(of: "'", with: "")
        let sql = """
            SELECT sampled_at, date, local_hour, model,
                   input_tokens, output_tokens, cache_read,
                   cache_creation_5m, cache_creation_1h, source_cost,
                   dedup_key, session_id, original_project_path, cc_version
            FROM turn WHERE date = '\(safe)' ORDER BY sampled_at
            """
        let ok = sql.withCString { duckdb_query(con, $0, &result) } == DuckDBSuccess
        defer { duckdb_destroy_result(&result) }
        guard ok else {
            throw ArchiveError.queryFailed(
                duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown")
        }

        var rows: [ArchiveRow] = []
        while let chunk = duckdb_fetch_chunk(result) {
            defer { var c: duckdb_data_chunk? = chunk; duckdb_destroy_data_chunk(&c) }
            let count = Int(duckdb_data_chunk_get_size(chunk))
            guard count > 0 else { continue }

            let vectors = (0..<14).map { duckdb_data_chunk_get_vector(chunk, UInt64($0)) }
            let data = vectors.map { duckdb_vector_get_data($0) }
            let validity = vectors.map { duckdb_vector_get_validity($0) }
            func isNull(_ col: Int, _ row: Int) -> Bool {
                guard let v = validity[col] else { return false }
                return !duckdb_validity_row_is_valid(v, UInt64(row))
            }
            func int64(_ col: Int, _ row: Int) -> Int64 {
                data[col]?.assumingMemoryBound(to: Int64.self)[row] ?? 0
            }
            func text(_ col: Int, _ row: Int) -> String? {
                guard !isNull(col, row), let base = data[col] else { return nil }
                var value = base.assumingMemoryBound(to: duckdb_string_t.self)[row]
                let length = Int(duckdb_string_t_length(value))
                guard length > 0 else { return "" }
                if duckdb_string_is_inlined(value) {
                    return withUnsafeBytes(of: &value.value.inlined.inlined) {
                        String(decoding: $0.prefix(length), as: UTF8.self)
                    }
                }
                guard let pointer = duckdb_string_t_data(&value) else { return nil }
                return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length),
                              as: UTF8.self)
            }

            for row in 0..<count {
                // TIMESTAMP is microseconds since epoch in DuckDB's layout.
                let micros = data[0]?.assumingMemoryBound(to: Int64.self)[row] ?? 0
                rows.append(ArchiveRow(
                    sampledAt: Date(timeIntervalSince1970: Double(micros) / 1_000_000),
                    date: text(1, row) ?? date,
                    localHour: Int(data[2]?.assumingMemoryBound(to: Int32.self)[row] ?? -1),
                    model: text(3, row) ?? "",
                    breakdown: TokenBreakdown(
                        inputTokens: int64(4, row),
                        outputTokens: int64(5, row),
                        cacheReadTokens: int64(6, row),
                        cacheCreation5mTokens: int64(7, row),
                        cacheCreation1hTokens: int64(8, row)),
                    sourceCostUSD: isNull(9, row)
                        ? nil : data[9]?.assumingMemoryBound(to: Double.self)[row],
                    dedupKey: text(10, row),
                    sessionId: text(11, row),
                    originalProjectPath: text(12, row),
                    ccVersion: text(13, row)))
            }
        }
        return rows
    }

    // MARK: - Plumbing

    private func appendText(_ appender: duckdb_appender?, _ value: String?) {
        guard let value else { duckdb_append_null(appender); return }
        value.withCString { _ = duckdb_append_varchar(appender, $0) }
    }

    private func exec(_ sql: String) throws {
        var result = duckdb_result()
        let ok = sql.withCString { duckdb_query(con, $0, &result) } == DuckDBSuccess
        defer { duckdb_destroy_result(&result) }
        guard ok else {
            throw ArchiveError.queryFailed(
                duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown")
        }
    }

    private func scalar(_ sql: String) throws -> Int64 {
        var result = duckdb_result()
        let ok = sql.withCString { duckdb_query(con, $0, &result) } == DuckDBSuccess
        defer { duckdb_destroy_result(&result) }
        guard ok else {
            throw ArchiveError.queryFailed(
                duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown")
        }
        return duckdb_value_int64(&result, 0, 0)
    }
}

/// One turn, as a plain value — so the archive never touches SwiftData objects
/// and can be fed from any actor.
struct ArchiveRow: Sendable {
    let sampledAt: Date
    let date: String
    let localHour: Int
    let model: String
    let breakdown: TokenBreakdown
    let sourceCostUSD: Double?
    let dedupKey: String?
    let sessionId: String?
    let originalProjectPath: String?
    let ccVersion: String?
}
