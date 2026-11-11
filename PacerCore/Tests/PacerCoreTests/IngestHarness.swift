import Darwin
import Foundation
import SQLite3
import SwiftData
import Testing
@testable import PacerCore

/// AGENTS.md rule 8 for branch work (#323): run the real ingest against real
/// data, in this test process, with no app launch and no window.
///
/// `PACER_COLD_START_PROBE` answers the same question for the INSTALLED app,
/// but it launches the app binary, and a second process of the bundle on the
/// owner's Mac is how windows flashed on his screen (2026-10-21). This runs the
/// same coordinator, configuration shape and priority from `swift test`, so a
/// branch can be checked from any worktree.
///
/// Two inputs, either or both:
///
/// - `PACER_INGEST_CLAUDE_DIR`: a frozen `CLAUDE_CONFIG_DIR` (a directory
///   holding `projects/`, e.g. `cp -c -R ~/.claude/projects <dir>/`). Unset,
///   the scan reads an empty root: a store-only run.
/// - `PACER_INGEST_STORE`: a COPY of a real store (`bin/dev-ingest-harness.sh`
///   says how to take one while the app writes it). It is opened, and
///   migrated if this build's schema differs, then given the first scan cycle
///   a new build's first launch runs. The run WRITES the copy; clone a fresh
///   one per run (the script does). Unset, the store is a new empty file in a
///   temporary folder: a first install, which is what the cold-start probe
///   measures (in memory there, on disk here so its writes are real).
///
/// With both, the copy's file cursors are first moved from `~/.claude` (or
/// `PACER_INGEST_CURSOR_ROOT`) onto the frozen tree, so the cycle reads what a
/// relaunch would: only what was written after the copy was made. Without
/// that, every frozen file is new to the store and the "relaunch" re-reads all
/// of history. `PACER_INGEST_KEEP_CURSORS=1` skips it.
///
/// It prints, in this order, with each phase's wall time and the bytes this
/// process wrote during it (`ri_logical_writes`, what the kernel's
/// 2 GiB-a-day disk-write limit counts and MetricKit reports as an
/// `MXDiskWriteException`, #387; and `ri_diskio_byteswritten`), the WAL's peak
/// size and the store's size after:
///
///   open       `PacerStore.prepareStore`: the schema migration, if any
///   index      `StoreIndexRepair.run` (launch, store runs only)
///   prune      `StoreMaintenance.pruneHistory` (launch, store runs only)
///   cycle      `ScanCoordinator.runOnce()`, split by its own phase timings
///   archive    `ArchiveSync.syncNewTurns()` into a copy of the DuckDB
///              archive (`PACER_INGEST_ARCHIVE`), in the DuckDB build only
///
/// then the cold-start probe's TOTALS line, character for character (rows and
/// the five token fields with both cache-write tiers apart, and their sum), the
/// thinking-token sum, and the cost the daily rollup holds, in total and per
/// model. Run against the same frozen tree with `PACER_COLD_START_DESKTOP_DIRS=`
/// (empty) on the cold-start probe, the two TOTALS lines must be equal.
///
/// Options: `PACER_INGEST_CATALOG` (a LiteLLM catalog copy; default the
/// bundled snapshot, so two runs price alike), `PACER_INGEST_DESKTOP_DIRS`
/// (frozen Claude Desktop data folders, comma-separated; default none),
/// `PACER_INGEST_FORCE_RESCAN=1` / `PACER_INGEST_FORCE_REBUILD=1` (drop the
/// stored `scanVersion` / `costRecomputeVersion` first: a release that bumps
/// one), `PACER_INGEST_STEADY_CYCLES=<n>` (incremental cycles after the
/// first), `PACER_INGEST_OUT=<dir>` (phases.tsv and a 50 ms writes timeline),
/// `PACER_INGEST_SAVE_BATCH=<n>` (inserts per save, to compare against the
/// default), `PACER_INGEST_PRIORITY=userInitiated` (the cycle runs at the scan loop's
/// `.utility` otherwise, which a machine busy with builds starves for minutes;
/// bytes and totals do not depend on it, timings do).
///
/// Run it through `make ingest-harness`, which builds it beside the app's DuckDB
/// importer so a full scan takes the path users are on. Plain
/// `swift test --filter IngestHarness` works too, through the line parser.
@Suite("Ingest harness", .enabled(if: ingestHarnessIsEnabled), .serialized)
struct IngestHarness {

