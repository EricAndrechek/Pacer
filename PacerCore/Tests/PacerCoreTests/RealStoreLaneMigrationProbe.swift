import CoreData
import Darwin
import Foundation
import SQLite3
import SwiftData
import Testing
@testable import PacerCore

/// The #352 schema change, migrating a frozen COPY of a real store (AGENTS.md
/// rule 8): a `laneId` on `RateLimitSample`, `UsageLimitSample` and
/// `AccountUsageArchive`, and the new `LiveMeterOutcome` table. That it is a
/// lightweight migration, that it loses nothing, and what it costs: how long
/// `prepareStore` takes and how many bytes it writes.
///
///     sqlite3 "<store>" ".backup '/tmp/migrate/pristine.sqlite'"
///     cp -c /tmp/migrate/pristine.sqlite /tmp/migrate/pacer.sqlite
///     PACER_MIGRATION_PROBE_STORE=/tmp/migrate/pacer.sqlite \
///     swift test --filter RealStoreLaneMigrationProbe
///
/// The copy must be on the schema before this change (a store the released
/// app wrote). It migrates the copy in place: clone a fresh one per run.
/// Run it alone, so the process's disk writes are the migration's.
///
/// What Core Data does (`-com.apple.CoreData.SQLDebug 1` shows it): an
/// `ALTER TABLE … ADD COLUMN` per new optional column, which is cheap, and a
/// `CREATE TABLE` for the new entity. But entities are numbered in name order,
/// so a new entity renumbers every entity whose name sorts after it: an
/// `UPDATE … SET Z_ENT` over each of those tables (`ZTOKENSAMPLE` among them)
/// and over the persistent-history `ACHANGE` rows that name them, plus a
/// rewrite of `ACHANGE.ZCOLUMNS` for every entity that gained a column. On a
/// real store those, not the new columns, are the cost.
///
/// Measured 2026-11-11 on a 1.4 GB four-account store (1.02M `TokenSample`
/// rows, 4.0M `ACHANGE` rows), on a busy Mac: 326 s and 867 MB written to
/// disk (1.9 GB logical). The same change with the new entity renamed to sort
/// after every existing one: 36 s and under 2 MB. The renumber is the cost.
@Suite("Real-store lane and live-meter migration probe",
       .enabled(if: ProcessInfo.processInfo.environment["PACER_MIGRATION_PROBE_STORE"] != nil))
struct RealStoreLaneMigrationProbe {

    @Test func probe() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: try #require(env["PACER_MIGRATION_PROBE_STORE"]))
        try #require(!url.path.contains("Group Containers"), "point the probe at a copy")

        let before = try Self.rowCounts(url)
        try #require(before["ZLIVEMETEROUTCOME"] == nil, "the copy is already migrated: clone a fresh one")
        let sizesBefore = Self.sizes(url)
        print("[probe] before: \(PacerStore.schemaState(at: url).rawValue), \(Self.describe(sizesBefore))")
        print("[probe] persistent history: ACHANGE \(before["ACHANGE"] ?? 0) rows, "
              + "ATRANSACTION \(before["ATRANSACTION"] ?? 0) rows")
        // Which entities this build's model and the copy's disagree on: the
        // migration's whole scope. Anything beyond the three tables gaining a
        // lane and the new one means the copy was not written by the build
        // this change sits on, and the numbers below are not this change's.
        let changed = try Self.changedEntities(url)
        print("[probe] entities that differ from the copy: \(changed.sorted().joined(separator: ", "))")
        #expect(changed == ["RateLimitSample", "UsageLimitSample", "AccountUsageArchive", "LiveMeterOutcome"])

        let io0 = Self.diskWrites()
        let (seconds, migrated, after) = try await Task.detached {
            let prepared = try PacerStore.prepareStore(at: url)
            // Decoded through SwiftData too, not only counted in SQL: an old
            // row reads back with no lane.
            let context = ModelContext(prepared.container)
            var d = FetchDescriptor<RateLimitSample>(sortBy: [SortDescriptor(\.sampledAt)])
            d.fetchLimit = 50
            let lanes = try context.fetch(d).map(\.laneId)
            #expect(lanes.count == 50 && lanes.allSatisfy { $0 == nil })
            return (prepared.seconds, prepared.migrated, prepared.after)
        }.value
        let io1 = Self.diskWrites()
        let sizesOpen = Self.sizes(url)
        print(String(format: "[probe] prepareStore: %.2f s, migrated: %@, now %@",
                     seconds, migrated ? "yes" : "no", after.rawValue))
        print("[probe] disk written by the process during the migration: "
              + "\(Self.mb(io1.physical - io0.physical)) physical, \(Self.mb(io1.logical - io0.logical)) logical")
        print("[probe] after, container open: \(Self.describe(sizesOpen))")
        #expect(migrated)
        #expect(after == .current)

