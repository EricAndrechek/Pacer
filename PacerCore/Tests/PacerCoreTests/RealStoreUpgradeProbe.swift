import Darwin
import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Runs the upgrade a new build's first launch performs, on a frozen COPY of a
/// real store, and measures what it costs the machine (AGENTS.md rule 8).
///
/// A store written by an older build carries an older `scanVersion` and
/// `costRecomputeVersion`, so the first cycle re-reads every transcript and
/// rebuilds every rollup. This drives exactly that cycle through
/// `ScanCoordinator.runOnce()` — the same coordinator, configuration shape and
/// task priority the app's scan loop uses — against transcripts frozen next to
/// the copy, so two builds can be compared on identical input:
///
///     sqlite3 "<copy of a pre-upgrade store>" ".backup '/tmp/up/pacer.sqlite'"
///     cp -c -R ~/.claude/projects /tmp/frozen/projects
///     PACER_UPGRADE_PROBE_STORE=/tmp/up/pacer.sqlite \
///     PACER_UPGRADE_PROBE_CLAUDE_DIR=/tmp/frozen \
///     PACER_UPGRADE_PROBE_CATALOG=/tmp/catalog.json \
///     PACER_ISOLATED_DEFAULTS=1 swift test --filter RealStoreUpgradeProbe
///
/// Run from PacerCore alone, the re-read goes through the line parser: the
/// DuckDB importer the app injects lives in the app target. The app's own path
/// is what `bin/dev-upgrade-bench.sh` measures — it compiles this file beside
/// `ArchiveImporter` and the vendored DuckDB, which is what `canImport(CDuckDB)`
/// below detects.
///
/// Reports the cycle's phase timings, its wall time, the process's peak cores
/// (over one-second windows), peak footprint and average cores while the cycle
/// runs, and fails on: any rollup row whose cost components don't sum to its
/// total; the daily or hourly rollups' tokens disagreeing with the samples;
/// the six per-field token totals moving. `PACER_UPGRADE_PROBE_OUT` names a
/// directory for a byte-exact dump of every rollup row and a digest of every
/// sample, so two builds' results can be compared with `cmp`.
@Suite("Real-store upgrade probe",
       .enabled(if: ProcessInfo.processInfo.environment["PACER_UPGRADE_PROBE_STORE"] != nil))
struct RealStoreUpgradeProbe {

    #if canImport(CDuckDB)
    static func bulkImporter() -> BulkTranscriptImporter? { ArchiveImporter() }
    #else
    static func bulkImporter() -> BulkTranscriptImporter? { nil }
    #endif

    /// The priority the cycle runs at: the app's scan loop's.
    /// `PACER_UPGRADE_PROBE_PRIORITY` (utility | userInitiated) overrides it.
    static func cyclePriority() -> TaskPriority {
        switch ProcessInfo.processInfo.environment["PACER_UPGRADE_PROBE_PRIORITY"] {
        case "utility": return .utility
        case "userInitiated": return .userInitiated
        default: return ScanCoordinator.loopPriority
        }
    }

    /// Timestamped like `Log.write`, so these lines and the coordinator's own
    /// interleave in time order.
    func log(_ s: String) {
        print("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) [upgrade] \(s)")
    }