    /// The process environment without its empty values: `make` passes every
    /// variable whether it was given or not.
    static var env: [String: String] { ProcessInfo.processInfo.environment.filter { !$0.value.isEmpty } }


    #if canImport(CDuckDB)
    static func bulkImporter() -> BulkTranscriptImporter? { ArchiveImporter() }
    #else
    static func bulkImporter() -> BulkTranscriptImporter? { nil }
    #endif

    func log(_ s: String) { print("[ingest] \(s)") }

    @ScanActor
    @Test func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let env = Self.env
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("pacer-ingest-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // The store: a copy the caller made, or a new one. Never the live file,
        // however its path is spelled.
        let storeURL: URL
        if let path = env["PACER_INGEST_STORE"] {
            storeURL = URL(fileURLWithPath: path)
            let resolved = storeURL.resolvingSymlinksInPath().path
            try #require(!resolved.contains("/Group Containers/"), "point the harness at a copy")
            if let live = try? PacerStore.storeURL() {
                try #require(resolved != live.resolvingSymlinksInPath().path, "point the harness at a copy")
            }
            try #require(fm.fileExists(atPath: storeURL.path), "no store at \(storeURL.path)")
        } else {
            storeURL = scratch.appendingPathComponent("pacer.sqlite")
        }
        let existing = env["PACER_INGEST_STORE"] != nil
        let claudeDir: URL
        if let dir = env["PACER_INGEST_CLAUDE_DIR"] {
            claudeDir = URL(fileURLWithPath: dir)
            try #require(fm.fileExists(atPath: claudeDir.appendingPathComponent("projects").path),
                         "no projects/ under \(claudeDir.path)")
        } else {
            claudeDir = scratch.appendingPathComponent("claude")
            try fm.createDirectory(at: claudeDir.appendingPathComponent("projects"),
                                   withIntermediateDirectories: true)
        }
        let outDir = env["PACER_INGEST_OUT"].map(URL.init(fileURLWithPath:))
        if let outDir { try fm.createDirectory(at: outDir, withIntermediateDirectories: true) }

        log("store: \(existing ? "copy \(storeURL.lastPathComponent), \(Self.mb(Self.size(storeURL))) MB" : "new, empty (first install)")")
        log("transcripts: \(env["PACER_INGEST_CLAUDE_DIR"] == nil ? "none" : claudeDir.path)")
        let importer = Self.bulkImporter()
        log("ingest: \(importer == nil ? "line parser (no DuckDB in this build; make ingest-harness has it)" : "DuckDB bulk importer")")

        // Pricing from a fixed catalog and the bundled curated file, so two
        // runs (two builds) price identically whatever the network did.
        let table = PricingTable()
        try await table.ensureLoaded(cacheURL: URL(fileURLWithPath: env["PACER_INGEST_CATALOG"]
            ?? scratch.appendingPathComponent("no-catalog.json").path))
        await SampleCostCache.reload(table, curatedCacheURL: scratch.appendingPathComponent("no-curated.json"))