        // The container is gone with the task: the files as the next launch
        // finds them.
        let sizesClosed = Self.sizes(url)
        print("[probe] after, container released: \(Self.describe(sizesClosed))")
        let reopened = Date()
        _ = try PacerStore.makeModelContainer(at: url)
        print(String(format: "[probe] ordinary open after it: %.2f s", Date().timeIntervalSince(reopened)))

        // Nothing lost: every table that was there has the rows it had.
        let afterCounts = try Self.rowCounts(url)
        for (table, count) in before.sorted(by: { $0.key < $1.key }) where Self.isEntityTable(table) {
            #expect(afterCounts[table] == count, "\(table): \(count) before, \(afterCounts[table] ?? -1) after")
        }
        print("[probe] rows: " + ["ZRATELIMITSAMPLE", "ZUSAGELIMITSAMPLE", "ZACCOUNTUSAGEARCHIVE", "ZTOKENSAMPLE"]
            .map { "\($0) \(afterCounts[$0] ?? -1)" }.joined(separator: ", "))

        // The new columns are there and empty: nothing is backfilled.
        for table in ["ZRATELIMITSAMPLE", "ZUSAGELIMITSAMPLE", "ZACCOUNTUSAGEARCHIVE"] {
            #expect(try Self.columns(url, table).contains("ZLANEID"), "\(table) has no ZLANEID")
            #expect(try Self.scalar(url, "SELECT COUNT(*) FROM \(table) WHERE ZLANEID IS NOT NULL") == 0)
        }
        // The new table, empty, with the index it declares: a table created
        // new gets its `#Index` (`StoreIndexRepair` exists for the ones that
        // do not).
        #expect(afterCounts["ZLIVEMETEROUTCOME"] == 0)
        let indexes = try Self.scalar(url, """
            SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZLIVEMETEROUTCOME'
              AND sql IS NOT NULL
            """)
        print("[probe] ZLIVEMETEROUTCOME indexes: \(indexes)")
        #expect(indexes >= 1)
        #expect(try Self.text(url, "PRAGMA quick_check") == "ok")
    }

    /// Entities whose version hash in this build's model differs from the
    /// store's metadata, or that only one side has.
    private static func changedEntities(_ url: URL) throws -> Set<String> {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: PacerStore.allModelTypes))
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        let stored = metadata[NSStoreModelVersionHashesKey] as? [String: Data] ?? [:]
        let current = model.entityVersionHashesByName
        return Set(stored.keys).union(current.keys).filter { stored[$0] != current[$0] }
    }

    // MARK: - SQLite, reads only

    /// Every table's row count.
    private static func rowCounts(_ url: URL) throws -> [String: Int] {
        let tables = try strings(url, "SELECT name FROM sqlite_master WHERE type = 'table'")
        var out: [String: Int] = [:]
        for t in tables { out[t] = try scalar(url, "SELECT COUNT(*) FROM \"\(t)\"") }
        return out
    }

    /// The tables SwiftData keeps rows in. `Z_METADATA`, `Z_MODELCACHE` and
    /// `Z_PRIMARYKEY` are its bookkeeping, which a migration rewrites.
    private static func isEntityTable(_ name: String) -> Bool {
        name.hasPrefix("Z") && !name.hasPrefix("Z_")
    }

    private static func columns(_ url: URL, _ table: String) throws -> [String] {
        try strings(url, "SELECT name FROM pragma_table_info('\(table)')")
    }

    private static func scalar(_ url: URL, _ sql: String) throws -> Int {
        Int(try text(url, sql) ?? "") ?? -1
    }

    private static func text(_ url: URL, _ sql: String) throws -> String? {
        try strings(url, sql).first
    }

    private static func strings(_ url: URL, _ sql: String) throws -> [String] {
        var db: OpaquePointer?
        // Read-write only so SQLite may create the WAL index a WAL store needs
        // to be read at all: a fresh clone has no `-shm`, and a read-only
        // open cannot make one. Nothing here writes.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw ProbeError.open
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ProbeError.query(sql) }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
        }
        return out
    }

    private enum ProbeError: Error { case open, query(String) }

    // MARK: - Files and disk writes

    private static func sizes(_ url: URL) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
            out[suffix.isEmpty ? "sqlite" : String(suffix.dropFirst())] = size ?? 0
        }
        return out
    }

    private static func describe(_ sizes: [String: Int64]) -> String {
        ["sqlite", "wal", "shm"].map { "\($0) \(mb(UInt64(sizes[$0] ?? 0)))" }.joined(separator: ", ")
    }

    private static func mb(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// This process's bytes written to disk so far: `ri_diskio_byteswritten`
    /// (what reached the device) and `ri_logical_writes` (what it asked for,
    /// cached or not).
    private static func diskWrites() -> (physical: UInt64, logical: UInt64) {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? (info.ri_diskio_byteswritten, info.ri_logical_writes) : (0, 0)
    }
}
