import Foundation
import SQLite3

/// Reads one account's turns straight from SQLite for the arena's history
/// (`ArenaHistoryBuilder.readSpend`), bypassing SwiftData.
///
/// **Why.** A full arena build reads 120 days of an account's turns, and it
/// ran through SwiftData a day at a time: hundreds of thousands of
/// `TokenSample` objects materialised by a background context on the app's
/// one container, every six hours per account and on every first pass. On
/// the first install that read held the store's coordinator for minutes
/// (`sample(1)`: the scorer 887 of 1541 samples in `readSpend`, inside Core
/// Data's fetch), while the scan, the refit and the views queued behind it.
/// This reads only the columns pricing needs, through its own read-only
/// connection: SQLite's WAL lets it run beside the app's writers without
/// blocking them, and no object is made.
///
/// Same terms as `RawLimitReader`: read-only; a day per statement, so no read
/// transaction pins the WAL for the whole walk; `false` on any surprise, and
/// the caller falls back to the SwiftData read it replaces. The column names
/// are Core Data's mangled ones, so `RuntimeRawSpendReaderTests` builds the
/// same history both ways and asserts they are identical.
enum RawSpendReader {

    /// One turn, with what `CostCalculator.sampleCost` reads.
    struct Turn: AggregatableSample {
        let sampledAt: Date
        let model: String
        let breakdown: TokenBreakdown
        let sourceCostUSD: Double?
        let speed: String?
        let inferenceGeo: String?
        // Not read by pricing.
        var sessionId: String? { nil }
        var projectPath: String? { nil }
        var ccVersion: String? { nil }
        var accountId: String? { nil }
    }

    /// Every turn of `account` in `(after, through]`, handed to `body` one at
    /// a time, `chunk` seconds of them per statement with `between` called
    /// after each. Returns false (having maybe called `body` for some rows)
    /// when the store can't be read this way; the caller discards and falls
    /// back.
    static func forEach(storeURL: URL, account: String, after: Date, through: Date,
                        chunk: TimeInterval = 86400, between: () -> Void = {},
                        _ body: (Turn) -> Void) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            return false
        }
        defer { sqlite3_close(db) }
        // The (accountId, sampledAt) index answers this.
        let sql = """
        SELECT ZSAMPLEDAT, ZMODEL, ZINPUTTOKENS, ZOUTPUTTOKENS, ZCACHEREADTOKENS,
               ZCACHECREATION5MTOKENS, ZCACHECREATION1HTOKENS, ZSOURCECOSTUSD, ZSPEED, ZINFERENCEGEO
        FROM ZTOKENSAMPLE
        WHERE ZACCOUNTID = ?1 AND ZSAMPLEDAT > ?2 AND ZSAMPLEDAT <= ?3
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        // A model id repeats on nearly every row: one copy of each.
        var strings = StringInterner()
        var from = after
        while from < through {
            let to = min(through, from.addingTimeInterval(chunk))
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            // SQLITE_TRANSIENT: SQLite copies the bytes.
            sqlite3_bind_text(stmt, 1, account, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            // Core Data stores a date as its `timeIntervalSinceReferenceDate`:
            // compared as that same double, the bounds are exactly SwiftData's.
            sqlite3_bind_double(stmt, 2, from.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 3, to.timeIntervalSinceReferenceDate)
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW, let model = text(stmt, 1) else { return false }
                body(Turn(
                    sampledAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0)),
                    model: strings(model),
                    breakdown: TokenBreakdown(
                        inputTokens: sqlite3_column_int64(stmt, 2),
                        outputTokens: sqlite3_column_int64(stmt, 3),
                        cacheReadTokens: sqlite3_column_int64(stmt, 4),
                        cacheCreation5mTokens: sqlite3_column_int64(stmt, 5),
                        cacheCreation1hTokens: sqlite3_column_int64(stmt, 6)),
                    sourceCostUSD: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7),
                    speed: strings(text(stmt, 8)),
                    inferenceGeo: strings(text(stmt, 9))))
            }
            // The statement's read transaction ends with the reset above, so a
            // pause here holds nothing.
            between()
            from = to
        }
        return true
    }

    private static func text(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
}
