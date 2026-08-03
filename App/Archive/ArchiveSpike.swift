import Foundation
import SwiftData
import PacerCore

/// Headless proof that a DuckDB archive can live inside Pacer.
///
/// **This is a spike, not a feature.** It answers the questions the storage
/// measurements couldn't — the ones that are about *this app* rather than
/// about DuckDB:
///
///   1. Does a ~19 MB C++ static library link into the real Pacer target and
///      run under `ENABLE_HARDENED_RUNTIME`?
///   2. Can it create and write a database file inside the App Group
///      container, alongside `pacer.sqlite`?
///   3. Does the ingestion path (DuckDB's Appender API) faithfully reproduce
///      what SwiftData holds — same row count, same token totals?
///   4. What does it cost — bundle size, ingest throughput, query latency?
///   5. Does the whole thing survive `codesign --options runtime` +
///      notarization + stapling via `make install`?
///
/// Run it with `PACER_ARCHIVE_SPIKE=1`. It reads the real `TokenSample`
/// rows (read-only — the scan loop never starts in this mode), writes a
/// throwaway `pacer-archive-spike.duckdb` next to the store, prints a
/// report, and exits. It never mutates SwiftData and never deletes a
/// sample. Delete the archive file to re-run from scratch.
@MainActor
enum ArchiveSpike {

    static var isActive: Bool {
        ProcessInfo.processInfo.environment["PACER_ARCHIVE_SPIKE"] == "1"
    }

    /// Throwaway file — deliberately NOT the name a shipping archive would
    /// use, so a spike build can never be mistaken for the real thing.
    private static let fileName = "pacer-archive-spike.duckdb"

    private static func log(_ message: String) {
        print("[archive-spike] \(message)")
    }

    // MARK: - Entry point

