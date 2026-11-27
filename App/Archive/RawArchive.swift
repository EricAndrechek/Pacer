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
    ///
    /// **Configured, not defaulted.** DuckDB sizes its worker pool to the
    /// machine's core count and parks every one of those threads in
    /// `TaskScheduler::ExecuteForever`. That's the right default for an
    /// analytics box running big queries; it is completely wrong for a menu-bar
    /// app that holds a connection open for its entire lifetime to append a
    /// handful of rows per scan cycle.
    ///
    /// Shipped without this, it cost **a full core, continuously**: measured
    /// at 100.3% average CPU over 22 hours on a 14-core machine, with 14
    /// threads sampled inside `ExecuteForever` — one per core, doing nothing.
    /// Pacer's whole reason to exist is that it sits quietly in the
    /// background, and the perf work behind it fought to reach ~0% idle.
    init(url: URL) throws {
        var config: duckdb_config?
        if duckdb_create_config(&config) == DuckDBSuccess {
            // One worker. The heaviest thing this connection ever does is a
            // COUNT/SUM over ~200k rows, which finishes in milliseconds
            // single-threaded; parallelism here buys nothing and costs a core.
            _ = "threads".withCString { name in
                "1".withCString { value in duckdb_set_config(config, name, value) }
            }
            // The buffer manager otherwise sizes itself to a share of system
            // RAM. The archive is 13 MB.
            _ = "memory_limit".withCString { name in
                "256MB".withCString { value in duckdb_set_config(config, name, value) }
            }
        }
        defer { duckdb_destroy_config(&config) }

        var message: UnsafeMutablePointer<CChar>?
        let opened = url.path.withCString { duckdb_open_ext($0, &db, config, &message) }
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
        try migrate()
    }

    /// Columns added after `turn` first shipped, oldest first (#352).
    ///
    /// Each is appended to the END of the table, on a fresh archive and an
    /// old one alike, so both end with the same column order, which the
    /// appender writes by position. Nullable with no default: rows archived
    /// before a column existed read NULL, which means "not recorded", never
    /// "standard" or "no account".
    ///
    /// - `account_id`: the account the store attributed the turn to when it
    ///   was archived (`TokenSample.accountId`). Attribution is a decision,
    ///   and the store can correct it later (`make reassign-account`); the
    ///   archive keeps what it was given, so a later correction is not
    ///   reflected here. Kept anyway: it is the only copy that survives if
    ///   the store ever sheds history.
    /// - `speed`, `inference_geo`: `usage.speed` and `usage.inference_geo` as
    ///   parsed. Both change what a turn costs (fast mode, US residency), and
    ///   transcripts are pruned after about 30 days.
    ///
    /// Not backfilled: the store still holds every older row's values, and a
    /// columnar UPDATE joined against a million-row walk of the store is not
    /// a step to run on the scan actor for data that is not at risk yet.
    static let addedColumns: [(name: String, type: String)] = [
        ("account_id", "VARCHAR"),
        ("speed", "VARCHAR"),
        ("inference_geo", "VARCHAR"),
    ]

    /// Bring `turn` up to `addedColumns`. Checks the catalog first, so an
    /// archive that already has them issues no DDL at all.
    private func migrate() throws {
        for column in Self.addedColumns {
            let present = try scalar("""
                SELECT COUNT(*) FROM information_schema.columns
                WHERE table_name = 'turn' AND column_name = '\(column.name)'
                """)
            guard present == 0 else { continue }
            try exec("ALTER TABLE turn ADD COLUMN \(column.name) \(column.type)")
            Log.write("RawArchive", "added column turn.\(column.name)")
        }
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
                micros: ArchiveRow.micros(row.sampledAt)))
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
            // `addedColumns`, in order.
            appendText(appender, row.accountId)
            appendText(appender, row.speed)
            appendText(appender, row.inferenceGeo)
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
                        _ = keys.insert(String(decoding: raw.prefix(length), as: UTF8.self))
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

    /// Which of a turn's copies the collapse keeps: the most output, then the
    /// copy appended last.
    ///
    /// - **Most output first** is rule 7 as far as the archive can see it. It
    ///   holds no `stop_reason`, and a streamed message's finished copy is the
    ///   one with the most output (true for every key on a real corpus,
    ///   `docs/duckdb-archive.md`), so a partial copy never wins, however late
    ///   it was appended.
    /// - **Then the latest append**, because every row is written from the
    ///   store as it was at the time, so the newest copy is the store's
    ///   current one. The store rewrites a row at EQUAL output when a full
    ///   re-read brings the pricing detail it predates (fast mode,
    ///   `inference_geo`, a response split into several calls): input and
    ///   cache change, output does not. The reconcile re-appends that row, and
    ///   the tie-break this replaced (earliest `sampled_at`, then lowest
    ///   `rowid`) kept the stale copy, so the hourly check failed on one Mac
    ///   from 0.8.2 on and the full reconcile it triggers never converged
    ///   (#433).
    ///
    /// `rowid` is the append order: DuckDB appends to the end of the table and
    /// never reuses a deleted row's slot, and a checkpoint that compacts row
    /// groups renumbers rows without reordering them
    /// (`RawArchiveReconcileTests` checks that on the vendored engine). Rows
    /// are compared by it only within one key, so its values never matter,
    /// only their order. `reconcileView` picks the same copy in Swift; the
    /// tests pin the two together.
    static let collapseOrder = "output_tokens DESC, rowid DESC"

    /// Collapse turns held more than once, keeping the copy `collapseOrder`
    /// ranks first.
    ///
    /// Sits uneasily with "append-only", so: append-only is a rule about not
    /// rewriting *observations*. Two rows describing one turn aren't two
    /// observations, they're one bookkeeping error, and this file's own
    /// contract already says the store is the system of record and wins on
    /// any disagreement. When the store collapses a duplicate, an archive
    /// that kept both would be permanently, visibly wrong. The same holds for
    /// a copy the store has since rewritten: the reconcile appends the store's
    /// current copy, and this supersedes the stale one.
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
                        ORDER BY \(Self.collapseOrder)) AS rn
                    FROM turn WHERE dedup_key IS NOT NULL)
                WHERE rn > 1)
            """)
        return before - (try scalar("SELECT COUNT(*) FROM turn"))
    }

    /// Per dedup key, at or after `since`: the copy the collapse keeps, as
    /// the reconcile compares it (`ArchivedTurn`).
    ///
    /// Presence alone isn't enough to tell whether a turn is faithfully
    /// archived: the store rewrites rows in place — a streamed message when
    /// its finished copy arrives, a finished one when a full re-read brings
    /// pricing detail it predates — so a key can be present and still be
    /// wrong. The archive can't see those writes, so the caller compares
    /// values: output, and a fingerprint of every other field the store
    /// can rewrite.
    ///
    /// A plain scan, with the winner picked here, rather than a window
    /// function in SQL: on a 1.2M-row archive with one thread the scan took
    /// 0.20 s, `row_number()` 0.46 s (and the output-only `GROUP BY` this
    /// replaced 0.14 s). Duplicates exist only between an append and its
    /// collapse, so the winner test almost never runs.
    ///
    /// Read in `rowid` pages, ascending, and each page returns its rows in
    /// insertion order (DuckDB preserves it for a query without `ORDER BY`,
    /// `preserve_insertion_order`, on by default and never changed here),
    /// which is `rowid` order. So a later row of a key is a later append, and
    /// the map holds no `rowid`. Paged because `duckdb_query` materializes its
    /// whole result before the first chunk is fetched: ten columns of every
    /// row at once raised a full reconcile's peak footprint by 190 MB on a
    /// real 1.2M-row copy (the streaming result API is deprecated in 1.5).
    /// A `rowid` range is pushed into the scan: 15 ms a page.
    func reconcileView(since: Date?) throws -> [String: ArchivedTurn] {
        let filter = since.map {
            " AND sampled_at >= make_timestamp(\(ArchiveRow.micros($0)))"
        } ?? ""
        // Sized up front: growing a million-entry map doubles it, and the
        // old and new storage coexist while it does.
        var out: [String: ArchivedTurn] = [:]
        out.reserveCapacity(Int(try scalar(
            "SELECT COUNT(*) FROM turn WHERE dedup_key IS NOT NULL" + filter)))
        let last = try scalar("SELECT COALESCE(MAX(rowid), -1) FROM turn")
        var low: Int64 = 0
        while low <= last {
            let high = low + Self.reconcilePageRows
            try readReconcilePage(
                "\(filter) AND rowid >= \(low) AND rowid < \(high)", into: &out)
            low = high
        }
        return out
    }

    /// About one row group.
    static let reconcilePageRows: Int64 = 131_072

    private func readReconcilePage(_ filter: String, into out: inout [String: ArchivedTurn]) throws {
        var result = duckdb_result()
        // Column order is what the reader below indexes.
        let sql = """
            SELECT dedup_key, output_tokens, input_tokens, cache_read,
                   cache_creation_5m, cache_creation_1h, source_cost,
                   CAST(EPOCH_US(sampled_at) AS BIGINT), speed, inference_geo
            FROM turn WHERE dedup_key IS NOT NULL\(filter)
            """
        let ok = sql.withCString { duckdb_query(con, $0, &result) } == DuckDBSuccess
        defer { duckdb_destroy_result(&result) }
        guard ok else {
            throw ArchiveError.queryFailed(
                duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown")
        }

        while let chunk = duckdb_fetch_chunk(result) {
            defer { var c: duckdb_data_chunk? = chunk; duckdb_destroy_data_chunk(&c) }
            let count = Int(duckdb_data_chunk_get_size(chunk))
            guard count > 0 else { continue }
            let vectors = (0..<10).map { duckdb_data_chunk_get_vector(chunk, UInt64($0)) }
            let data = vectors.map { duckdb_vector_get_data($0) }
            let validity = vectors.map { duckdb_vector_get_validity($0) }
            func isNull(_ col: Int, _ row: Int) -> Bool {
                guard let v = validity[col] else { return false }
                return !duckdb_validity_row_is_valid(v, UInt64(row))
            }
            func int64(_ col: Int, _ row: Int) -> Int64 {
                data[col]?.assumingMemoryBound(to: Int64.self)[row] ?? 0
            }
            for row in 0..<count {
                guard let key = Self.text(data[0], row, isNull: isNull(0, row)), !key.isEmpty
                else { continue }
                let output = int64(1, row)
                // `collapseOrder`, in Swift: most output, then the later
                // append, which is the later row read.
                if let kept = out[key], kept.outputTokens > output { continue }
                let speed = Self.text(data[8], row, isNull: isNull(8, row))
                let geo = Self.text(data[9], row, isNull: isNull(9, row))
                let recorded: ArchivedTurn.Recorded = [
                    speed == nil ? [] : .speed, geo == nil ? [] : .inferenceGeo,
                ]
                out[key] = ArchivedTurn(
                    outputTokens: output,
                    fingerprint: ArchivedTurn.fingerprint(
                        input: int64(2, row), cacheRead: int64(3, row),
                        cc5m: int64(4, row), cc1h: int64(5, row),
                        sourceCostUSD: isNull(6, row)
                            ? nil : data[6]?.assumingMemoryBound(to: Double.self)[row],
                        sampledAtMicros: int64(7, row),
                        speed: speed, inferenceGeo: geo),
                    recorded: recorded)
            }
        }
    }

    /// A VARCHAR value out of a chunk's vector data, or nil when NULL.
    private static func text(_ base: UnsafeMutableRawPointer?, _ row: Int, isNull: Bool) -> String? {
        guard !isNull, let base else { return nil }
        var value = base.assumingMemoryBound(to: duckdb_string_t.self)[row]
        let length = Int(duckdb_string_t_length(value))
        guard length > 0 else { return "" }
        if duckdb_string_is_inlined(value) {
            return withUnsafeBytes(of: &value.value.inlined.inlined) {
                String(decoding: $0.prefix(length), as: UTF8.self)
            }
        }
        guard let pointer = duckdb_string_t_data(&value) else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
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
                   dedup_key, session_id, original_project_path, cc_version,
                   account_id, speed, inference_geo
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

            let vectors = (0..<17).map { duckdb_data_chunk_get_vector(chunk, UInt64($0)) }
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
                    ccVersion: text(13, row),
                    accountId: text(14, row),
                    speed: text(15, row),
                    inferenceGeo: text(16, row)))
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
    /// `RawArchive.addedColumns`. Nil on rows archived before they existed.
    let accountId: String?
    let speed: String?
    let inferenceGeo: String?

    /// `sampled_at` as the archive stores it: whole microseconds, truncated.
    /// One function for the write and for the reconcile's comparison, so the
    /// two can't round differently and see every turn as changed.
    static func micros(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000_000)
    }
}

/// One archived turn as the reconcile compares it against the store: the copy
/// the duplicate collapse keeps (`RawArchive.collapseOrder`), reduced to what
/// the store can rewrite after archiving (#433).
///
/// The store rewrites a row through `SamplePersister.apply`: input, output,
/// cache read, both cache-creation tiers, source cost, speed and
/// `inference_geo` (and thinking tokens, which the archive doesn't carry).
/// Output is kept as a number, because its direction decides what to do. The
/// rest are a fingerprint, plus `sampled_at`, which no store write changes:
/// the collapse no longer breaks ties on it, so a pair of copies that differ
/// only there (residue of a store duplicate, `repairDuplicateSamples`) has to
/// be caught here instead.
///
/// A fingerprint rather than the values: a full reconcile holds one of these
/// per archived turn (1.2M on a real archive), at 24 bytes each where the
/// values would take about 96 (the output-only reconcile held 8). `Hasher` is
/// seeded per process, which is enough: both sides are hashed by the same
/// process, in the same pass, and a collision between two different rows of
/// one turn is a 1-in-2^64 chance of leaving one stale.
struct ArchivedTurn: Sendable {

    /// Which of the columns added in #352 held a value. NULL there means
    /// "not recorded" on every row archived before them (never backfilled),
    /// so a NULL is compared as matching whatever the store holds, as
    /// `ArchiveRoundTrip` does. Comparing it as nil would re-append every
    /// pre-#352 turn the store has a speed or region for — a backfill the
    /// archive deliberately never ran, on the scan actor.
    ///
    /// The same byte carries two marks the reconcile sets while it walks the
    /// store, so they cost no memory: `visited`, any store row of this turn
    /// seen this pass, and `reached`, one seen with at least the archived
    /// output (see `visit`).
    struct Recorded: OptionSet, Sendable {
        let rawValue: UInt8
        static let speed = Recorded(rawValue: 1 << 0)
        static let inferenceGeo = Recorded(rawValue: 1 << 1)
        static let visited = Recorded(rawValue: 1 << 2)
        static let reached = Recorded(rawValue: 1 << 3)
    }

    enum Verdict: Equatable {
        /// The archived copy matches the store's.
        case same
        /// The store holds more output: the archived copy is mid-stream.
        case upgraded
        /// Equal output, something else rewritten (#433).
        case patched
        /// The archive holds MORE output than the store. An append can't fix
        /// that — the collapse keeps the larger copy — so it is left, and
        /// counted per turn when no store row of it reached the archived
        /// output. The six-day soak, and every check since, found none.
        case ahead
        /// Equal output, but an earlier store row of the same turn already
        /// reached it: a store duplicate, not compared (see `visit`).
        case superseded
    }

    let outputTokens: Int64
    let fingerprint: Int
    var recorded: Recorded

    /// What the reconcile does with a store row of this turn, given in the
    /// walk's order (`sampledAt`, then row id), and marks the turn.
    ///
    /// **One store row per turn is compared at equal output: the first.**
    /// The store can hold the same key twice (residue from before its dedup
    /// guard, until `repairDuplicateSamples` runs), at equal output and a
    /// different `sampledAt`. Comparing both against the archive's one copy
    /// re-appended whichever differed, the collapse kept it, and the next
    /// pass re-appended the other: re-appends 0, 1, 0, 1 forever. The first
    /// row at equal output in this order is the one the store's repair keeps
    /// (largest output, then earliest, ties in row-id order), so that is the
    /// copy the archive follows. A later row with MORE output than the
    /// archive is still an upgrade: the repair would keep it, and the
    /// collapse keeps the largest output whatever else was appended.
    mutating func visit(storeOutput: Int64, storeFingerprint: () -> Int) -> Verdict {
        defer { recorded.insert(.visited) }
        if storeOutput < outputTokens { return .ahead }
        if storeOutput > outputTokens {
            recorded.insert(.reached)
            return .upgraded
        }
        guard !recorded.contains(.reached) else { return .superseded }
        recorded.insert(.reached)
        return storeFingerprint() == fingerprint ? .same : .patched
    }

    /// Visited this pass, and no store row of it reached the archived output.
    var isAhead: Bool { recorded.contains(.visited) && !recorded.contains(.reached) }

    /// The store's side, hashed the way this turn was archived: a column
    /// this copy didn't record is left out on both sides. Plain values, so a
    /// full reconcile hashes a million store rows without building a row
    /// value for each.
    func storeFingerprint(
        input: Int64, cacheRead: Int64, cc5m: Int64, cc1h: Int64,
        sourceCostUSD: Double?, sampledAt: Date, speed: String?, inferenceGeo: String?
    ) -> Int {
        Self.fingerprint(
            input: input, cacheRead: cacheRead, cc5m: cc5m, cc1h: cc1h,
            sourceCostUSD: sourceCostUSD, sampledAtMicros: ArchiveRow.micros(sampledAt),
            speed: recorded.contains(.speed) ? speed : nil,
            inferenceGeo: recorded.contains(.inferenceGeo) ? inferenceGeo : nil)
    }

    /// Every compared field but output. Both sides call this one function.
    static func fingerprint(
        input: Int64, cacheRead: Int64, cc5m: Int64, cc1h: Int64,
        sourceCostUSD: Double?, sampledAtMicros: Int64,
        speed: String?, inferenceGeo: String?
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(input)
        hasher.combine(cacheRead)
        hasher.combine(cc5m)
        hasher.combine(cc1h)
        // The bits, not the value: the archive stores the store's Double
        // exactly, and bits are what round-trip.
        hasher.combine(sourceCostUSD?.bitPattern)
        hasher.combine(sampledAtMicros)
        hasher.combine(speed)
        hasher.combine(inferenceGeo)
        return hasher.finalize()
    }
}
