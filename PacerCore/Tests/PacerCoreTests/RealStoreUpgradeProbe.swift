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
/// runs, then what memory the rebuild leaves behind and what is left after a
/// steady-state stand-in — `steadyCycles` incremental cycles with the HTTP
/// snapshot rebuilt between them (#337) — and fails on: any rollup row whose cost components don't sum to its
/// total; the daily or hourly rollups' tokens disagreeing with the samples;
/// the six per-field token totals moving. `PACER_UPGRADE_PROBE_OUT` names a
/// directory for a byte-exact dump of every rollup row and a digest of every
/// sample, so two builds' results can be compared with `cmp`.
/// `PACER_UPGRADE_PROBE_FORCE_REBUILD` drops the stored `costRecomputeVersion`
/// first, so every rollup is rebuilt from every sample. While the cycle runs,
/// `MainActorWatch` records how long the main actor went without running (and
/// fails above 250 ms); `PACER_UPGRADE_PROBE_MAIN` picks what it keeps on the
/// main thread meanwhile.
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

        // Line-buffered, so a run that stalls shows how far it got.
        setvbuf(stdout, nil, _IOLBF, 0)
        let opened = Date()
        let container = try PacerStore.makeModelContainer(at: storeURL)
        // Token sums only, through a slim paged fetch: whatever this walk
        // leaves resident would otherwise count against the cycle measured
        // below (an `enumerate` here left gigabytes, #337).
        let before = try Self.tokenSums(container)
        log(String(format: "opened copy (migration applied) in %.1f s", Date().timeIntervalSince(opened)))
        log("before  rows=\(before.rows) tokens=\(before.tokens)")
        let scanVersionBefore = try Self.meta(container, ClaudeCodeMetaKey.scanVersion)
        if env["PACER_UPGRADE_PROBE_FORCE_REBUILD"] != nil {
            // Every rollup rebuilt from every sample, as a `costRecomputeVersion`
            // bump does: the worst case for memory, and with an empty Claude
            // root a deterministic one, so two builds' dumps compare bit for bit.
            let ctx = ModelContext(container)
            let key = ClaudeCodeMetaKey.costRecomputeVersion
            for row in try ctx.fetch(FetchDescriptor<ClaudeCodeMeta>(predicate: #Predicate { $0.key == key })) {
                ctx.delete(row)
            }
            try ctx.save()
            log("forcing a full rollup rebuild")
        }
        logMemory("before cycle", ProcessMemory.current())

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
        let watchMode = MainActorWatch.Mode(rawValue: env["PACER_UPGRADE_PROBE_MAIN"] ?? "") ?? .reader
        let watch = await MainActorWatch.start(container: container, mode: watchMode)
        log("main actor watch: \(watchMode.rawValue)")
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
        let mainActor = await watch.stop()
        let report = try outcome.get()
        // A copy the current build wrote is already on this scan version;
        // only a forced rebuild runs on one, and it rebuilds without re-reading.
        #expect(report.wasFullScan == (scanVersionBefore != ScanCoordinator.currentScanVersion))
        for line in mainActor.lines { log("main actor: \(line)") }
        // The bar for the first launch after an update (#376): the main
        // thread is never held for more than a quarter second at a time.
        #expect(mainActor.longestGapMs < 250, "the main actor was held \(Int(mainActor.longestGapMs)) ms")

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

        // What the rebuild leaves behind (#337): the floor the app then sits
        // on. Taken before anything below reads the store back.
        logMemory("after rebuild", ProcessMemory.current())
        if let outDir { Self.inspect(into: outDir, label: "rebuild") }

        // A steady-state stand-in: incremental cycles against the live
        // transcripts, with the HTTP snapshot rebuilt between them as the
        // app's refresher does.
        let steadyStarted = Date()
        var steadyInserted = 0
        var snapshotMs: [Double] = []
        for _ in 0..<Self.steadyCycles {
            let cycle = try await Self.runCycle(coordinator, priority: priority)
            #expect(!cycle.wasFullScan)
            steadyInserted += cycle.persisterStats.inserted
            for _ in 0..<(Self.snapshotBuilds / Self.steadyCycles) {
                let built = Date()
                _ = try await Self.buildSnapshot(container)
                snapshotMs.append(Date().timeIntervalSince(built) * 1000)
            }
        }
        log(String(format: "steady: %d incremental cycle(s) + %d snapshot build(s) in %.1f s "
                   + "(snapshot median %.0f ms), %d row(s) inserted",
                   Self.steadyCycles, snapshotMs.count, Date().timeIntervalSince(steadyStarted),
                   snapshotMs.sorted()[snapshotMs.count / 2], steadyInserted))
        logMemory("steady state", ProcessMemory.current())
        if let outDir { Self.inspect(into: outDir, label: "steady") }

        // Correctness, read back through a fresh context.
        let ctx = ModelContext(container)
        let after = try Self.sampleTotals(ctx)
        log("after   \(after.description)")
        // The frozen transcripts may hold turns newer than the copy: those are
        // inserted, and nothing already stored may be lost or shrink.
        log("inserted \(report.persisterStats.inserted) row(s), "
            + "upgraded \(report.persisterStats.upgradedFromPartial)")
        #expect(after.rows == before.rows + report.persisterStats.inserted + steadyInserted)
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

    @ScanActor
    static func meta(_ container: ModelContainer, _ key: String) throws -> String? {
        try ModelContext(container).fetch(FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate { $0.key == key })).first?.value
    }

    // MARK: - Steady state and memory

    static let steadyCycles = 10
    static let snapshotBuilds = 20

    /// One cycle at the loop's priority, without escalating it — see the
    /// full cycle above.
    @ScanActor
    static func runCycle(_ coordinator: ScanCoordinator,
                         priority: TaskPriority) async throws -> ScanCoordinator.ScanReport {
        let outcome: Result<ScanCoordinator.ScanReport, Error> = await withCheckedContinuation { done in
            Task.detached(priority: priority) {
                do { done.resume(returning: .success(try await coordinator.runOnce())) }
                catch { done.resume(returning: .failure(error)) }
            }
        }
        return try outcome.get()
    }

    /// The HTTP API's snapshot, built off the scan actor as the app's
    /// refresher builds it on its own queue.
    static func buildSnapshot(_ container: ModelContainer) async throws -> PacerAPISnapshot {
        try await Task.detached(priority: .utility) {
            try PacerAPISnapshot.build(container: container, activeAccountId: nil,
                                       desktop: nil, now: Date())
        }.value
    }

    func logMemory(_ label: String, _ m: ProcessMemory) {
        log("memory \(label): \(m.summary) · fragmentation \(ProcessMemory.mb(m.mallocFragmentation)) MB")
    }

    /// `vmmap --summary` of this process (and, with `PACER_UPGRADE_PROBE_HEAP`,
    /// `heap`'s count by type) into `outDir`, for what the in-process numbers
    /// can't say: which zone, which region type, which allocations.
    static func inspect(into outDir: URL, label: String) {
        var tools = [("vmmap", ["--summary", String(getpid())])]
        if ProcessInfo.processInfo.environment["PACER_UPGRADE_PROBE_HEAP"] != nil {
            tools.append(("heap", ["-sortBySize", String(getpid())]))
        }
        for (tool, arguments) in tools {
            let out = outDir.appendingPathComponent("\(tool)-\(label).txt")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: out) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/\(tool)")
            process.arguments = arguments
            process.standardOutput = handle
            process.standardError = handle
            do {
                try process.run()
                process.waitUntilExit()
            } catch {}
            try? handle.close()
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
    static func tokenSums(_ container: ModelContainer) throws -> (rows: Int, tokens: [Int64]) {
        var rows = 0
        var tokens = [Int64](repeating: 0, count: 5)
        var d = FetchDescriptor<TokenSample>()
        d.propertiesToFetch = [\.inputTokens, \.outputTokens, \.cacheReadTokens,
                               \.cacheCreation5mTokens, \.cacheCreation1hTokens]
        // Pages through throwaway contexts, written out here rather than
        // through `ModelWalk` so this file builds against older trees too.
        d.fetchLimit = 10_000
        var offset = 0
        while true {
            d.fetchOffset = offset
            let page = try autoreleasepool { try ModelContext(container).fetch(d).map {
                [$0.inputTokens, $0.outputTokens, $0.cacheReadTokens,
                 $0.cacheCreation5mTokens, $0.cacheCreation1hTokens]
            } }
            for t in page {
                rows += 1
                for i in 0..<5 { tokens[i] += t[i] }
            }
            offset += page.count
            if page.count < 10_000 { break }
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

/// How long the main actor goes without running while the upgrade cycle runs
/// off it (#376): the first launch after an update must never hold it for
/// more than a quarter second at a time.
///
/// A heartbeat on the main actor sleeps 10 ms and records how late it wakes;
/// a wake that is late by a second means the main thread could not run a
/// job, a click or a frame for that second. The modes add what the app keeps
/// on the main thread during a rebuild, so the cost of each can be told apart:
///
/// Chosen with `PACER_UPGRADE_PROBE_MAIN`:
///
/// - `off`: no watch at all.
/// - `beat`: the heartbeat alone, the store's main context never created.
///   What the rebuild itself sends to the main actor.
/// - `context`: plus `container.mainContext`, which the app always has, and
///   which SwiftData merges every other context's saves into on the main
///   thread.
/// - `reader` (the default): plus the reads the menu bar label made on the
///   main context after every save any context made, as its `@Query`s did
///   until PACER-19 moved them off the main thread (`MenuBarLabelFeed`). Kept
///   as the heavy case: the dropdown's retained host still holds two of them.
@MainActor
final class MainActorWatch {
    enum Mode: String { case off, beat, context, reader }

    struct Report {
        var longestGapMs = 0.0
        var lines: [String] = []
    }

    private let mode: Mode
    private let container: ModelContainer
    private let origin = Date()
    private var task: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?
    private var readerQueued = false
    private var gaps: [(at: Double, ms: Double, step: String)] = []
    private var beats = 0
    private var readerPasses = 0
    private var readerTotalMs = 0.0
    private var readerLongest: (at: Double, ms: Double) = (0, 0)
    private var saves = 0
    private let account: String

    private init(container: ModelContainer, mode: Mode, account: String) {
        self.container = container
        self.mode = mode
        self.account = account
    }

    static func start(container: ModelContainer, mode: Mode) async -> MainActorWatch {
        // The account the menu bar would be scoped to: the one with the most
        // turns, read before the watch starts so it costs the cycle nothing.
        let account = await Task.detached {
            let ctx = ModelContext(container)
            let ids = ((try? ctx.fetch(FetchDescriptor<Account>())) ?? []).map(\.id)
            return ids.max { a, b in
                let ca = (try? ctx.fetchCount(FetchDescriptor<TokenSample>(
                    predicate: #Predicate { $0.accountId == a }))) ?? 0
                let cb = (try? ctx.fetchCount(FetchDescriptor<TokenSample>(
                    predicate: #Predicate { $0.accountId == b }))) ?? 0
                return ca < cb
            } ?? UsageScope.noAccountSentinel
        }.value
        let watch = MainActorWatch(container: container, mode: mode, account: account)
        watch.begin()
        return watch
    }

    private func begin() {
        guard mode != .off else { return }
        if mode != .beat { _ = container.mainContext }
        if mode == .reader {
            observer = NotificationCenter.default.addObserver(
                forName: ModelContext.didSave, object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.saveSeen() }
            }
            read()
        }
        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let now = clock.now
                let late = (now - last) / .milliseconds(1) - 10
                last = now
                self?.beat(lateMs: late)
            }
        }
    }

    private func now() -> Double { Date().timeIntervalSince(origin) }

    private func beat(lateMs: Double) {
        beats += 1
        guard lateMs >= 100 else { return }
        let step = HistoryRebuildStatus.shared.step.map { "\($0)" } ?? "-"
        gaps.append((now() - lateMs / 1000, lateMs, step))
    }

    /// Coalesced like a `@Query` refresh: one pass per main-actor turn,
    /// however many saves landed in it.
    private func saveSeen() {
        saves += 1
        guard !readerQueued else { return }
        readerQueued = true
        Task { @MainActor in
            self.readerQueued = false
            self.read()
        }
    }

    /// What `MenuBarLabel`'s four `@Query`s and its window load fetched before
    /// PACER-19, on the main context.
    private func read() {
        let began = Date()
        let ctx = container.mainContext
        let today = TokenSample.formatDate(Date())
        let acct = account
        _ = try? ctx.fetch(FetchDescriptor<DailyAggregate>(predicate: #Predicate { $0.date == today }))
        _ = try? ctx.fetch(FetchDescriptor<AccountDailyAggregate>(
            predicate: #Predicate { $0.date == today && $0.accountId == acct }))
        var newest = FetchDescriptor<TokenSample>(sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        newest.fetchLimit = 1
        _ = try? ctx.fetch(newest)
        var scopedNewest = FetchDescriptor<TokenSample>(
            predicate: #Predicate { $0.accountId == acct },
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        scopedNewest.fetchLimit = 1
        _ = try? ctx.fetch(scopedNewest)
        _ = try? ctx.fetch(LimitScope.rateLimits(account: acct, limit: 8))
        _ = try? ctx.fetch(LimitScope.modelScopedLimits(account: acct, limit: 64))
        let ms = Date().timeIntervalSince(began) * 1000
        readerPasses += 1
        readerTotalMs += ms
        if ms > readerLongest.ms { readerLongest = (now() - ms / 1000, ms) }
    }

    func stop() -> Report {
        task?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        var r = Report()
        r.longestGapMs = gaps.map(\.ms).max() ?? 0
        let held = gaps.reduce(0) { $0 + $1.ms }
        r.lines.append(String(
            format: "%@ · %d beats · longest gap %.0f ms · %d gap(s) ≥ 100 ms, %d ≥ 250 ms, %d ≥ 1 s · %.1f s held in all",
            mode.rawValue, beats, r.longestGapMs, gaps.count, gaps.filter { $0.ms >= 250 }.count,
            gaps.filter { $0.ms >= 1000 }.count, held / 1000))
        if mode == .reader {
            r.lines.append(String(
                format: "reader: %d pass(es) after %d save(s), longest %.0f ms at +%.1f s, %.1f s in all",
                readerPasses, saves, readerLongest.ms, readerLongest.at, readerTotalMs / 1000))
        }
        for g in gaps.sorted(by: { $0.ms > $1.ms }).prefix(12) {
            r.lines.append(String(format: "  gap %6.0f ms at +%6.1f s during %@", g.ms, g.at, g.step))
        }
        return r
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
