import Foundation
import SQLite3
import Testing
@testable import PacerCore

/// `#Index` is applied when SwiftData creates a table, and never again. On an
/// upgraded store the declarations are simply absent — which is exactly what
/// happened to the three sample tables when they gained an `accountId`
/// predicate on every read.
@Suite("Repairing indexes SwiftData declared but never built")
struct StoreIndexRepairTests {

    private func makeStore(_ setup: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        for sql in setup { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        sqlite3_close(db)
        return url
    }

    private func indexes(in url: URL, table: String) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='\(table)'"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let c = sqlite3_column_text(statement, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    private static let table = """
        CREATE TABLE ZRATELIMITSAMPLE (Z_PK INTEGER PRIMARY KEY, ZACCOUNTID TEXT,
        ZWINDOW TEXT, ZSAMPLEDAT REAL)
        """

    @Test("an upgraded store gets the missing indexes")
    func createsWhatIsMissing() throws {
        let url = try makeStore([Self.table,
                                 "CREATE INDEX Z_x_sampledAt ON ZRATELIMITSAMPLE (ZSAMPLEDAT)"])
        let created = StoreIndexRepair.run(storeURL: url)
        #expect(created.count == 2)
        let names = indexes(in: url, table: "ZRATELIMITSAMPLE")
        #expect(names.contains("pacer_ix_zratelimitsample_zaccountid_zsampledat"))
        #expect(names.contains("Z_x_sampledAt"))   // never drops anything
    }

    /// A fresh install already has SwiftData's own; a duplicate would cost
    /// write throughput for nothing.
    @Test("an index that already covers the columns is left alone")
    func skipsWhatSwiftDataAlreadyBuilt() throws {
        let url = try makeStore([
            Self.table,
            "CREATE INDEX Z_RateLimitSample_SwiftDataIndexOnBinaryaccountIdsampledAt ON ZRATELIMITSAMPLE (ZACCOUNTID, ZSAMPLEDAT)",
            "CREATE INDEX Z_RateLimitSample_SwiftDataIndexOnBinaryaccountIdwindowsampledAt ON ZRATELIMITSAMPLE (ZACCOUNTID, ZWINDOW, ZSAMPLEDAT)",
        ])
        #expect(StoreIndexRepair.run(storeURL: url).isEmpty)
    }

    /// A wider index that *leads* with the columns we want serves the same
    /// queries, so it counts as covered.
    @Test("a wider index leading with the same columns counts")
    func acceptsALeadingPrefix() throws {
        let url = try makeStore([
            Self.table,
            "CREATE INDEX wide ON ZRATELIMITSAMPLE (ZACCOUNTID, ZSAMPLEDAT, ZWINDOW)",
        ])
        let created = StoreIndexRepair.run(storeURL: url)
        #expect(!created.contains("pacer_ix_zratelimitsample_zaccountid_zsampledat"))
    }

    /// The list grew past the rate-limit table when the Now tile and the
    /// toolbar pill started asking for "this account's newest turn". Both
    /// probes sort by time inside one account, which is a compound index or a
    /// scan of the largest table in the store.
    @Test("the newest-turn and newest-session probes get their indexes")
    func coversTheScopedActivityProbes() throws {
        let url = try makeStore([
            """
            CREATE TABLE ZTOKENSAMPLE (Z_PK INTEGER PRIMARY KEY, ZACCOUNTID TEXT,
            ZSAMPLEDAT REAL)
            """,
            """
            CREATE TABLE ZACCOUNTSESSIONINFO (Z_PK INTEGER PRIMARY KEY,
            ZACCOUNTID TEXT, ZLASTSEENAT REAL)
            """,
        ])
        let created = StoreIndexRepair.run(storeURL: url)
        #expect(created.contains("pacer_ix_ztokensample_zaccountid_zsampledat"))
        #expect(created.contains("pacer_ix_zaccountsessioninfo_zaccountid_zlastseenat"))
        #expect(StoreIndexRepair.run(storeURL: url).isEmpty)
    }

    @Test("running twice creates nothing the second time")
    func isIdempotent() throws {
        let url = try makeStore([Self.table])
        #expect(StoreIndexRepair.run(storeURL: url).count == 2)
        #expect(StoreIndexRepair.run(storeURL: url).isEmpty)
    }

    /// A store that predates a table must not be an error — the repair runs on
    /// every launch and has to be a no-op on anything it does not recognise.
    @Test("an absent table is skipped, not a failure")
    func toleratesAMissingTable() throws {
        let url = try makeStore(["CREATE TABLE ZUNRELATED (Z_PK INTEGER PRIMARY KEY)"])
        #expect(StoreIndexRepair.run(storeURL: url).isEmpty)
    }
}
