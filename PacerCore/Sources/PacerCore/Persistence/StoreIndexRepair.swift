import Foundation
import SQLite3

/// Creates the indexes SwiftData declared but never built.
///
/// `#Index` is applied when SwiftData *creates a table*. On an existing store,
/// lightweight migration adds columns and leaves the indexes alone — silently.
/// The account work made this concrete: the four new per-account rollup tables
/// have their `accountId` indexes because they were created new, while the
/// three pre-existing sample tables, which gained an `accountId` predicate on
/// every single read, have none.
///
/// It is invisible until it isn't. SQLite still answers a scoped "newest N"
/// from the `sampledAt` index in under a millisecond today, so nothing looks
/// broken; but it walks past the other account's rows to do it, and that cost
/// grows with both the table and the number of accounts. Worse, a fresh
/// install and an upgraded one get *different query plans*, which is the kind
/// of difference that makes a performance report impossible to reproduce.
///
/// So: create them directly. Indexes are invisible to Core Data — they are not
/// part of the model hash it validates, nothing in the schema description
/// mentions them, and SQLite maintains them on write regardless of who asked.
/// This only ever runs `CREATE INDEX`; it never drops or alters anything, and
/// every failure is logged and swallowed.
public enum StoreIndexRepair {

    /// One index we want, in terms of the store's physical column names.
    struct Desired {
        let table: String
        let columns: [String]
        /// `pacer_ix_` so it can never collide with a SwiftData-generated name
        /// (`Z_<Model>_SwiftDataIndexOnBinary<props>`), and so it is obvious in
        /// `sqlite_master` who created it.
        var name: String { "pacer_ix_\(table.lowercased())_\(columns.joined(separator: "_").lowercased())" }
    }

    /// Mirrors the `#Index` declarations on `RateLimitSample`,
    /// `UsageLimitSample`, `ExtraUsageSample`, `TokenSample` and
    /// `AccountSessionInfo`. Keep the two in step: this list is what an
    /// *upgraded* store gets, the declarations are what a *fresh* one gets,
    /// and they should describe the same database.
    static let desired: [Desired] = [
        Desired(table: "ZRATELIMITSAMPLE", columns: ["ZACCOUNTID", "ZSAMPLEDAT"]),
        Desired(table: "ZRATELIMITSAMPLE", columns: ["ZACCOUNTID", "ZWINDOW", "ZSAMPLEDAT"]),
        Desired(table: "ZUSAGELIMITSAMPLE", columns: ["ZACCOUNTID", "ZSAMPLEDAT"]),
        Desired(table: "ZUSAGELIMITSAMPLE", columns: ["ZACCOUNTID", "ZIDENTITY", "ZSAMPLEDAT"]),
        Desired(table: "ZEXTRAUSAGESAMPLE", columns: ["ZACCOUNTID", "ZSAMPLEDAT"]),
        // Scoped "newest turn" / "newest session". `ZTOKENSAMPLE` is the
        // largest table in the store, and `ZACCOUNTSESSIONINFO` was created
        // new — but only on machines that have run the account build, so it
        // is listed here too rather than assumed.
        Desired(table: "ZTOKENSAMPLE", columns: ["ZACCOUNTID", "ZSAMPLEDAT"]),
        Desired(table: "ZACCOUNTSESSIONINFO", columns: ["ZACCOUNTID", "ZLASTSEENAT"]),
    ]

    /// Create whatever is missing. Returns the names created, for the log and
    /// for the test.
    @discardableResult
    public static func run(storeURL: URL) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else {
            Log.write("StoreIndexRepair", "could not open the store; skipping")
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        // The app has the same file open. `CREATE INDEX` needs the write lock
        // for as long as it takes to build, so wait rather than fail if a scan
        // cycle is mid-write.
        sqlite3_busy_timeout(db, 10_000)

        var created: [String] = []
        for want in desired {
            guard tableExists(db, want.table) else { continue }
            guard !isCovered(db, table: want.table, columns: want.columns) else { continue }
            let sql = "CREATE INDEX IF NOT EXISTS \(want.name) ON \(want.table) "
                + "(\(want.columns.joined(separator: ", ")))"
            if exec(db, sql) {
                created.append(want.name)
            } else {
                Log.write("StoreIndexRepair",
                          "could not create \(want.name): \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        if !created.isEmpty {
            Log.write("StoreIndexRepair", "created \(created.count) missing index(es): "
                        + created.joined(separator: ", "))
        }
        return created
    }

    /// Whether some existing index already leads with exactly these columns.
    /// A fresh install has SwiftData's own, and adding a duplicate would cost
    /// write throughput for nothing.
    private static func isCovered(_ db: OpaquePointer, table: String, columns: [String]) -> Bool {
        for index in indexNames(db, table: table) {
            let cols = indexColumns(db, index: index)
            if cols.count >= columns.count,
               Array(cols.prefix(columns.count)) == columns { return true }
        }
        return false
    }

    private static func tableExists(_ db: OpaquePointer, _ table: String) -> Bool {
        query(db, "SELECT name FROM sqlite_master WHERE type='table' AND name=?", bind: table)
            .isEmpty == false
    }

    private static func indexNames(_ db: OpaquePointer, table: String) -> [String] {
        query(db, "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?", bind: table)
    }

    private static func indexColumns(_ db: OpaquePointer, index: String) -> [String] {
        // `PRAGMA index_info` cannot be parameterised; the name comes from
        // `sqlite_master` on this same connection, not from user input.
        query(db, "PRAGMA index_info(\(quoted(index)))", column: 2)
    }

    private static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func query(_ db: OpaquePointer, _ sql: String,
                              bind: String? = nil, column: Int32 = 0) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if let bind {
            sqlite3_bind_text(statement, 1, (bind as NSString).utf8String, -1, nil)
        }
        var out: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let c = sqlite3_column_text(statement, column) {
                out.append(String(cString: c))
            }
        }
        return out
    }
}
