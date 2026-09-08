import Foundation
import SQLite3

/// Reads the two limit tables straight from SQLite, bypassing SwiftData.
///
/// **Why this exists.** The forecast refit reads 32 days of rate-limit and
/// scoped-limit samples — on an active two-account store that is ~75,000 rows —
/// and through SwiftData it costs about five seconds of the ~7 s refit
/// (`scopedLimits:3364, rate:1332` in the phase log). That is not SQLite being
/// slow; it is object materialisation, roughly 65 µs a row for four to ten
/// scalars. The refit is what the dashboard's multi-second hitches queue behind
/// — 30 of 36 slow reads landed inside one — so this is the cost worth removing.
///
/// Precedent: `StoreIndexRepair` already opens the same file directly.
///
/// **Safety.** Read-only connection, so it cannot corrupt anything, and SQLite's
/// WAL mode means it does not block the app's writers. Every failure path
/// returns `nil` rather than throwing or guessing, and every caller falls back
/// to the SwiftData query it replaced — so a schema rename degrades to "slow
/// again", never to "wrong".
///
/// **Correctness.** The column names below are Core Data's mangled ones, which
/// are an implementation detail of a framework nobody here controls. That is
/// exactly why `RawLimitReaderParityTests` writes rows through SwiftData and
/// asserts this reader returns the identical sequence: if the mapping ever
/// drifts, the test says so rather than the forecast quietly changing.
enum RawLimitReader {

    /// Core Data stores dates as seconds since 2001-01-01, not 1970.
    private static let referenceEpoch: TimeInterval = 978_307_200

    // MARK: - Public reads

    /// `RateLimitSample` rows at or after `since`, ascending, optionally for one
    /// account. `nil` account reads every account — the same meaning
    /// `LimitScope.rateLimitPredicate` gives it.
    static func rateRows(
        storeURL: URL, account: String?, since: Date
    ) -> [EngineFeatures.RateRow]? {
        query(storeURL: storeURL, account: account, since: since,
              sql: """
              SELECT ZWINDOW, ZSAMPLEDAT, ZUSEDPERCENTAGE, ZRESETSAT
              FROM ZRATELIMITSAMPLE
              WHERE ZSAMPLEDAT >= ?
              """) { stmt in
            guard let window = text(stmt, 0) else { return nil }
            return EngineFeatures.RateRow(
                window: window,
                at: date(stmt, 1),
                usedPercentage: sqlite3_column_double(stmt, 2),
                resetsAt: optionalDate(stmt, 3))
        }
    }

    /// `UsageLimitSample` rows at or after `since`, ascending, optionally for
    /// one account. `inLatestBatch` is left `false`; the caller stamps it, since
    /// it depends on the newest row in the returned set.
    static func scopedRows(
        storeURL: URL, account: String?, since: Date
    ) -> [EngineFeatures.ScopedRow]? {
        query(storeURL: storeURL, account: account, since: since,
              sql: """
              SELECT ZIDENTITY, ZGROUP, ZLABEL, ZMODELID, ZMODELDISPLAYNAME,
                     ZSURFACE, ZSAMPLEDAT, ZPERCENT, ZRESETSAT, ZISACTIVE
              FROM ZUSAGELIMITSAMPLE
              WHERE ZSAMPLEDAT >= ?
              """) { stmt in
            guard let identity = text(stmt, 0),
                  let group = text(stmt, 1),
                  let label = text(stmt, 2)
            else { return nil }
            return EngineFeatures.ScopedRow(
                identity: identity, group: group, label: label,
                modelId: text(stmt, 3), modelDisplayName: text(stmt, 4),
                surface: text(stmt, 5),
                at: date(stmt, 6),
                usedPercentage: sqlite3_column_double(stmt, 7),
                resetsAt: optionalDate(stmt, 8),
                inLatestBatch: false,
                isActive: sqlite3_column_int(stmt, 9) != 0)
        }
    }

    // MARK: - Machinery

    /// The account predicate is appended rather than parameterised over a
    /// nullable value, because `ZACCOUNTID = ?` never matches NULL and "every
    /// account" has to mean no clause at all.
    private static func query<Row>(
        storeURL: URL, account: String?, since: Date, sql: String,
        map: (OpaquePointer) -> Row?
    ) -> [Row]? {
        var db: OpaquePointer?
        // `file:…?mode=ro` rather than the plain path: it is read-only at the
        // URI level, so nothing here can create or upgrade the file.
        guard sqlite3_open_v2(storeURL.path, &db,
                              SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db
        else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let full = sql
            + (account != nil ? " AND ZACCOUNTID = ?" : "")
            + " ORDER BY ZSAMPLEDAT ASC"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, full, -1, &stmt, nil) == SQLITE_OK, let stmt
        else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970 - referenceEpoch)
        if let account {
            // SQLITE_TRANSIENT: SQLite copies the bytes, so the Swift string
            // does not have to outlive the bind.
            sqlite3_bind_text(stmt, 2, account, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        var out: [Row] = []
        out.reserveCapacity(4096)
        while sqlite3_step(stmt) == SQLITE_ROW {
            // A row that fails to map is a schema surprise, and half a result
            // set is worse than none: bail so the caller falls back.
            guard let row = map(stmt) else { return nil }
            out.append(row)
        }
        return out
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private static func date(_ stmt: OpaquePointer, _ index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(stmt, index) + referenceEpoch)
    }

    private static func optionalDate(_ stmt: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return date(stmt, index)
    }
}