        if existing, env["PACER_INGEST_CLAUDE_DIR"] != nil, env["PACER_INGEST_KEEP_CURSORS"] != "1" {
            let from = (env["PACER_INGEST_CURSOR_ROOT"]
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
            let moved = try Self.rebaseCursors(store: storeURL, from: from, to: claudeDir.path)
            log("cursors: \(moved) moved from the live tree onto the frozen one")
        }

        let meter = WriteMeter(storeURL: storeURL)
        meter.start()
        var phases: [PhaseRecord] = []

        // What the app does at launch, in its order, one phase at a time.
        let prepared = try await meter.phase("open", into: &phases) {
            try await Task.detached { try PacerStore.prepareStore(at: storeURL) }.value
        }
        let container = prepared.container
        log("open: schema \(prepared.before.rawValue) → \(prepared.after.rawValue)"
            + (prepared.migrated ? " (migrated)" : ""))
        #expect(prepared.after == .current)

        if env["PACER_INGEST_FORCE_RESCAN"] == "1" || env["PACER_INGEST_FORCE_REBUILD"] == "1" {
            let ctx = ModelContext(container)
            var drop: [String] = []
            if env["PACER_INGEST_FORCE_RESCAN"] == "1" { drop.append(ClaudeCodeMetaKey.scanVersion) }
            if env["PACER_INGEST_FORCE_REBUILD"] == "1" { drop.append(ClaudeCodeMetaKey.costRecomputeVersion) }
            for key in drop {
                for row in try ctx.fetch(FetchDescriptor<ClaudeCodeMeta>(predicate: #Predicate { $0.key == key })) {
                    ctx.delete(row)
                }
            }
            try ctx.save()
            log("dropped \(drop.joined(separator: ", ")): the first cycle re-reads / rebuilds as a bump would")
        }

        if existing {
            _ = try await meter.phase("index", into: &phases) { StoreIndexRepair.run(storeURL: storeURL) }
            _ = try await meter.phase("prune", into: &phases) { StoreMaintenance.pruneHistory(container: container) }
        }

        // A home of its own, so nothing reads the developer's logins.
        let home = scratch.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let desktopDirs = (env["PACER_INGEST_DESKTOP_DIRS"] ?? "")
            .split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .auto, watcherMode: .manual, probeStatsCache: false,
                                 saveBatchSize: Int(env["PACER_INGEST_SAVE_BATCH"] ?? "")
                                     ?? ScanCoordinator.Configuration().saveBatchSize,
                                 bulkImporter: importer,
                                 desktopSessions: DesktopSessionDirectory(dataDirectories: desktopDirs)),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": claudeDir.path]),
            homeDirectory: home)

        let cycleStart = meter.elapsed()
        let report = try await meter.phase("cycle", into: &phases) {
            try await Self.runCycle(coordinator)
        }
        phases += meter.split(report.phaseTimings, from: cycleStart)
        let p = report.phaseTimings
        log(String(format: "cycle: %@ in %.1f s · parsed %d entries from %d files · inserted %d · upgraded %d",
                   report.wasFullScan ? "full" : "incremental", report.durationSeconds,
                   report.scanProgress.entriesParsed, report.scanProgress.filesScanned,
                   report.persisterStats.inserted, report.persisterStats.upgradedFromPartial))
        log(String(format: "  parse %.0f · cursors %.0f · daily %.0f · hourly %.0f · project %.0f · session %.0f ms",
                   p.scanMs, p.saveCursorsMs, p.dailyRecomputeMs, p.hourlyRecomputeMs,
                   p.projectRecomputeMs, p.sessionRecomputeMs))

        #if canImport(CDuckDB)
        if let archive = env["PACER_INGEST_ARCHIVE"] {
            let url = URL(fileURLWithPath: archive)
            try #require(!url.resolvingSymlinksInPath().path.contains("/Group Containers/"), "an archive copy")
            _ = try await meter.phase("archive", into: &phases) {
                ArchiveSync(container: container, archiveURL: url).syncNewTurns()
            }
        }
        #endif

        let steady = Int(env["PACER_INGEST_STEADY_CYCLES"] ?? "") ?? 0
        if steady > 0 {
            _ = try await meter.phase("steady×\(steady)", into: &phases) {
                for _ in 0..<steady { _ = try await Self.runCycle(coordinator) }
            }
        }
        meter.stop()

        for r in phases { log(r.line) }
        let all = phases.filter { !$0.name.hasPrefix("  ") }
        let logical = all.reduce(UInt64(0)) { $0 + $1.logical }
        let disk = all.reduce(UInt64(0)) { $0 + $1.disk }
        log("WRITES \(Self.mb(logical)) MB logical, \(Self.mb(disk)) MB to disk, "
            + "store now \(Self.mb(Self.size(storeURL))) MB")

