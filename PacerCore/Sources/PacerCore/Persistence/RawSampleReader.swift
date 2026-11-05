import Foundation
import SQLite3
import SwiftData

/// Reads every `TokenSample` as a `SampleSnapshot.Row` straight from SQLite,
/// bypassing SwiftData (#335).
///
/// **Why.** A rebuild's snapshot is the whole sample table. Through SwiftData
/// that is object materialisation for every row (~20 s for 744k rows, and
/// the 1.4–1.6 GB footprint floor #335 measured), and every page is a fetch on
/// the container's own coordinator — a coordinator the main thread's
/// `@Query`s wait their turn on. This is a read-only connection of its own, so
/// it costs neither, the same way `RawLimitReader` reads the limit tables.
///
/// **Order.** `Z_PK` is the row id, which is the order an unsorted SwiftData
/// fetch returns (a full table scan). The rollups sum costs in snapshot order,
/// so a different order would move totals in the last bits.
/// `RawSampleReaderParityTests` holds the two readers to the same rows in the
/// same order.
///
/// **Safety.** Any failure — the file, a renamed column, a NULL where the model
/// has none — and the caller walks the store through SwiftData instead: slow
/// again, never wrong.
enum RawSampleReader {

    /// The container's store file, or nil for an in-memory store (tests, the
    /// screenshot harness), which only SwiftData can read.
    static func storeURL(of container: ModelContainer) -> URL? {
        guard let config = container.configurations.first, !config.isStoredInMemoryOnly,
              config.url.isFileURL, config.url.path != "/dev/null" else { return nil }
        return config.url
    }

    /// Every sample, in table order; nil if anything in the file surprised it.
    static func rows(storeURL: URL) -> [SampleSnapshot.Row]? {
        var out: [SampleSnapshot.Row] = []
        let complete = forEach(storeURL: storeURL, reserve: { out.reserveCapacity($0) }) { out.append($0) }
        return complete ? out : nil
    }

    /// Hand every sample to `body`, in table order, without keeping them.
    /// Returns false if the read stopped early: `body` has then seen some of
    /// the rows, never a wrong one.
    @discardableResult
    static func forEach(storeURL: URL, reserve: (Int) -> Void = { _ in },
                        _ body: (SampleSnapshot.Row) -> Void) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db
        else {
            if db != nil { sqlite3_close(db) }
            return false
        }
        defer { sqlite3_close(db) }
        // A WAL reader is rarely refused, but a refusal here costs the whole
        // SwiftData walk, so give a moment's contention a second to clear.
        sqlite3_busy_timeout(db, 1_000)

        let sql = """
            SELECT ZDATE, ZMODEL, ZPROJECTPATH, ZSESSIONID, ZSAMPLEDAT, ZLOCALHOUR, ZCCVERSION,
                   ZINPUTTOKENS, ZOUTPUTTOKENS, ZCACHEREADTOKENS, ZCACHECREATION5MTOKENS,
                   ZCACHECREATION1HTOKENS, ZSOURCECOSTUSD, ZACCOUNTID, ZSPEED, ZINFERENCEGEO
            FROM ZTOKENSAMPLE ORDER BY Z_PK
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }

        var count: OpaquePointer?
        var expected = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ZTOKENSAMPLE", -1, &count, nil) == SQLITE_OK,
           let count {
            if sqlite3_step(count) == SQLITE_ROW { expected = Int(sqlite3_column_int64(count, 0)) }
            sqlite3_finalize(count)
        }

        // One column cache each: consecutive rows mostly repeat their date,
        // model, project, session and account, so most rows build no string.
        var columns = (0..<7).map { _ in TextColumn() }
        var strings = StringInterner()
        reserve(expected)
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return true }
            guard step == SQLITE_ROW,
                  let date = columns[0].read(stmt, 0, &strings),
                  let model = columns[1].read(stmt, 1, &strings),
                  sqlite3_column_type(stmt, 4) != SQLITE_NULL
            else { return false }
            let sampledAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
            let storedHour = Int(sqlite3_column_int64(stmt, 5))
            body(SampleSnapshot.Row(
                date: date,
                model: model,
                projectPath: columns[2].read(stmt, 2, &strings),
                sessionId: columns[3].read(stmt, 3, &strings),
                sampledAt: sampledAt,
                localHour: storedHour >= 0
                    ? storedHour
                    : Calendar.current.component(.hour, from: sampledAt),
                ccVersion: columns[4].read(stmt, 6, &strings),
                breakdown: TokenBreakdown(
                    inputTokens: sqlite3_column_int64(stmt, 7),
                    outputTokens: sqlite3_column_int64(stmt, 8),
                    cacheReadTokens: sqlite3_column_int64(stmt, 9),
                    cacheCreation5mTokens: sqlite3_column_int64(stmt, 10),
                    cacheCreation1hTokens: sqlite3_column_int64(stmt, 11)),
                sourceCostUSD: sqlite3_column_type(stmt, 12) == SQLITE_NULL
                    ? nil : sqlite3_column_double(stmt, 12),
                accountId: columns[5].read(stmt, 13, &strings),
                speed: columns[6].read(stmt, 14, &strings),
                inferenceGeo: text(stmt, 15)))
        }
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    /// The previous row's value of one text column, kept with its bytes so the
    /// next row can reuse it after a `memcmp` instead of building a string.
    private struct TextColumn {
        private var bytes: [UInt8] = []
        private var value: String?
        private var isNull = true

        mutating func read(_ stmt: OpaquePointer, _ index: Int32,
                           _ strings: inout StringInterner) -> String? {
            guard let c = sqlite3_column_text(stmt, index) else {
                isNull = true
                value = nil
                return nil
            }
            let n = Int(sqlite3_column_bytes(stmt, index))
            if !isNull, n == bytes.count,
               bytes.withUnsafeBytes({ memcmp($0.baseAddress, c, n) == 0 }) {
                return value
            }
            let buffer = UnsafeBufferPointer(start: c, count: n)
            let s = strings(String(decoding: buffer, as: UTF8.self))
            bytes = Array(buffer)
            value = s
            isNull = false
            return s
        }
    }
}
