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
            || ProcessInfo.processInfo.environment["PACER_COLD_START_SPIKE"] == "1"
            || ProcessInfo.processInfo.environment["PACER_IMPORT_SPIKE"] == "1"
    }

    static var isImport: Bool {
        ProcessInfo.processInfo.environment["PACER_IMPORT_SPIKE"] == "1"
    }

    /// The bulk-import path end to end: DuckDB parses, the ordinary
    /// `SamplePersister` persists. Reports the same totals the cold-start
    /// harness does so the two are directly comparable — same corpus, same
    /// expected rows, same expected token sums.
    static func runImport() async {
        log("bulk import: DuckDB parse → SamplePersister → in-memory store")
        guard let container = try? PacerStore.makeInMemoryContainer() else {
            log("FAIL: in-memory container"); return
        }
        await SampleCostCache.reload()
        let roots: [URL]
        do {
            roots = try ClaudePathResolver().resolve().map(\.projectsDirectory)
        } catch {
            log("FAIL: could not resolve Claude roots — \(error)"); return
        }
        log("roots: \(roots.map(\.path).joined(separator: ", "))")

        let imported: ArchiveImporter.Result
        do {
            imported = try ArchiveImporter.importAll(roots: roots)
        } catch {
            log("FAIL: import threw \(error)"); return
        }
        log(String(format: "PARSE (DuckDB): %.2f s for %d entries from %d files",
                   imported.seconds, imported.entries.count, imported.fileMarks.count))

        let persistStart = Date()
        do {
            let outcome = try await persist(entries: imported.entries, container: container)
            log(String(format: "PERSIST: %.2f s — inserted %d, duplicates %d, upgraded %d",
                       Date().timeIntervalSince(persistStart),
                       outcome.inserted, outcome.duplicates, outcome.upgraded))
            log("  TOTALS rows=\(outcome.rows) input=\(outcome.input) output=\(outcome.output) "
                + "cacheRead=\(outcome.cacheRead) cc5m=\(outcome.cc5m) cc1h=\(outcome.cc1h) "
                + "all=\(outcome.input + outcome.output + outcome.cacheRead + outcome.cc5m + outcome.cc1h)")
        } catch {
            log("FAIL: persist threw \(error)"); return
        }
        log("done")
    }

    private struct PersistOutcome: Sendable {
        var inserted = 0, duplicates = 0, upgraded = 0, rows = 0
        var input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0
        var cc5m: Int64 = 0, cc1h: Int64 = 0
    }

    /// Persisting runs on `ScanActor` — the same isolation the live scan uses,
    /// so the bulk path exercises the persister exactly as production does
    /// rather than through some test-only relaxation. Totals are summed here
    /// and returned as plain numbers because `TokenSample` can't cross actors.
    @ScanActor
    private static func persist(
        entries: [ParsedUsageEntry], container: ModelContainer
    ) throws -> PersistOutcome {
        let context = ModelContext(container)
        let persister = try SamplePersister(context: context)
        for entry in entries { _ = try persister.insert(entry) }
        try context.save()

        var outcome = PersistOutcome()
        outcome.inserted = persister.stats.inserted
        outcome.duplicates = persister.stats.skippedAsDuplicate
        outcome.upgraded = persister.stats.upgradedFromPartial
        for row in try context.fetch(FetchDescriptor<TokenSample>()) {
            outcome.rows += 1
            outcome.input += row.inputTokens
            outcome.output += row.outputTokens
            outcome.cacheRead += row.cacheReadTokens
            outcome.cc5m += row.cacheCreation5mTokens
            outcome.cc1h += row.cacheCreation1hTokens
        }
        return outcome
    }

    /// Measure what a *first* launch actually costs: an empty store, the real
    /// scanner, the user's whole `~/.claude` history.
    ///
    /// This is the number the bulk-ingest design hinges on. "Swift is slow at
    /// ingesting months of history" splits into two very different costs —
    /// parsing the JSONL, and inserting rows into SwiftData — and only the
    /// first is one DuckDB can take over. If the cold start is parse-bound,
    /// routing the backfill through DuckDB fixes it; if it's insert-bound,
    /// the rows have to stop landing in SwiftData at all for it to matter.
    /// The scan report's phase timings separate the two.
    static var isColdStart: Bool {
        ProcessInfo.processInfo.environment["PACER_COLD_START_SPIKE"] == "1"
    }

    static func runColdStart() async {
        log("cold-start ingest: empty in-memory store, real scanner, real ~/.claude")
        guard let container = try? PacerStore.makeInMemoryContainer() else {
            log("FAIL: in-memory container"); return
        }
        await SampleCostCache.reload()
        let coordinator = ScanCoordinator(container: container)
        let start = Date()
        do {
            let report = try await coordinator.runOnce()
            let elapsed = Date().timeIntervalSince(start)
            let p = report.phaseTimings
            log(String(format: "TOTAL cold ingest: %.1f s (scan report: %.1f s)",
                       elapsed, report.durationSeconds))
            log("  parsed \(report.scanProgress.entriesParsed) entries from "
                + "\(report.scanProgress.filesScanned) files, "
                + "inserted \(report.persisterStats.inserted), "
                + "deduped \(report.persisterStats.skippedAsDuplicate)")
            log(String(format: "  PARSE  (scan phase, JSONL→entries):  %8.0f ms", p.scanMs))
            log(String(format: "  INSERT (save phase, entries→store):  %8.0f ms", p.saveMs))
            log(String(format: "  flush %.0f · daily %.0f · hourly %.0f · project %.0f · session %.0f ms",
                       p.flushMs, p.dailyRecomputeMs, p.hourlyRecomputeMs,
                       p.projectRecomputeMs, p.sessionRecomputeMs))

            // Field-level totals for the differential test against the DuckDB
            // extraction. A matching row COUNT proves the filter and dedup
            // agree; only per-field sums prove the mapping does — a swapped
            // cache tier or a missed legacy-sum fallback keeps the count
            // identical while silently changing everyone's cost.
            let ctx = ModelContext(container)
            if let rows = try? ctx.fetch(FetchDescriptor<TokenSample>()) {
                var input: Int64 = 0, output: Int64 = 0, read: Int64 = 0
                var cc5m: Int64 = 0, cc1h: Int64 = 0
                for r in rows {
                    input += r.inputTokens; output += r.outputTokens
                    read += r.cacheReadTokens
                    cc5m += r.cacheCreation5mTokens; cc1h += r.cacheCreation1hTokens
                }
                log("  TOTALS rows=\(rows.count) input=\(input) output=\(output) "
                    + "cacheRead=\(read) cc5m=\(cc5m) cc1h=\(cc1h) "
                    + "all=\(input + output + read + cc5m + cc1h)")
            }
        } catch {
            log("FAIL: scan threw \(error)")
        }
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