    @ScanActor
    @Test func upgradeACopyOfTheRealStore() async throws {
        let env = ProcessInfo.processInfo.environment
        let storeURL = URL(fileURLWithPath: try #require(env["PACER_UPGRADE_PROBE_STORE"]))
        let claudeDir = try #require(env["PACER_UPGRADE_PROBE_CLAUDE_DIR"])
        // Refuse the live store outright, however the path is spelled.
        if let live = try? PacerStore.storeURL() {
            let same = storeURL.resolvingSymlinksInPath().path == live.resolvingSymlinksInPath().path
            #expect(!same)
            guard !same else { return }
        }
        let outDir = env["PACER_UPGRADE_PROBE_OUT"].map(URL.init(fileURLWithPath:))
        if let outDir {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        }

        let opened = Date()
        let container = try PacerStore.makeModelContainer(at: storeURL)
        // Token sums only, through a slim fetch: whatever this walk leaves
        // resident would otherwise count against the cycle measured below.
        let before = try Self.tokenSums(ModelContext(container))
        log(String(format: "opened copy (migration applied) in %.1f s", Date().timeIntervalSince(opened)))
        log("before  rows=\(before.rows) tokens=\(before.tokens)")

        // Pricing: an explicit catalog copy and the bundled curated file, so
        // two runs price identically whatever the network did in between.
        let table = PricingTable()
        try await table.ensureLoaded(cacheURL: env["PACER_UPGRADE_PROBE_CATALOG"].map(URL.init(fileURLWithPath:)))
        await SampleCostCache.reload(table, curatedCacheURL: URL(fileURLWithPath: "/nonexistent/price-history.json"))

        // A home of its own, so nothing reads the developer's login; the
        // config root is the frozen directory, which names no login either.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-upgrade-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let importer = Self.bulkImporter()
        log("ingest: \(importer == nil ? "line parser (no DuckDB in this build)" : "DuckDB bulk importer")")
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .auto, watcherMode: .manual, probeStatsCache: false,
                                 bulkImporter: importer),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": claudeDir]),
            homeDirectory: home)

        let priority = Self.cyclePriority()
        log("cycle priority: \(priority)")
        let sampler = ResourceSampler()
        sampler.start()
        let started = Date()
        // Not `await Task(priority:) {…}.value`: awaiting a task escalates it
        // to the awaiter's priority, which would measure the wrong thing. The
        // app's loop is never awaited either.
        let outcome: Result<ScanCoordinator.ScanReport, Error> = await withCheckedContinuation { done in
            Task.detached(priority: priority) {
                do { done.resume(returning: .success(try await coordinator.runOnce())) }
                catch { done.resume(returning: .failure(error)) }
            }
        }
        let wall = Date().timeIntervalSince(started)
        let usage = sampler.stop()
        let report = try outcome.get()
        #expect(report.wasFullScan)

        let p = report.phaseTimings
        log(String(format: "cycle %.1f s wall · %.2f cores average · peak %.2f cores (1 s window) at +%.0f s",
                   wall, usage.averageCores, usage.peakCores, usage.peakCoresAt))
        log(String(format: "memory: peak footprint %.0f MB at +%.0f s · peak resident %.0f MB · lifetime max footprint %.0f MB",
                   Double(usage.peakFootprint) / 1e6, usage.peakFootprintAt,
                   Double(usage.peakResident) / 1e6, Double(usage.lifetimeMaxFootprint) / 1e6))
        log(String(format: "phases (s): autoA %.1f · prep %.1f · mig %.1f · scan %.1f · flush %.1f · curs %.1f · "
                   + "daily %.1f · hourly %.1f · project %.1f · session %.1f · save %.1f",
                   p.autoAliasMs / 1000, p.metaPrepMs / 1000, p.migrationMs / 1000, p.scanMs / 1000,
                   p.flushMs / 1000, p.saveCursorsMs / 1000, p.dailyRecomputeMs / 1000,
                   p.hourlyRecomputeMs / 1000, p.projectRecomputeMs / 1000,
                   p.sessionRecomputeMs / 1000, p.saveMs / 1000))
        log("scan: \(coordinator.formatReport(report))")
        if let outDir { try usage.timeline.write(to: outDir.appendingPathComponent("timeline.tsv"), atomically: true, encoding: .utf8) }

        // Correctness, read back through a fresh context.
        let ctx = ModelContext(container)
        let after = try Self.sampleTotals(ctx)
        log("after   \(after.description)")
        // The frozen transcripts may hold turns newer than the copy: those are
        // inserted, and nothing already stored may be lost or shrink.
        log("inserted \(report.persisterStats.inserted) row(s), "
            + "upgraded \(report.persisterStats.upgradedFromPartial)")
        #expect(after.rows == before.rows + report.persisterStats.inserted)
        #expect(zip(after.tokens, before.tokens).allSatisfy { $0 >= $1 }, "a token total went down")

