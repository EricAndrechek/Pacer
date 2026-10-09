import Foundation
import SQLite3

/// Reads recent turns straight from SQLite for the API snapshot's session table
/// (#211), bypassing SwiftData.
///
/// **Why this exists.** The snapshot answers `/v1/session` for every session
/// seen in the last six hours, and it is rebuilt every few seconds while
/// anything is happening. Through SwiftData that was 200 `TokenSample` objects
/// per session, about 260 ms a build for 14 sessions on a real store: object
/// materialisation at ~90 µs a row, not SQLite. This reads the same columns
/// for every live session in one indexed query.
///
/// Same safety and correctness terms as `RawLimitReader`: a read-only
/// connection; `nil` on any surprise, so the caller falls back to the
/// SwiftData path it replaced; and `RawSessionTurnReaderParityTests` writes
/// rows through SwiftData and asserts this returns the identical sequence,
/// because the column names are Core Data's mangled ones.
enum RawSessionTurnReader {

    /// Core Data stores dates as seconds since 2001-01-01, not 1970.
    private static let referenceEpoch: TimeInterval = 978_307_200

    /// Every turn at or after `since` that carries a session id, newest first,
    /// with the columns `PacerSessionLookupBuilder` reads.
    static func turns(storeURL: URL, since: Date) -> [(sessionId: String, turn: PacerSessionTurn)]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db
        else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT ZSESSIONID, ZSAMPLEDAT, ZMODEL, ZACCOUNTID, ZPROJECTPATH
        FROM ZTOKENSAMPLE
        WHERE ZSAMPLEDAT >= ? AND ZSESSIONID IS NOT NULL
        ORDER BY ZSAMPLEDAT DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970 - referenceEpoch)

        var out: [(sessionId: String, turn: PacerSessionTurn)] = []
        out.reserveCapacity(8192)
        while sqlite3_step(stmt) == SQLITE_ROW {
            // A row that fails to map is a schema surprise, and half a result
            // set is worse than none: bail so the caller falls back.
            guard let sessionId = text(stmt, 0), let model = text(stmt, 2) else { return nil }
            out.append((sessionId, PacerSessionTurn(
                sampledAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1) + referenceEpoch),
                model: model,
                accountId: text(stmt, 3),
                projectPath: text(stmt, 4))))
        }
        return out
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}