        let totals = try Self.totals(storeURL)
        log(totals.line)
        log("thinking=\(totals.thinking)")
        let cost = try Self.costByModel(storeURL)
        log(String(format: "COST $%.4f (daily rollup, auto mode)", cost.reduce(0) { $0 + $1.1 }))
        for (model, usd) in cost.prefix(12) { log(String(format: "  %-34@ $%.4f", model as NSString, usd)) }

        if let outDir {
            try (["phase\tseconds\tlogical_bytes\tdisk_bytes\twal_peak_bytes\tstore_bytes_after"]
                 + phases.map(\.tsv)).joined(separator: "\n").appending("\n")
                .write(to: outDir.appendingPathComponent("phases.tsv"), atomically: true, encoding: .utf8)
            try meter.timeline().write(to: outDir.appendingPathComponent("writes-timeline.tsv"),
                                       atomically: true, encoding: .utf8)
            try "\(totals.line)\nthinking=\(totals.thinking)\n".write(
                to: outDir.appendingPathComponent("totals.txt"), atomically: true, encoding: .utf8)
        }
    }

    static var cyclePriority: TaskPriority {
        env["PACER_INGEST_PRIORITY"] == "userInitiated" ? .userInitiated : ScanCoordinator.loopPriority
    }

    /// One cycle at the scan loop's priority, never escalated by the await
    /// (`RealStoreUpgradeProbe.runCycle` explains why that matters).
    @ScanActor
    static func runCycle(_ coordinator: ScanCoordinator) async throws -> ScanCoordinator.ScanReport {
        let outcome: Result<ScanCoordinator.ScanReport, Error> = await withCheckedContinuation { done in
            Task.detached(priority: cyclePriority) {
                do { done.resume(returning: .success(try await coordinator.runOnce())) }
                catch { done.resume(returning: .failure(error)) }
            }
        }
        return try outcome.get()
    }

    // MARK: - Reading the result back

    struct Totals {
        var rows: Int64 = 0
        var input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cc5m: Int64 = 0, cc1h: Int64 = 0
        var thinking: Int64 = 0
        /// `ColdStartProbe.totals`'s line, character for character, so the two
        /// can be compared with `diff`.
        var line: String {
            "TOTALS rows=\(rows) input=\(input) output=\(output) "
                + "cacheRead=\(cacheRead) cc5m=\(cc5m) cc1h=\(cc1h) "
                + "all=\(input + output + cacheRead + cc5m + cc1h)"
        }
    }

    /// Straight from the table, on a read-only connection of its own: a sum
    /// over a million rows is milliseconds in SQL, where materialising them
    /// through SwiftData holds gigabytes (#337). The column is the attribute,
    /// so this reads what SwiftData stored, tier by tier.
    static func totals(_ store: URL) throws -> Totals {
        let rows = try query(store, """
            SELECT count(*), total(ZINPUTTOKENS), total(ZOUTPUTTOKENS), total(ZCACHEREADTOKENS),
                   total(ZCACHECREATION5MTOKENS), total(ZCACHECREATION1HTOKENS), total(ZTHINKINGTOKENS)
            FROM ZTOKENSAMPLE
            """)
        guard let r = rows.first, r.count == 7 else { return Totals() }
        func n(_ i: Int) -> Int64 { Int64(r[i]) ?? Int64(Double(r[i]) ?? 0) }
        return Totals(rows: n(0), input: n(1), output: n(2), cacheRead: n(3), cc5m: n(4), cc1h: n(5),
                      thinking: n(6))
    }

    static func costByModel(_ store: URL) throws -> [(String, Double)] {
        try query(store, "SELECT ZMODEL, total(ZTOTALCOSTUSD) FROM ZDAILYAGGREGATE GROUP BY ZMODEL ORDER BY 2 DESC")
            .map { ($0[0], Double($0[1]) ?? 0) }
    }

    /// Point the copy's `JSONLFileCursor` rows at the frozen tree: the store
    /// keys a file's read offset by its path, and the frozen tree has the same
    /// files, offsets and mtimes (`cp -c` keeps them) under another root. Raw
    /// SQL on the copy before SwiftData opens it, so it costs no launch phase.
    static func rebaseCursors(store: URL, from: String, to: String) throws -> Int {
        let from = from.hasSuffix("/") ? from : from + "/"
        let to = to.hasSuffix("/") ? to : to + "/"
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "UPDATE ZJSONLFILECURSOR SET ZPATH = ?2 || substr(ZPATH, length(?1) + 1) "
            + "WHERE substr(ZPATH, 1, length(?1)) = ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, from, -1, transient)
        sqlite3_bind_text(stmt, 2, to, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        return Int(sqlite3_changes(db))
    }

    static func query(_ store: URL, _ sql: String) throws -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(stmt) }
        var out: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String] = []
            for i in 0..<sqlite3_column_count(stmt) {
                // Integer sums print exactly; `total()` returns a double
                // only when a column holds one.
                if sqlite3_column_type(stmt, i) == SQLITE_FLOAT {
                    let v = sqlite3_column_double(stmt, i)
                    row.append(v.rounded() == v && abs(v) < 9e15 ? String(Int64(v)) : String(v))
                } else {
                    row.append(sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "")
                }
            }
            out.append(row)
        }
        return out
    }

    static func size(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    static func mb(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }
}