        func check<T: PersistentModel & RollupCostColumns>(_ name: String, _ type: T.Type) throws -> Int {
            var maxDiff = 0.0, n = 0
            for row in try ctx.fetch(FetchDescriptor<T>()) {
                n += 1
                maxDiff = max(maxDiff, abs(row.rollupTotalCostUSD - row.costComponents.total))
            }
            log("components: \(name) \(n) row(s), max |total - Σcomponents| = \(maxDiff)")
            #expect(maxDiff < 1e-9, "\(name) components do not sum to the total")
            return n
        }
        _ = try check("daily", DailyAggregate.self)
        _ = try check("hourly", HourlyAggregate.self)
        _ = try check("project", ProjectDailyAggregate.self)
        _ = try check("session", SessionInfo.self)
        _ = try check("acct-daily", AccountDailyAggregate.self)
        _ = try check("acct-hourly", AccountHourlyAggregate.self)
        _ = try check("acct-project", AccountProjectDailyAggregate.self)
        _ = try check("acct-session", AccountSessionInfo.self)

        let daily = try ctx.fetch(FetchDescriptor<DailyAggregate>())
        let hourly = try ctx.fetch(FetchDescriptor<HourlyAggregate>())
        let dailyTokens = daily.reduce(into: [Int64](repeating: 0, count: 5)) { t, r in
            t[0] += r.inputTokens; t[1] += r.outputTokens; t[2] += r.cacheReadTokens
            t[3] += r.cacheCreation5mTokens; t[4] += r.cacheCreation1hTokens
        }
        let hourlyTokens = hourly.reduce(into: [Int64](repeating: 0, count: 5)) { t, r in
            t[0] += r.inputTokens; t[1] += r.outputTokens; t[2] += r.cacheReadTokens
            t[3] += r.cacheCreation5mTokens; t[4] += r.cacheCreation1hTokens
        }
        log("rollup tokens: daily \(dailyTokens == after.tokens ? "=" : "≠") samples, "
            + "hourly \(hourlyTokens == after.tokens ? "=" : "≠") samples")
        #expect(dailyTokens == after.tokens)
        #expect(hourlyTokens == after.tokens)

        // Per-model cost, summed in key order so the figure is reproducible
        // to the bit across runs.
        var byModel: [String: Double] = [:]
        for row in daily.sorted(by: { $0.dateModelKey < $1.dateModelKey }) {
            byModel[row.model, default: 0] += row.totalCostUSD
        }
        for (model, cost) in byModel.sorted(by: { $0.value > $1.value }) {
            log(String(format: "  %-30@ $%12.4f  bits %016llx", model as NSString, cost, cost.bitPattern))
        }

