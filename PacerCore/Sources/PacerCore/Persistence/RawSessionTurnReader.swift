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
        guard let db = open(storeURL) else { return nil }
        defer { sqlite3_close(db) }
        return turns(db: db, since: since)
    }

    /// A read-only connection to the store, or nil.
    static func open(_ storeURL: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db
        else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        return db
    }

    /// `turns(storeURL:since:)` over a connection the caller holds open.
    static func turns(db: OpaquePointer, since: Date) -> [(sessionId: String, turn: PacerSessionTurn)]? {
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
        // A busy window is thousands of turns over a few dozen sessions,
        // models, accounts and projects: one copy of each (#337).
        var strings = StringInterner()
        while sqlite3_step(stmt) == SQLITE_ROW {
            // A row that fails to map is a schema surprise, and half a result
            // set is worse than none: bail so the caller falls back.
            guard let sessionId = text(stmt, 0), let model = text(stmt, 2) else { return nil }
            out.append((strings(sessionId), PacerSessionTurn(
                sampledAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1) + referenceEpoch),
                model: strings(model),
                accountId: strings(text(stmt, 3)),
                projectPath: strings(text(stmt, 4)))))
        }
        return out
    }

    /// `PRAGMA data_version`: unchanged until another connection commits to
    /// the store, which every writer Pacer has is.
    static func dataVersion(_ db: OpaquePointer) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA data_version", -1, &stmt, nil) == SQLITE_OK, let stmt
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}

/// The API snapshot's live-session answers, kept between builds and worked
/// out again only when the store has changed (#337).
///
/// The snapshot is rebuilt every 15 s even on an idle machine, and each build
/// opened the store, read six hours of turns into fresh strings, and grouped
/// them into new dictionaries to arrive at the answers it had last time.
/// Between commits the answers cannot change: they read the stored turns,
/// which only a commit moves, and the binding — the activation trail and the
/// Desktop session accounts — which is compared. Time passing only ages
/// sessions out of the window, and the turns a surviving session's answer
/// reads all lie inside it — so a kept answer is filtered, never recomputed.
///
/// One read-only connection is held open for this, which is also what makes
/// `PRAGMA data_version` mean "another connection committed since you last
/// asked". A store file replaced underneath it is noticed by its inode.
final class LiveSessionCache: @unchecked Sendable {

    static let shared = LiveSessionCache()

    private let lock = NSLock()
    // Everything below is guarded by `lock`.
    private var db: OpaquePointer?
    private var path: String?
    private var inode: UInt64?
    private var version: Int64?
    private var binding: (trail: AccountTrail, desktopAccounts: [String: String])?
    /// The earliest `liveSince` the kept answers are good for.
    private var liveSince = Date.distantFuture
    private var answers: [String: PacerSessionLookup] = [:]

    /// Kept answers for sessions still active since `liveSince`, or ones
    /// `compute` derives from a fresh read starting at `readSince`. Nil when
    /// the store can't be read raw; the caller falls back.
    func answers(
        storeURL: URL, liveSince: Date, readSince: Date, binding: PacerSessionBinding,
        compute: ([(sessionId: String, turn: PacerSessionTurn)]) -> [String: PacerSessionLookup]
    ) -> [String: PacerSessionLookup]? {
        lock.lock()
        defer { lock.unlock() }
        guard let db = connection(to: storeURL),
              let current = RawSessionTurnReader.dataVersion(db) else {
            close()
            return nil
        }
        if current == version, let kept = self.binding, kept.trail == binding.trail,
           kept.desktopAccounts == binding.desktopAccounts, liveSince >= self.liveSince {
            return answers.filter { ($0.value.lastActiveAt ?? .distantPast) >= liveSince }
        }
        guard let rows = RawSessionTurnReader.turns(db: db, since: readSince) else {
            close()
            return nil
        }
        answers = compute(rows)
        version = current
        self.binding = (binding.trail, binding.desktopAccounts)
        self.liveSince = liveSince
        return answers
    }

    /// Forget everything and close the connection.
    func reset() {
        lock.lock()
        close()
        lock.unlock()
    }

    /// Must hold `lock`.
    private func connection(to storeURL: URL) -> OpaquePointer? {
        var info = stat()
        let node: UInt64? = stat(storeURL.path, &info) == 0 ? UInt64(info.st_ino) : nil
        if let db, path == storeURL.path, inode == node { return db }
        close()
        guard let opened = RawSessionTurnReader.open(storeURL) else { return nil }
        db = opened
        path = storeURL.path
        inode = node
        return opened
    }

    /// Must hold `lock`.
    private func close() {
        if let db { sqlite3_close(db) }
        db = nil
        path = nil
        inode = nil
        version = nil
        binding = nil
        liveSince = .distantFuture
        answers = [:]
    }
}