/// Outside the suite: a `@Suite` trait can't read its own type's members.
private var ingestHarnessIsEnabled: Bool {
    IngestHarness.env["PACER_INGEST_CLAUDE_DIR"] != nil || IngestHarness.env["PACER_INGEST_STORE"] != nil
}

/// One phase's cost: wall time, bytes written, the WAL's high-water mark.
struct PhaseRecord {
    var name: String
    var seconds: Double
    var logical: UInt64
    var disk: UInt64
    var walPeak: UInt64
    var storeAfter: UInt64

    var line: String {
        String(format: "%-14@ %8.2f s  %9@ MB logical  %9@ MB disk  WAL peak %8@ MB  store %8@ MB",
               name as NSString, seconds, IngestHarness.mb(logical) as NSString,
               IngestHarness.mb(disk) as NSString, IngestHarness.mb(walPeak) as NSString,
               IngestHarness.mb(storeAfter) as NSString)
    }
    var tsv: String {
        "\(name.trimmingCharacters(in: .whitespaces))\t\(String(format: "%.3f", seconds))\t\(logical)\t\(disk)\t\(walPeak)\t\(storeAfter)"
    }
}

/// This process's write counters, read every 50 ms on a plain thread (not the
/// cooperative pool, which is busy with the work being measured), with the
/// store's WAL size beside them.
final class WriteMeter: @unchecked Sendable {
    struct Point { let t: Double; let logical: UInt64; let disk: UInt64; let wal: UInt64 }

    private let lock = NSLock()
    private var points: [Point] = []
    private var running = false
    private let origin = Date()
    private let walPath: String
    private let storeURL: URL

    init(storeURL: URL) {
        self.storeURL = storeURL
        self.walPath = storeURL.path + "-wal"
    }