        if let outDir {
            try Self.dumpRollups(ctx).write(
                to: outDir.appendingPathComponent("rollups.tsv"), atomically: true, encoding: .utf8)
            var models = byModel.sorted { $0.key < $1.key }
                .map { "\($0.key)\t\(String($0.value.bitPattern, radix: 16))\t\($0.value)" }
            models.append("TOTALS\t\(after.description)")
            models.append("SAMPLE_DIGEST\t\(after.digest)")
            try (models.joined(separator: "\n") + "\n").write(
                to: outDir.appendingPathComponent("models.tsv"), atomically: true, encoding: .utf8)
            log("wrote rollups.tsv, models.tsv and timeline.tsv to \(outDir.path)")
        }
    }

    // MARK: - Reading the store back

    struct SampleTotals: CustomStringConvertible {
        var rows = 0
        /// input, output, cache read, cache write 5m, cache write 1h.
        var tokens = [Int64](repeating: 0, count: 5)
        /// Order-independent digest of every sample's stored fields: two
        /// stores with the same rows have the same digest whatever order a
        /// fetch returns them in.
        var digest = ""
        var description: String {
            "rows=\(rows) input=\(tokens[0]) output=\(tokens[1]) cacheRead=\(tokens[2]) "
                + "cc5m=\(tokens[3]) cc1h=\(tokens[4]) digest=\(digest)"
        }
    }

    @ScanActor
    static func tokenSums(_ context: ModelContext) throws -> (rows: Int, tokens: [Int64]) {
        var rows = 0
        var tokens = [Int64](repeating: 0, count: 5)
        var d = FetchDescriptor<TokenSample>()
        d.propertiesToFetch = [\.inputTokens, \.outputTokens, \.cacheReadTokens,
                               \.cacheCreation5mTokens, \.cacheCreation1hTokens]
        try context.enumerate(d, batchSize: 10_000) { s in
            rows += 1
            tokens[0] += s.inputTokens; tokens[1] += s.outputTokens; tokens[2] += s.cacheReadTokens
            tokens[3] += s.cacheCreation5mTokens; tokens[4] += s.cacheCreation1hTokens
        }
        return (rows, tokens)
    }

    @ScanActor
    static func sampleTotals(_ context: ModelContext) throws -> SampleTotals {
        var t = SampleTotals()
        var sum: UInt64 = 0, mix: UInt64 = 0
        try context.enumerate(FetchDescriptor<TokenSample>(), batchSize: 5_000) { s in
            t.rows += 1
            t.tokens[0] += s.inputTokens; t.tokens[1] += s.outputTokens; t.tokens[2] += s.cacheReadTokens
            t.tokens[3] += s.cacheCreation5mTokens; t.tokens[4] += s.cacheCreation1hTokens
            // Built in typed steps: as one 18-element literal Xcode 16's
            // type checker gives up on it (macOS 15 CI).
            let stamp: String = String(s.sampledAt.timeIntervalSince1970.bitPattern, radix: 16)
            let cost: String = s.sourceCostUSD.map { String($0.bitPattern, radix: 16) } ?? "-"
            var parts: [String] = [s.dedupKey ?? "-", stamp, s.date, s.model, String(s.localHour)]
            parts += [String(s.inputTokens), String(s.outputTokens), String(s.cacheReadTokens)]
            parts += [String(s.cacheCreation5mTokens), String(s.cacheCreation1hTokens), cost]
            parts += [s.sessionId ?? "-", s.projectPath ?? "-", s.originalProjectPath ?? "-"]
            parts += [s.ccVersion ?? "-", s.accountId ?? "-", s.speed ?? "-", s.inferenceGeo ?? "-"]
            let line: String = parts.joined(separator: "\u{1F}")
            let h = fnv1a(line)
            sum &+= h
            mix ^= h &* 0x9E37_79B9_7F4A_7C15
        }
        t.digest = String(format: "%016llx%016llx", sum, mix)
        return t
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    /// Every rollup row, keyed and sorted, with costs as bit patterns.
    @ScanActor
    static func dumpRollups(_ ctx: ModelContext) throws -> String {
        func bits(_ c: CostComponents, _ total: Double) -> String {
            [total, c.input, c.output, c.cacheRead, c.cacheWrite5m, c.cacheWrite1h]
                .map { String($0.bitPattern, radix: 16) }.joined(separator: "\t")
        }
        func tokens(_ v: Int64...) -> String { v.map(String.init).joined(separator: "\t") }
        var lines: [String] = []
        for r in try ctx.fetch(FetchDescriptor<DailyAggregate>()) {
            lines.append("daily\t\(r.dateModelKey)\t" + tokens(r.inputTokens, r.outputTokens, r.cacheReadTokens,
                r.cacheCreation5mTokens, r.cacheCreation1hTokens) + "\t" + bits(r.costComponents, r.totalCostUSD))
        }
        for r in try ctx.fetch(FetchDescriptor<HourlyAggregate>()) {
            lines.append("hourly\t\(r.dateHourModelKey)\t" + tokens(r.inputTokens, r.outputTokens, r.cacheReadTokens,
                r.cacheCreation5mTokens, r.cacheCreation1hTokens) + "\t" + bits(r.costComponents, r.totalCostUSD))
        }
        for r in try ctx.fetch(FetchDescriptor<ProjectDailyAggregate>()) {
            lines.append("project\t\(r.projectDateKey)\t" + tokens(r.inputTokens, r.outputTokens, r.cacheReadTokens,
                r.cacheCreation5mTokens, r.cacheCreation1hTokens) + "\t" + bits(r.costComponents, r.totalCostUSD))
        }
        for r in try ctx.fetch(FetchDescriptor<SessionInfo>()) {
            lines.append("session\t\(r.sessionId)\t" + tokens(r.cumulativeInputTokens, r.cumulativeOutputTokens,
                r.cumulativeCacheReadTokens, r.cumulativeCacheCreation5mTokens, r.cumulativeCacheCreation1hTokens)
                + "\t" + bits(r.costComponents, r.cumulativeCostUSD))
        }
        for r in try ctx.fetch(FetchDescriptor<AccountDailyAggregate>()) {
            lines.append("acct-daily\t\(r.accountDateModelKey)\t" + bits(r.costComponents, r.totalCostUSD))
        }
        for r in try ctx.fetch(FetchDescriptor<AccountHourlyAggregate>()) {
            lines.append("acct-hourly\t\(r.accountDateHourModelKey)\t" + bits(r.costComponents, r.totalCostUSD))
        }
        for r in try ctx.fetch(FetchDescriptor<AccountProjectDailyAggregate>()) {
            lines.append("acct-project\t\(r.accountProjectDateKey)\t" + bits(r.costComponents, r.totalCostUSD))
        }
        for r in try ctx.fetch(FetchDescriptor<AccountSessionInfo>()) {
            lines.append("acct-session\t\(r.accountSessionKey)\t" + bits(r.costComponents, r.rollupTotalCostUSD))
        }
        return lines.sorted().joined(separator: "\n") + "\n"
    }
}

