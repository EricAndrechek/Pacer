#if canImport(CDuckDB)
import CDuckDB
import Foundation
import Testing
@testable import PacerCore

/// The archive's `turn` table gained `account_id`, `speed` and
/// `inference_geo` (#352). An archive written before them must open, keep
/// every row it had, read those rows back with the new fields nil, and take
/// new rows with the fields set, in the same column order a fresh archive has.
///
/// `RawArchive` lives in the app target, beside DuckDB, so this runs where
/// DuckDB is linked: `bin/dev-ingest-parity.sh --fixtures` (CI's app job).
@Suite("Raw archive migration")
struct RawArchiveMigrationTests {

    static func tempURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("raw-archive.duckdb")
    }

    /// The `turn` table exactly as it first shipped, with one row in it.
    static func writeOriginalArchive(at url: URL) throws {
        var db: duckdb_database?
        var con: duckdb_connection?
        #expect(url.path.withCString { duckdb_open($0, &db) } == DuckDBSuccess)
        #expect(duckdb_connect(db, &con) == DuckDBSuccess)
        defer { duckdb_disconnect(&con); duckdb_close(&db) }
        for sql in [
            """
            CREATE TABLE turn(
                sampled_at TIMESTAMP NOT NULL, date VARCHAR NOT NULL, local_hour INTEGER NOT NULL,
                model VARCHAR NOT NULL, input_tokens BIGINT NOT NULL, output_tokens BIGINT NOT NULL,
                cache_read BIGINT NOT NULL, cache_creation_5m BIGINT NOT NULL,
                cache_creation_1h BIGINT NOT NULL, source_cost DOUBLE, dedup_key VARCHAR,
                session_id VARCHAR, original_project_path VARCHAR, cc_version VARCHAR)
            """,
            """
            INSERT INTO turn VALUES (make_timestamp(1790000000000000), '2026-09-21', 10,
                'claude-opus-5-5', 1, 2, 3, 4, 5, NULL, 'm-old:r-old', 's-old', '/tmp/old', '2.1.0')
            """,
        ] {
            var result = duckdb_result()
            #expect(sql.withCString { duckdb_query(con, $0, &result) } == DuckDBSuccess)
            duckdb_destroy_result(&result)
        }
    }

    static func row(_ key: String, date: String, account: String?, speed: String?, geo: String?) -> ArchiveRow {
        ArchiveRow(
            sampledAt: Date(timeIntervalSince1970: 1_790_003_600), date: date, localHour: 11,
            model: "claude-opus-5-5",
            breakdown: TokenBreakdown(inputTokens: 10, outputTokens: 20, cacheReadTokens: 30,
                                      cacheCreation5mTokens: 40, cacheCreation1hTokens: 50),
            sourceCostUSD: nil, dedupKey: key, sessionId: "s", originalProjectPath: "/tmp/p",
            ccVersion: "2.1.1", accountId: account, speed: speed, inferenceGeo: geo)
    }

    @Test func anOriginalArchiveMigratesInPlaceAndKeepsItsRows() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Self.writeOriginalArchive(at: url)

        do {
            let archive = try RawArchive(url: url)
            #expect(try archive.totals().rows == 1)
            let old = try #require(try archive.turns(onDate: "2026-09-21").first)
            #expect(old.dedupKey == "m-old:r-old" && old.breakdown.outputTokens == 2)
            #expect(old.accountId == nil && old.speed == nil && old.inferenceGeo == nil)

            try archive.append([Self.row("m-new:r-new", date: "2026-09-21",
                                         account: "acct-a", speed: "fast", geo: "us")])
            let rows = try archive.turns(onDate: "2026-09-21")
            let new = try #require(rows.first { $0.dedupKey == "m-new:r-new" })
            #expect(new.accountId == "acct-a" && new.speed == "fast" && new.inferenceGeo == "us")
            #expect(new.ccVersion == "2.1.1" && new.breakdown.cacheCreation1hTokens == 50)
        }
        // Reopening finds the columns and changes nothing.
        let again = try RawArchive(url: url)
        #expect(try again.totals().rows == 2)
        #expect(try again.turns(onDate: "2026-09-21").count == 2)
    }

    @Test func aFreshArchiveHasTheSameShape() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let archive = try RawArchive(url: url)
        try archive.append([
            Self.row("m1:r1", date: "2026-11-11", account: "acct-a", speed: "standard", geo: "global"),
            Self.row("m2:r2", date: "2026-11-11", account: nil, speed: nil, geo: nil),
        ])
        let rows = try archive.turns(onDate: "2026-11-11")
        #expect(rows.count == 2)
        let first = try #require(rows.first { $0.dedupKey == "m1:r1" })
        #expect(first.accountId == "acct-a" && first.speed == "standard" && first.inferenceGeo == "global")
        let second = try #require(rows.first { $0.dedupKey == "m2:r2" })
        #expect(second.accountId == nil && second.speed == nil && second.inferenceGeo == nil)
    }
}
#endif