    /// `ri_logical_writes` is every byte the process wrote, whether or not it
    /// has reached the disk yet: what the kernel's disk-write limit and
    /// MetricKit count. `ri_diskio_byteswritten` is what reached the device
    /// on this process's account so far, and lags it by the page cache.
    static func counters() -> (logical: UInt64, disk: UInt64) {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        } == 0
        return ok ? (info.ri_logical_writes, info.ri_diskio_byteswritten) : (0, 0)
    }

    func elapsed() -> Double { Date().timeIntervalSince(origin) }

    private func sample() -> Point {
        let c = Self.counters()
        var st = stat()
        let wal = stat(walPath, &st) == 0 ? UInt64(st.st_size) : 0
        return Point(t: elapsed(), logical: c.logical, disk: c.disk, wal: wal)
    }

    func start() {
        lock.lock(); running = true; points = [sample()]; lock.unlock()
        let thread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.05)
                let p = sample()
                lock.lock()
                guard running else { lock.unlock(); return }
                points.append(p)
                lock.unlock()
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { lock.lock(); running = false; lock.unlock() }

    private func record(_ p: Point) { lock.lock(); points.append(p); lock.unlock() }

    /// Runs `work` as one named phase and appends its record. On the caller's
    /// actor, so the work runs exactly where it would without the meter.
    func phase<T>(_ name: String, into records: inout [PhaseRecord],
                  isolation: isolated (any Actor)? = #isolation,
                  _ work: () async throws -> T) async rethrows -> T {
        let a = sample(); record(a)
        let value = try await work()
        let b = sample(); record(b)
        let r = PhaseRecord(name: name, seconds: b.t - a.t, logical: b.logical - a.logical,
                            disk: b.disk - a.disk, walPeak: walPeak(from: a.t, to: b.t),
                            storeAfter: IngestHarness.size(storeURL))
        records.append(r)
        // As it ends, so a long or interrupted run still says where it got.
        print("[ingest] done: \(r.line)")
        return value
    }

    private func walPeak(from t0: Double, to t1: Double) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return points.filter { $0.t >= t0 && $0.t <= t1 }.map(\.wal).max() ?? 0
    }

    /// The counters at `t`, interpolated between the samples either side.
    private func at(_ t: Double) -> (logical: Double, disk: Double) {
        lock.lock(); let pts = points; lock.unlock()
        guard let first = pts.first else { return (0, 0) }
        guard t > first.t else { return (Double(first.logical), Double(first.disk)) }
        for (i, p) in pts.enumerated().dropFirst() where p.t >= t {
            let q = pts[i - 1]
            let f = p.t > q.t ? (t - q.t) / (p.t - q.t) : 1
            return (Double(q.logical) + f * (Double(p.logical) - Double(q.logical)),
                    Double(q.disk) + f * (Double(p.disk) - Double(q.disk)))
        }
        let last = pts[pts.count - 1]
        return (Double(last.logical), Double(last.disk))
    }

    /// The cycle's own phases, in the order `runScanCycle` ticks them, laid
    /// end to end from when the cycle started and charged the bytes written
    /// in each span. Approximate at the edges (50 ms samples), exact enough to
    /// say which phase wrote the gigabyte.
    func split(_ p: ScanCoordinator.PhaseTimings, from start: Double) -> [PhaseRecord] {
        let order: [(String, Double)] = [
            ("autoAlias", p.autoAliasMs), ("metaPrep", p.metaPrepMs), ("migration", p.migrationMs),
            ("scan", p.scanMs), ("flush", p.flushMs), ("cursors", p.saveCursorsMs),
            ("daily", p.dailyRecomputeMs), ("hourly", p.hourlyRecomputeMs),
            ("project", p.projectRecomputeMs), ("session", p.sessionRecomputeMs),
            ("probe", p.probeMs), ("save", p.saveMs), ("notify", p.notifMs),
        ]
        var t = start
        var out: [PhaseRecord] = []
        for (name, ms) in order {
            let a = at(t), b = at(t + ms / 1000)
            out.append(PhaseRecord(name: "  " + name, seconds: ms / 1000,
                                   logical: UInt64(max(0, b.logical - a.logical)),
                                   disk: UInt64(max(0, b.disk - a.disk)),
                                   walPeak: walPeak(from: t, to: t + ms / 1000), storeAfter: 0))
            t += ms / 1000
        }
        return out
    }

    /// Every sample: elapsed s, cumulative logical and disk bytes, WAL bytes.
    func timeline() -> String {
        lock.lock(); let pts = points; lock.unlock()
        return (["t_s\tlogical_bytes\tdisk_bytes\twal_bytes"]
                + pts.map { String(format: "%.3f", $0.t) + "\t\($0.logical)\t\($0.disk)\t\($0.wal)" })
            .joined(separator: "\n") + "\n"
    }
}