    static func run(container: ModelContainer) async {
        log("DuckDB \(String(cString: duckdb_library_version()))")

        let archiveURL: URL
        do {
            archiveURL = try PacerStore.sharedContainerURL().appendingPathComponent(fileName)
        } catch {
            log("FAIL: App Group container unavailable — \(error)")
            return
        }
        // Clear the previous run, WAL sidecar included — a stale WAL against
        // a fresh file is its own class of confusing failure.
        for suffix in ["", ".wal", ".tmp"] {
            try? FileManager.default.removeItem(
                at: archiveURL.deletingLastPathComponent()
                    .appendingPathComponent(archiveURL.lastPathComponent + suffix))
        }
        log("archive path: \(archiveURL.path)")

        // 1 · Open inside the App Group container.
        var db: duckdb_database?
        var con: duckdb_connection?
        let openStart = Date()
        guard archiveURL.path.withCString({ duckdb_open($0, &db) }) == DuckDBSuccess,
              duckdb_connect(db, &con) == DuckDBSuccess else {
            log("FAIL: could not open/connect in the App Group container")
            return
        }
        defer { duckdb_disconnect(&con); duckdb_close(&db) }
        log(String(format: "open+connect: %.0f ms", Date().timeIntervalSince(openStart) * 1000))

        guard exec(con, """
            CREATE TABLE IF NOT EXISTS token_sample(
                sampled_at TIMESTAMP, date VARCHAR, model VARCHAR,
                input_tokens BIGINT, output_tokens BIGINT, cache_read BIGINT,
                cache_creation_5m BIGINT, cache_creation_1h BIGINT,
                source_cost DOUBLE, dedup_key VARCHAR, session_id VARCHAR,
                original_project_path VARCHAR, cc_version VARCHAR)
            """) else { return }

        // 2 · Read the real rows out of SwiftData (read-only).
        let readStart = Date()
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<TokenSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .forward)])
        descriptor.propertiesToFetch = [
            \.sampledAt, \.date, \.model, \.inputTokens, \.outputTokens,
            \.cacheReadTokens, \.cacheCreation5mTokens, \.cacheCreation1hTokens,
            \.sourceCostUSD, \.dedupKey, \.sessionId, \.originalProjectPath, \.ccVersion,
        ]
        guard let rows = try? context.fetch(descriptor) else {
            log("FAIL: could not read TokenSample rows"); return
        }
        log(String(format: "read %d SwiftData rows: %.0f ms",
                   rows.count, Date().timeIntervalSince(readStart) * 1000))
        guard !rows.isEmpty else { log("no rows to archive — nothing to prove"); return }

        // 3 · Ingest via the Appender (the path a real backfill would use).
        var appender: duckdb_appender?
        guard duckdb_appender_create(con, nil, "token_sample", &appender) == DuckDBSuccess else {
            log("FAIL: appender_create"); return
        }
        var expectedTokens: Int64 = 0
        let ingestStart = Date()
        for row in rows {
            duckdb_append_timestamp(appender, duckdb_timestamp(
                micros: Int64(row.sampledAt.timeIntervalSince1970 * 1_000_000)))
            appendString(appender, row.date)
            appendString(appender, row.model)
            duckdb_append_int64(appender, row.inputTokens)
            duckdb_append_int64(appender, row.outputTokens)
            duckdb_append_int64(appender, row.cacheReadTokens)
            duckdb_append_int64(appender, row.cacheCreation5mTokens)
            duckdb_append_int64(appender, row.cacheCreation1hTokens)
            if let cost = row.sourceCostUSD { duckdb_append_double(appender, cost) }
            else { duckdb_append_null(appender) }
            appendString(appender, row.dedupKey)
            appendString(appender, row.sessionId)
            appendString(appender, row.originalProjectPath)
            appendString(appender, row.ccVersion)
            duckdb_appender_end_row(appender)
            expectedTokens += row.inputTokens + row.outputTokens + row.cacheReadTokens
        }
        duckdb_appender_close(appender)
        duckdb_appender_destroy(&appender)
        let ingestSeconds = Date().timeIntervalSince(ingestStart)
        log(String(format: "ingest %d rows: %.0f ms (%.0f rows/sec)",
                   rows.count, ingestSeconds * 1000, Double(rows.count) / ingestSeconds))

        // 4 · Correctness: the archive must agree with SwiftData exactly.
        let archivedCount = scalar(con, "SELECT COUNT(*) FROM token_sample") ?? -1
        let archivedTokens = scalar(
            con, "SELECT CAST(SUM(input_tokens + output_tokens + cache_read) AS BIGINT) "
               + "FROM token_sample") ?? -1
        log("row count   swiftdata=\(rows.count) archive=\(archivedCount) "
            + (archivedCount == Int64(rows.count) ? "✓ MATCH" : "✗ MISMATCH"))
        log("token total swiftdata=\(expectedTokens) archive=\(archivedTokens) "
            + (archivedTokens == expectedTokens ? "✓ MATCH" : "✗ MISMATCH"))

        // 5 · Query latency for the things the archive exists to serve.
        time(con, "per-day/model rollup over all history",
             "SELECT date, model, SUM(input_tokens + output_tokens), COUNT(*) "
             + "FROM token_sample GROUP BY date, model")
        time(con, "full re-pricing scan",
             "SELECT SUM(input_tokens * 3.0/1e6 + output_tokens * 15.0/1e6) FROM token_sample")
        time(con, "per-session aggregate",
             "SELECT session_id, SUM(output_tokens) FROM token_sample GROUP BY session_id")

        // 6 · What it cost on disk, against the SwiftData store it mirrors.
        let fm = FileManager.default
        let archiveBytes = byteSize(archiveURL, fm: fm)
        var storeBytes: Int64 = 0
        if let storeURL = try? PacerStore.storeURL() {
            for suffix in ["", "-wal", "-shm"] {
                storeBytes += byteSize(
                    storeURL.deletingLastPathComponent()
                        .appendingPathComponent(storeURL.lastPathComponent + suffix), fm: fm)
            }
        }
        log(String(format: "archive file: %.1f MB for %d rows (%.0f bytes/row)",
                   Double(archiveBytes) / 1_048_576, rows.count,
                   Double(archiveBytes) / Double(rows.count)))
        log(String(format: "swiftdata store (all tables + indexes): %.1f MB",
                   Double(storeBytes) / 1_048_576))
        log("done")
    }

    // MARK: - Thin C-API helpers

    private static func appendString(_ appender: duckdb_appender?, _ value: String?) {
        guard let value else { duckdb_append_null(appender); return }
        value.withCString { _ = duckdb_append_varchar(appender, $0) }
    }

    @discardableResult
    private static func exec(_ con: duckdb_connection?, _ sql: String) -> Bool {
        var result = duckdb_result()
        let ok = sql.withCString { duckdb_query(con, $0, &result) } == DuckDBSuccess
        if !ok, let err = duckdb_result_error(&result) {
            log("SQL FAIL: \(String(cString: err))")
        }
        duckdb_destroy_result(&result)
        return ok
    }

    /// Scalar read. `SUM(BIGINT)` comes back as HUGEINT in DuckDB, which the
    /// legacy `duckdb_value_int64` accessor can't always read — so the SQL
    /// casts to BIGINT and this reports any error rather than a silent nil.
    private static func scalar(_ con: duckdb_connection?, _ sql: String) -> Int64? {
        var result = duckdb_result()
        guard sql.withCString({ duckdb_query(con, $0, &result) }) == DuckDBSuccess else {
            if let err = duckdb_result_error(&result) {
                log("  scalar SQL error: \(String(cString: err))")
            }
            duckdb_destroy_result(&result); return nil
        }
        defer { duckdb_destroy_result(&result) }
        return duckdb_value_int64(&result, 0, 0)
    }

    private static func time(_ con: duckdb_connection?, _ label: String, _ sql: String) {
        let start = Date()
        var result = duckdb_result()
        let ok = sql.withCString { duckdb_query(con, $0, &result) } == DuckDBSuccess
        if !ok, let err = duckdb_result_error(&result) {
            log("  query SQL error: \(String(cString: err))")
        }
        let rows = ok ? duckdb_row_count(&result) : 0
        duckdb_destroy_result(&result)
        log(String(format: "query %-38s %6.1f ms (%d groups)",
                   (label as NSString).utf8String!, Date().timeIntervalSince(start) * 1000,
                   Int(rows)))
    }

    private static func byteSize(_ url: URL, fm: FileManager) -> Int64 {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) as? Int64 ?? 0
    }
}
