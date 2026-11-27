#if canImport(CDuckDB)
import CDuckDB
import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The archive kept equal to the store (#433).
///
/// The store rewrites a row in place: a streamed message when its finished
/// copy arrives (more output), and since 0.8.0 a finished one when a full
/// re-read brings pricing detail the row predates (EQUAL output; input and
/// cache change). The reconcile compared output only, so the second kind was
/// never re-archived, and one Mac's hourly check failed on every check from
/// 0.8.2 on. It now compares every field the store rewrites, and the
/// duplicate collapse keeps the copy the reconcile appended.
///
/// Every number below is written out by hand. `RawArchive` and `ArchiveSync`
/// live in the app target, beside DuckDB, so this runs where DuckDB is linked:
/// `bin/dev-ingest-parity.sh --fixtures` (CI's app job).
///
/// Serialized: the integrity check counts into the process-wide
/// `TelemetryCounters`, which one test reads.
@Suite("Raw archive reconcile", .serialized)
struct RawArchiveReconcileTests {

    static let opus = "claude-opus-5-5"

    /// Noon yesterday: a whole day before today, which the integrity check
    /// compares, and inside the reconcile's 30-day window.
    static let yesterdayNoon: Date = {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.date(byAdding: .hour, value: -12, to: today)!
    }()
    static let yesterday = TokenSample.formatDate(yesterdayNoon)

    static func tempURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-reconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("raw-archive.duckdb")
    }

    static func breakdown(_ input: Int64, _ output: Int64, _ cacheRead: Int64,
                          _ cc5m: Int64, _ cc1h: Int64) -> TokenBreakdown {
        TokenBreakdown(inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
                       cacheCreation5mTokens: cc5m, cacheCreation1hTokens: cc1h)
    }

    static func row(_ key: String, _ b: TokenBreakdown, at: Date = yesterdayNoon,
                    account: String? = nil, speed: String? = nil, geo: String? = nil) -> ArchiveRow {
        ArchiveRow(
            sampledAt: at, date: TokenSample.formatDate(at), localHour: 12, model: opus,
            breakdown: b, sourceCostUSD: nil, dedupKey: key, sessionId: "s",
            originalProjectPath: "/tmp/p", ccVersion: "2.1.1", accountId: account,
            speed: speed, inferenceGeo: geo)
    }

    static func sample(_ key: String, _ b: TokenBreakdown, at: Date = yesterdayNoon,
                       cost: Double? = nil) -> TokenSample {
        TokenSample(
            sampledAt: at, date: TokenSample.formatDate(at), model: opus,
            inputTokens: b.inputTokens, outputTokens: b.outputTokens,
            cacheReadTokens: b.cacheReadTokens, cacheCreation5mTokens: b.cacheCreation5mTokens,
            cacheCreation1hTokens: b.cacheCreation1hTokens, sourceCostUSD: cost, dedupKey: key,
            sessionId: "s", projectPath: "/tmp/p", ccVersion: "2.1.1")
    }

    /// The one archived copy of `key`, read back.
    static func archived(_ key: String, at url: URL) throws -> [ArchiveRow] {
        let archive = try RawArchive(url: url)
        return try archive.turns(onDate: yesterday).filter { $0.dedupKey == key }
    }

    /// One `syncNewTurns` with a fresh sync, as a launch does: its throttles
    /// start clear, so the reconcile and the integrity check both run. The
    /// sync, and the archive it holds open, are gone when this returns, so
    /// the test can open the file itself (DuckDB must not have it open twice
    /// in one process).
    @ScanActor
    static func pass(_ container: ModelContainer, _ url: URL) -> ArchiveSync.ReconcileCounts? {
        let sync = ArchiveSync(container: container, archiveURL: url)
        sync.syncNewTurns()
        return sync.lastReconcile
    }

    static func verdict(_ container: ModelContainer) throws -> String? {
        let key = ClaudeCodeMetaKey.archiveIntegrity
        return try ModelContext(container).fetch(FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key })).first?.value
    }

    // MARK: - The collapse

    @Test("at equal output the collapse keeps the copy appended last")
    func equalOutputLatestAppendWins() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let archive = try RawArchive(url: url)
        // The turn as first archived, then as the store holds it after a
        // re-read patched it: same output, input and cache rewritten.
        try archive.append([Self.row("m1:r1", Self.breakdown(100, 300, 5_000, 200, 0))])
        try archive.append([Self.row("m2:r2", Self.breakdown(7, 70, 700, 0, 0))])
        try archive.append([Self.row("m1:r1", Self.breakdown(120, 300, 4_000, 0, 200))])

        #expect(try archive.collapseDuplicates() == 1)
        let kept = try archive.turns(onDate: Self.yesterday).filter { $0.dedupKey == "m1:r1" }
        #expect(kept.count == 1)
        #expect(kept.first?.breakdown == Self.breakdown(120, 300, 4_000, 0, 200))
        // 120 + 7, 300 + 70, 4,000 + 700, 0 + 0, 200 + 0.
        let t = try archive.totals()
        #expect(t == RawArchive.Totals(rows: 2, input: 127, output: 370,
                                       cacheRead: 4_700, cc5m: 0, cc1h: 200))
    }

    @Test("a streamed partial never beats its finished copy, appended before or after it")
    func finishedCopyWinsWhicheverCameLast() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let archive = try RawArchive(url: url)
        // Partial first (the usual order), and finished first (a partial
        // appended after its finished copy: latest-append must not win).
        try archive.append([Self.row("m1:r1", Self.breakdown(10, 1, 900, 0, 0))])
        try archive.append([Self.row("m1:r1", Self.breakdown(10, 289, 900, 0, 0))])
        try archive.append([Self.row("m2:r2", Self.breakdown(20, 412, 800, 0, 0))])
        try archive.append([Self.row("m2:r2", Self.breakdown(20, 3, 800, 0, 0))])

        #expect(try archive.collapseDuplicates() == 2)
        let rows = try archive.turns(onDate: Self.yesterday)
        #expect(rows.count == 2)
        #expect(rows.first { $0.dedupKey == "m1:r1" }?.breakdown.outputTokens == 289)
        #expect(rows.first { $0.dedupKey == "m2:r2" }?.breakdown.outputTokens == 412)
    }

    @Test("the reconcile compares against the copy the collapse keeps")
    func reconcileViewAgreesWithCollapse() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let archive = try RawArchive(url: url)
        let stale = Self.breakdown(100, 289, 5_000, 0, 0)
        let fresh = Self.breakdown(120, 289, 4_000, 0, 0)
        try archive.append([Self.row("m1:r1", stale)])
        try archive.append([Self.row("m1:r1", fresh)])
        try archive.append([Self.row("m1:r1", Self.breakdown(120, 1, 4_000, 0, 0))])  // late partial

        func fingerprint(_ b: TokenBreakdown) -> Int {
            ArchivedTurn.fingerprint(
                input: b.inputTokens, cacheRead: b.cacheReadTokens, cc5m: b.cacheCreation5mTokens,
                cc1h: b.cacheCreation1hTokens, sourceCostUSD: nil,
                sampledAtMicros: ArchiveRow.micros(Self.yesterdayNoon), speed: nil, inferenceGeo: nil)
        }
        let before = try #require(try archive.reconcileView(since: nil)["m1:r1"])
        #expect(before.outputTokens == 289)
        #expect(before.fingerprint == fingerprint(fresh))
        #expect(before.fingerprint != fingerprint(stale))

        #expect(try archive.collapseDuplicates() == 2)
        let after = try #require(try archive.reconcileView(since: nil)["m1:r1"])
        #expect(after.outputTokens == 289 && after.fingerprint == before.fingerprint)
    }

    @Test("the reconcile view keeps the later append across its read pages")
    func reconcileViewAcrossPages() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let archive = try RawArchive(url: url)
        let stale = Self.breakdown(100, 289, 5_000, 0, 0)
        let fresh = Self.breakdown(120, 289, 4_000, 0, 0)
        // Each turn's first copy on the first page, its second on the next.
        var rows = [Self.row("m1:r1", stale), Self.row("m2:r2", Self.breakdown(10, 412, 800, 0, 0))]
        for i in 0..<Int(RawArchive.reconcilePageRows) {
            rows.append(Self.row("f\(i)", Self.breakdown(1, 1, 1, 0, 0)))
        }
        rows.append(Self.row("m1:r1", fresh))
        rows.append(Self.row("m2:r2", Self.breakdown(10, 3, 800, 0, 0)))   // late partial
        try archive.append(rows)

        let view = try archive.reconcileView(since: nil)
        #expect(view.count == Int(RawArchive.reconcilePageRows) + 2)
        let fingerprint = ArchivedTurn.fingerprint(
            input: 120, cacheRead: 4_000, cc5m: 0, cc1h: 0, sourceCostUSD: nil,
            sampledAtMicros: ArchiveRow.micros(Self.yesterdayNoon), speed: nil, inferenceGeo: nil)
        #expect(view["m1:r1"]?.fingerprint == fingerprint)
        #expect(view["m2:r2"]?.outputTokens == 412)
    }

    /// The collapse's tie-break is `rowid DESC`, so it needs rowid to follow
    /// append order on the vendored engine, including after a checkpoint has
    /// compacted the row groups a collapse thinned out, which renumbers rows.
    @Test("rowid keeps append order across a compacting checkpoint")
    func rowidKeepsAppendOrderAcrossCompaction() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Three row groups (122,880 rows each) of filler, with the turn's
        // stale copy near the end.
        do {
            let archive = try RawArchive(url: url)
            var rows: [ArchiveRow] = []
            for i in 0..<300_000 {
                rows.append(Self.row("f\(i)", Self.breakdown(1, 1, 1, 0, 0)))
                if i == 299_000 { rows.append(Self.row("m1:r1", Self.breakdown(100, 300, 5_000, 0, 0))) }
            }
            try archive.append(rows)
        }
        // Delete 90% of the filler, checkpoint, and look at the stale copy's
        // rowid on each side of it.
        var db: duckdb_database?
        var con: duckdb_connection?
        #expect(url.path.withCString { duckdb_open($0, &db) } == DuckDBSuccess)
        #expect(duckdb_connect(db, &con) == DuckDBSuccess)
        func scalar(_ sql: String) -> Int64 {
            var result = duckdb_result()
            #expect(sql.withCString { duckdb_query(con, $0, &result) } == DuckDBSuccess)
            defer { duckdb_destroy_result(&result) }
            return duckdb_value_int64(&result, 0, 0)
        }
        let rowidBefore = scalar("SELECT rowid FROM turn WHERE dedup_key = 'm1:r1'")
        _ = scalar("""
            DELETE FROM turn WHERE dedup_key LIKE 'f%'
              AND CAST(substr(dedup_key, 2) AS INTEGER) % 10 <> 0
            """)
        _ = scalar("CHECKPOINT")
        let rowidAfter = scalar("SELECT rowid FROM turn WHERE dedup_key = 'm1:r1'")
        let outOfOrder = scalar("""
            SELECT COUNT(*) FROM (
                SELECT CAST(substr(dedup_key, 2) AS INTEGER) AS i,
                       lag(CAST(substr(dedup_key, 2) AS INTEGER)) OVER (ORDER BY rowid) AS prev
                FROM turn WHERE dedup_key LIKE 'f%')
            WHERE prev > i
            """)
        duckdb_disconnect(&con)
        duckdb_close(&db)
        // The checkpoint did renumber (otherwise this tests nothing: if a
        // DuckDB upgrade stops compacting, thin the filler differently), and
        // kept the order.
        #expect(rowidAfter < rowidBefore)
        #expect(outOfOrder == 0)

        let archive = try RawArchive(url: url)
        try archive.append([Self.row("m1:r1", Self.breakdown(120, 300, 4_000, 0, 200))])
        #expect(try archive.collapseDuplicates() == 1)
        let kept = try archive.turns(onDate: Self.yesterday).filter { $0.dedupKey == "m1:r1" }
        #expect(kept.map(\.breakdown) == [Self.breakdown(120, 300, 4_000, 0, 200)])
    }

    // MARK: - The reconcile, end to end

    @ScanActor
    @Test("a row rewritten at equal output is re-archived, and the check that failed passes")
    func rewriteAtEqualOutputConverges() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        let patched = Self.sample("m1:r1", Self.breakdown(100, 300, 5_000, 200, 0))
        context.insert(patched)
        context.insert(Self.sample("m2:r2", Self.breakdown(7, 70, 700, 0, 0)))
        // The store's rollup, as the recomputer leaves it: 100 + 7, 300 + 70,
        // 5,000 + 700, 200 + 0, 0 + 0, two turns.
        let hourly = HourlyAggregate(
            date: Self.yesterday, hour: 12, model: Self.opus, inputTokens: 107,
            outputTokens: 370, cacheReadTokens: 5_700, cacheCreation5mTokens: 200,
            cacheCreation1hTokens: 0, sampleCount: 2)
        context.insert(hourly)
        try context.save()

        // First launch: both turns archived by the forward path.
        #expect(Self.pass(container, url) == ArchiveSync.ReconcileCounts())
        #expect(try Self.verdict(container)?.hasPrefix("ok|") == true)

        // A full re-read patches m1:r1 (`SamplePersister.apply`): same output,
        // input and cache rewritten. The rollup follows: 120 + 7, 4,000 + 700,
        // 0 + 0, 200 + 0.
        patched.inputTokens = 120
        patched.cacheReadTokens = 4_000
        patched.cacheCreation5mTokens = 0
        patched.cacheCreation1hTokens = 200
        hourly.inputTokens = 127
        hourly.cacheReadTokens = 4_700
        hourly.cacheCreation5mTokens = 0
        hourly.cacheCreation1hTokens = 200
        try context.save()

        var counts = ArchiveSync.ReconcileCounts()
        counts.patched = 1
        #expect(Self.pass(container, url) == counts)
        // Re-appended and collapsed to the store's copy, before the check ran.
        #expect(try Self.archived("m1:r1", at: url).map(\.breakdown)
                == [Self.breakdown(120, 300, 4_000, 0, 200)])
        let verdict = try #require(try Self.verdict(container))
        #expect(verdict.hasPrefix("ok|"))
        #expect(verdict.contains("|checks=2|mismatches=0"))

        // Converged: nothing differs, so nothing is appended.
        #expect(Self.pass(container, url) == ArchiveSync.ReconcileCounts())
        #expect(try RawArchive(url: url).totals() == RawArchive.Totals(
            rows: 2, input: 127, output: 370, cacheRead: 4_700, cc5m: 0, cc1h: 200))
    }

    @ScanActor
    @Test("a source cost rewritten at equal tokens is re-archived")
    func sourceCostIsCompared() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        // Claude Code's own `costUSD`, stored as `sourceCostUSD`; a re-read
        // that patches the row rewrites it with the tokens unchanged.
        let turn = Self.sample("m1:r1", Self.breakdown(10, 20, 30, 0, 0), cost: 0.5)
        context.insert(turn)
        context.insert(Self.sample("m2:r2", Self.breakdown(40, 50, 60, 0, 0), cost: 0.25))
        try context.save()
        #expect(Self.pass(container, url) == ArchiveSync.ReconcileCounts())
        #expect(try Self.archived("m1:r1", at: url).map(\.sourceCostUSD) == [0.5])

        turn.sourceCostUSD = 0.75
        try context.save()

        var counts = ArchiveSync.ReconcileCounts()
        counts.patched = 1
        #expect(Self.pass(container, url) == counts)
        #expect(try Self.archived("m1:r1", at: url).map(\.sourceCostUSD) == [0.75])
        #expect(try Self.archived("m2:r2", at: url).map(\.sourceCostUSD) == [0.25])
        #expect(Self.pass(container, url) == ArchiveSync.ReconcileCounts())
    }

    @ScanActor
    @Test("a streamed partial is still superseded by its finished copy")
    func streamedPartialIsUpgraded() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        let streamed = Self.sample("m1:r1", Self.breakdown(10, 1, 900, 0, 0))
        context.insert(streamed)
        try context.save()
        #expect(Self.pass(container, url) == ArchiveSync.ReconcileCounts())

        // The finished copy arrived; the store upgraded the row in place.
        streamed.outputTokens = 289
        try context.save()

        var counts = ArchiveSync.ReconcileCounts()
        counts.upgraded = 1
        #expect(Self.pass(container, url) == counts)
        #expect(try Self.archived("m1:r1", at: url).map(\.breakdown)
                == [Self.breakdown(10, 289, 900, 0, 0)])
        #expect(Self.pass(container, url) == ArchiveSync.ReconcileCounts())
    }

    @ScanActor
    @Test("an identical row is not re-appended, and a speed the archive never recorded is not a difference")
    func identicalRowsStay() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Archived before the store had them: one turn from before #352
        // (speed and region NULL, "not recorded"), one recorded as standard.
        do {
            let archive = try RawArchive(url: url)
            try archive.append([
                Self.row("old:r1", Self.breakdown(10, 20, 30, 0, 0)),
                Self.row("new:r2", Self.breakdown(40, 50, 60, 0, 0), speed: "standard", geo: "global"),
                Self.row("same:r3", Self.breakdown(70, 80, 90, 0, 0), speed: "standard", geo: "global"),
            ])
        }
        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        let old = Self.sample("old:r1", Self.breakdown(10, 20, 30, 0, 0))
        old.speed = "fast"
        old.inferenceGeo = "us"
        let new = Self.sample("new:r2", Self.breakdown(40, 50, 60, 0, 0))
        new.speed = "fast"   // patched since: standard -> fast
        new.inferenceGeo = "global"
        let same = Self.sample("same:r3", Self.breakdown(70, 80, 90, 0, 0))
        same.speed = "standard"
        same.inferenceGeo = "global"
        for s in [old, new, same] { context.insert(s) }
        try context.save()

        // Only the recorded speed that changed is re-archived.
        var counts = ArchiveSync.ReconcileCounts()
        counts.patched = 1
        #expect(Self.pass(container, url) == counts)
        #expect(try Self.archived("new:r2", at: url).map(\.speed) == ["fast"])
        #expect(try Self.archived("old:r1", at: url).map(\.speed) == [nil])
        #expect(try RawArchive(url: url).totals().rows == 3)
        #expect(Self.pass(container, url) == ArchiveSync.ReconcileCounts())
        #expect(try RawArchive(url: url).totals().rows == 3)
    }

    @ScanActor
    @Test("beside an account, a NULL speed or region is a recorded nil")
    func attributedNullIsRecorded() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Archived since #352 with an account and no speed or region, then
        // patched in the store to fast / us. And the same turn shape without
        // an account, which can't be told from a row archived before #352.
        do {
            let archive = try RawArchive(url: url)
            try archive.append([
                Self.row("acct:r1", Self.breakdown(10, 20, 30, 0, 0), account: "acct-a"),
                Self.row("acct:r2", Self.breakdown(10, 20, 30, 0, 0), account: "acct-a"),
                Self.row("none:r3", Self.breakdown(10, 20, 30, 0, 0)),
            ])
        }
        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        let fast = Self.sample("acct:r1", Self.breakdown(10, 20, 30, 0, 0))
        fast.speed = "fast"
        let us = Self.sample("acct:r2", Self.breakdown(10, 20, 30, 0, 0))
        us.inferenceGeo = "us"
        let unattributed = Self.sample("none:r3", Self.breakdown(10, 20, 30, 0, 0))
        unattributed.speed = "fast"
        for s in [fast, us, unattributed] { context.insert(s) }
        try context.save()

        var counts = ArchiveSync.ReconcileCounts()
        counts.patched = 2
        #expect(Self.pass(container, url) == counts)
        #expect(try Self.archived("acct:r1", at: url).map(\.speed) == ["fast"])
        #expect(try Self.archived("acct:r2", at: url).map(\.inferenceGeo) == ["us"])
        #expect(try Self.archived("none:r3", at: url).map(\.speed) == [nil])
        #expect(Self.pass(container, url) == ArchiveSync.ReconcileCounts())
    }

    @ScanActor
    @Test("a copy that differs only in when it was sampled follows the store")
    func sampledAtIsCompared() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Residue of a store duplicate: the archive kept the copy sampled a
        // second later than the one `repairDuplicateSamples` kept. The
        // collapse no longer breaks ties on `sampled_at`, so the reconcile
        // has to see this one.
        let stored = Self.yesterdayNoon
        do {
            let archive = try RawArchive(url: url)
            try archive.append([Self.row("m1:r1", Self.breakdown(10, 20, 30, 0, 0),
                                         at: stored.addingTimeInterval(1))])
        }
        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Self.sample("m1:r1", Self.breakdown(10, 20, 30, 0, 0), at: stored))
        try context.save()

        var counts = ArchiveSync.ReconcileCounts()
        counts.patched = 1
        #expect(Self.pass(container, url) == counts)
        #expect(try Self.archived("m1:r1", at: url).map(\.sampledAt) == [stored])
        #expect(Self.pass(container, url) == ArchiveSync.ReconcileCounts())
    }

    /// A turn an hour after the others, in both stores: the archive's
    /// newest, so the forward path's watermark is past the duplicates below,
    /// as it is on a real store (duplicates are old residue). Without it a
    /// fresh sync's watermark, read back from the archive, can sit between
    /// two copies and archive the later one again as new.
    static let later = (key: "m9:r9", breakdown: breakdown(5, 6, 7, 0, 0),
                        at: yesterdayNoon.addingTimeInterval(3_600))

    @ScanActor
    @Test("a store duplicate at equal output settles on the copy the store's repair keeps")
    func storeDuplicateSettles() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // One key stored twice (residue `repairDuplicateSamples` removes):
        // equal output, a second apart, input differing. The repair keeps
        // the earlier one.
        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = Self.yesterdayNoon
        context.insert(Self.sample("m1:r1", Self.breakdown(10, 20, 30, 0, 0), at: first))
        context.insert(Self.sample("m1:r1", Self.breakdown(11, 20, 30, 0, 0),
                                   at: first.addingTimeInterval(1)))
        context.insert(Self.sample(Self.later.key, Self.later.breakdown, at: Self.later.at))
        try context.save()

        // The forward path archives all three; the next launch's collapse
        // keeps the later append of m1:r1, the copy the repair would drop.
        // Comparing both store rows re-appended whichever differed from the
        // archive's copy, every pass (0, 1, 1, 1 ...). Now the earlier row is
        // re-archived once, and the later one is never compared again.
        var re: [Int] = []
        var superseded: [Int] = []
        for _ in 0..<5 {
            let counts = try #require(Self.pass(container, url))
            re.append(counts.reappended)
            superseded.append(counts.superseded)
        }
        #expect(re == [0, 1, 0, 0, 0])
        #expect(superseded == [0, 1, 1, 1, 1])
        // The marks live in the byte that was already there: an entry of the
        // full reconcile's map is still 24 bytes.
        #expect(MemoryLayout<ArchivedTurn>.stride == 24)
        #expect(MemoryLayout<ArchivedTurn.Recorded>.size == 1)
        #expect(try Self.archived("m1:r1", at: url).map(\.breakdown.inputTokens) == [10])
    }

    @ScanActor
    @Test("a later store duplicate with more output is still an upgrade")
    func laterDuplicateWithMoreOutputUpgrades() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Archived partial; the store then holds the partial and, a second
        // later, the finished copy under the same key. The repair keeps the
        // finished one (largest output first), so the archive must too,
        // although the partial row reaches the archived output first.
        do {
            let archive = try RawArchive(url: url)
            try archive.append([
                Self.row("m1:r1", Self.breakdown(10, 1, 30, 0, 0)),
                Self.row(Self.later.key, Self.later.breakdown, at: Self.later.at),
            ])
        }
        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Self.sample("m1:r1", Self.breakdown(10, 1, 30, 0, 0)))
        context.insert(Self.sample("m1:r1", Self.breakdown(10, 289, 30, 0, 0),
                                   at: Self.yesterdayNoon.addingTimeInterval(1)))
        context.insert(Self.sample(Self.later.key, Self.later.breakdown, at: Self.later.at))
        try context.save()

        var counts = ArchiveSync.ReconcileCounts()
        counts.upgraded = 1
        #expect(Self.pass(container, url) == counts)
        #expect(try Self.archived("m1:r1", at: url).map(\.breakdown.outputTokens) == [289])
        // Settled: the partial row is behind the archive and the finished one
        // matches it, so the turn is not `ahead` either.
        #expect(Self.pass(container, url) == ArchiveSync.ReconcileCounts())
    }

    @ScanActor
    @Test("an archive holding more output than the store is counted, not re-appended, and the check names each field")
    func archiveAheadIsCountedAndNamed() throws {
        let url = try Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let archive = try RawArchive(url: url)
            try archive.append([Self.row("m1:r1", Self.breakdown(100, 500, 1_000, 40, 3))])
        }
        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Self.sample("m1:r1", Self.breakdown(90, 300, 1_000, 40, 8)))
        context.insert(HourlyAggregate(
            date: Self.yesterday, hour: 12, model: Self.opus, inputTokens: 90,
            outputTokens: 300, cacheReadTokens: 1_000, cacheCreation5mTokens: 40,
            cacheCreation1hTokens: 8, sampleCount: 1))
        try context.save()

        let watched = [
            "data.archive_integrity.rows.equal",
            "data.archive_integrity.output.over.e2",      // 500 - 300 = 200
            "data.archive_integrity.input.over.e1",       // 100 - 90 = 10
            "data.archive_integrity.cache_read.equal",
            "data.archive_integrity.cc5m.equal",
            "data.archive_integrity.cc1h.under.e0",       // 8 - 3 = 5
            "data.archive_integrity.mismatch",
        ]
        let before = TelemetryCounters.peek()

        var counts = ArchiveSync.ReconcileCounts()
        counts.ahead = 1
        #expect(Self.pass(container, url) == counts)
        #expect(try Self.archived("m1:r1", at: url).map(\.breakdown)
                == [Self.breakdown(100, 500, 1_000, 40, 3)])

        let after = TelemetryCounters.peek()
        for key in watched {
            #expect((after[key] ?? 0) - (before[key] ?? 0) == 1, "\(key)")
        }
        let verdict = try #require(try Self.verdict(container))
        #expect(verdict.hasPrefix("mismatch|"))
        #expect(verdict.contains("rows 1/1 out 500/300 in 100/90 cc1h 3/8"))
    }
}
#endif