/// Samples this process's CPU time and memory every 100 ms on a plain thread
/// (not the cooperative pool, which is what is being measured).
final class ResourceSampler: @unchecked Sendable {
    struct Usage {
        var averageCores = 0.0
        var peakCores = 0.0
        var peakCoresAt = 0.0
        var peakFootprint: UInt64 = 0
        var peakFootprintAt = 0.0
        var peakResident: UInt64 = 0
        var lifetimeMaxFootprint: UInt64 = 0
        /// One line a second: elapsed s, cores over that second, footprint MB.
        var timeline = ""
    }

    private struct Point { let t: Double; let cpu: Double; let footprint: UInt64; let resident: UInt64 }

    private let lock = NSLock()
    private var points: [Point] = []
    private var running = false
    private var thread: Thread?
    private let origin = Date()

    private static func read(since origin: Date) -> Point {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        } == 0
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let cpu = Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec)
            + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
        return Point(t: Date().timeIntervalSince(origin), cpu: cpu,
                     footprint: ok ? info.ri_phys_footprint : 0,
                     resident: ok ? info.ri_resident_size : 0)
    }

    func start() {
        lock.lock(); running = true; points = [Self.read(since: origin)]; lock.unlock()
        let t = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.1)
                let p = Self.read(since: origin)
                lock.lock()
                guard running else { lock.unlock(); return }
                points.append(p)
                lock.unlock()
            }
        }
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() -> Usage {
        let last = Self.read(since: origin)
        lock.lock(); running = false; points.append(last); let pts = points; lock.unlock()
        var u = Usage()
        guard let first = pts.first, pts.count > 1 else { return u }
        u.averageCores = (last.cpu - first.cpu) / max(last.t - first.t, 1e-9)
        // `j` trails `i` as the latest point at least a second before it, so
        // each window is the trailing second (or a little more).
        var j = 0
        for (i, p) in pts.enumerated() {
            if p.footprint > u.peakFootprint { u.peakFootprint = p.footprint; u.peakFootprintAt = p.t }
            u.peakResident = max(u.peakResident, p.resident)
            while j + 1 < i, p.t - pts[j + 1].t >= 1.0 { j += 1 }
            let window = p.t - pts[j].t
            if window >= 1.0 {
                let cores = (p.cpu - pts[j].cpu) / window
                if cores > u.peakCores { u.peakCores = cores; u.peakCoresAt = p.t }
            }
        }
        var lines = ["t_s\tcores\tfootprint_mb\tresident_mb"]
        var prev = first
        for p in pts where p.t - prev.t >= 1.0 || p.t == last.t {
            let cores = (p.cpu - prev.cpu) / max(p.t - prev.t, 1e-9)
            lines.append(String(format: "%.1f\t%.2f\t%.0f\t%.0f", p.t, cores,
                                Double(p.footprint) / 1e6, Double(p.resident) / 1e6))
            prev = p
        }
        u.timeline = lines.joined(separator: "\n") + "\n"
        var info = rusage_info_v4()
        _ = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        u.lifetimeMaxFootprint = info.ri_lifetime_max_phys_footprint
        return u
    }
}
