import Foundation
import SQLite3

/// Reads `EngineEvalOutcome` rows straight from SQLite, bypassing SwiftData.
///
/// **Why.** The arena models multiply the rate-limit record: two dozen models
/// scored at eight cuts over months of cycles is tens of thousands of rows per
/// account beside the engine's own. Through SwiftData every one is an object
/// materialised at ~65 µs (the measured cost `RawLimitReader` exists to
/// avoid), and two readers need them: the engine's first refit of a launch
/// (`fetchEvalRows`), which every ask queues behind, and the arena scorer,
/// which reads a window's record for the cycles it might score.
///
/// Same terms as `RawLimitReader`: a read-only connection; `nil` on any
/// surprise, so the caller falls back to the SwiftData fetch it replaces; and
/// `RawEvalReaderParityTests` writes rows through SwiftData and asserts this
/// returns the identical set, because the column names are Core Data's
/// mangled ones.
enum RawEvalReader {

    struct Row: Sendable, Equatable, Hashable {
        let surface: String
        let method: String
        let bucket: String
        let periodKey: String
        let predicted: Double
        let truth: Double
    }

    /// Every row of one scope: surfaces ending in `suffix` (`#<account>`), or
    /// with no `#` at all when `suffix` is empty (`EngineScope.suffix`).
    static func scopeRows(storeURL: URL, suffix: String) -> [Row]? {
        if suffix.isEmpty {
            return query(storeURL, "WHERE instr(ZSURFACE, '#') = 0", binds: [])
        }
        return query(storeURL, "WHERE length(ZSURFACE) >= ?1 AND substr(ZSURFACE, length(ZSURFACE) - ?1 + 1) = ?2",
                     binds: [.int(suffix.unicodeScalars.count), .text(suffix)])
    }

    /// One surface's rows for these periods.
    static func surfaceRows(storeURL: URL, surface: String, periods: [String]) -> [Row]? {
        guard !periods.isEmpty else { return [] }
        guard let rows = query(storeURL, "WHERE ZSURFACE = ?1", binds: [.text(surface)]) else { return nil }
        let wanted = Set(periods)
        return rows.filter { wanted.contains($0.periodKey) }
    }

    private enum Bind { case int(Int), text(String) }

    private static func query(_ storeURL: URL, _ whereClause: String, binds: [Bind]) -> [Row]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT ZSURFACE, ZMETHOD, ZBUCKET, ZPERIODKEY, ZPREDICTED, ZTRUTH FROM ZENGINEEVALOUTCOME "
            + whereClause
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            switch b {
            case .int(let v): sqlite3_bind_int64(stmt, Int32(i + 1), Int64(v))
            // SQLITE_TRANSIENT: SQLite copies the bytes.
            case .text(let s): sqlite3_bind_text(stmt, Int32(i + 1), s, -1,
                                                 unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }
        var out: [Row] = []
        out.reserveCapacity(4096)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let surface = text(stmt, 0), let method = text(stmt, 1),
                  let bucket = text(stmt, 2), let period = text(stmt, 3) else { return nil }
            out.append(Row(surface: surface, method: method, bucket: bucket, periodKey: period,
                           predicted: sqlite3_column_double(stmt, 4), truth: sqlite3_column_double(stmt, 5)))
        }
        return out
    }

    private static func text(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
}
