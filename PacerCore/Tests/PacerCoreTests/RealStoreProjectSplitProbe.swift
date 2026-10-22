import Darwin
import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Runs cost recompute "19" — the project rollups gaining their split by
/// model — on a frozen COPY of a real store, and checks every row it wrote
/// (AGENTS.md rule 8). Opt-in, and never the live store:
///
///     sqlite3 "<store>" ".backup '/tmp/split/pacer.sqlite'"
///     PACER_SPLIT_PROBE_STORE=/tmp/split/pacer.sqlite \
///     PACER_ISOLATED_DEFAULTS=1 swift test --filter RealStoreProjectSplitProbe
///
/// Opening the copy runs this build's lightweight migration on it (the two
/// old per-model columns dropped, `modelBreakdownJSON` added); the first scan
/// cycle then takes the version-19 rebuild, exactly as an upgrading user's
/// first launch would. The scan reads an empty Claude root, so the samples
/// already in the copy are the only input. Prices come from the embedded
/// snapshot and the bundled curated file, so nothing else is read.
///
/// Reports the cycle's wall time and peak footprint, and fails on: a project
/// or per-account project row whose models' tokens differ from its columns
/// (exactly) or whose models' costs differ from its cost parts (beyond float
/// rounding); a (date, model) whose projects' shares differ from its
/// `DailyAggregate` row; any token column total moving across the rebuild.
@Suite("Real-store project split probe",
       .enabled(if: ProcessInfo.processInfo.environment["PACER_SPLIT_PROBE_STORE"] != nil))
struct RealStoreProjectSplitProbe {

    func log(_ s: String) {
        print("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) [split] \(s)")
    }

    /// The five token columns of every row of `T`, summed — through a slim
    /// fetch, as the tables are small.
    @ScanActor
    static func columnTotals<T: PersistentModel & RollupTokenColumns>(
        _ type: T.Type, _ context: ModelContext
    ) throws -> (rows: Int, tokens: TokenBreakdown) {
        let rows = try context.fetch(FetchDescriptor<T>())
        return (rows.count, rows.reduce(TokenBreakdown.zero) { $0 + $1.tokens })
    }

    struct RowCheck {
        var rows = 0
        var mismatched = 0
        var undecodable = 0
        var models = 0
        var bytes = 0
        var maxCostDiff = 0.0
        var firstBad: [String] = []
    }

    static func check(_ rows: [any ProjectDailyReadable], label: (any ProjectDailyReadable) -> String) -> RowCheck {
        var out = RowCheck()
        for row in rows {
            out.rows += 1
            out.bytes += row.modelBreakdownJSON?.count ?? 0
            guard let models = ProjectModelBreakdowns.decode(row.modelBreakdownJSON) else {
                out.undecodable += 1
                if out.firstBad.count < 5 { out.firstBad.append("undecodable \(label(row))") }
                continue
            }
            out.models += models.count
            let sum = models.values.reduce(CostBreakdown.zero, +)
            var diff = 0.0
            for part in CostComponent.allCases {
                diff = max(diff, abs(sum.cost[part] - row.costComponents[part]))
            }
            out.maxCostDiff = max(out.maxCostDiff, diff)
            if models.isEmpty || models.count != row.modelCount || sum.tokens != row.tokens || diff > 1e-9 {
                out.mismatched += 1
                if out.firstBad.count < 5 {
                    out.firstBad.append("\(label(row)) models=\(models.count)/\(row.modelCount) "
                                        + "tokens \(sum.tokens.all) vs \(row.tokens.all) cost Δ\(diff)")
                }
            }
        }
        return out
    }

    @ScanActor
    @Test func rebuildACopyOfTheRealStore() async throws {
        let env = ProcessInfo.processInfo.environment
        let storeURL = URL(fileURLWithPath: try #require(env["PACER_SPLIT_PROBE_STORE"]))
        // Refuse the live store outright, however the path is spelled.
        if let live = try? PacerStore.storeURL() {
            let same = storeURL.resolvingSymlinksInPath().path == live.resolvingSymlinksInPath().path
            #expect(!same)
            guard !same else { return }
        }

        let opened = Date()
        let container = try PacerStore.makeModelContainer(at: storeURL)
        log(String(format: "opened copy (migration applied) in %.1f s", Date().timeIntervalSince(opened)))
        let pre = ModelContext(container)
        let key = ClaudeCodeMetaKey.costRecomputeVersion
        let storedVersion = try pre.fetch(FetchDescriptor<ClaudeCodeMeta>(predicate: #Predicate { $0.key == key }))
            .first?.value
        log("stored cost recompute version: \(storedVersion ?? "none") → \(ScanCoordinator.currentCostRecomputeVersion)")
        let projectBefore = try Self.columnTotals(ProjectDailyAggregate.self, pre)
        let accountProjectBefore = try Self.columnTotals(AccountProjectDailyAggregate.self, pre)
        let dailyBefore = try Self.columnTotals(DailyAggregate.self, pre)
        let withSplit = try pre.fetch(FetchDescriptor<ProjectDailyAggregate>())
            .filter { $0.modelBreakdownJSON != nil }.count
        log("before: \(projectBefore.rows) project row(s), \(withSplit) with a split; "
            + "\(accountProjectBefore.rows) per-account project row(s)")
        var topBefore: [String: String] = [:]
        for s in try pre.fetch(FetchDescriptor<SessionInfo>()) { topBefore[s.sessionId] = s.topModel }
        let unattributedSamples = try pre.fetchCount(FetchDescriptor<TokenSample>(predicate: #Predicate {
            $0.accountId == nil }))
        log("samples with no account: \(unattributedSamples)")

        let table = PricingTable()
        try await table.ensureLoaded(cacheURL: URL(fileURLWithPath: "/nonexistent/litellm-pricing.json"))
        await SampleCostCache.reload(table, curatedCacheURL: URL(fileURLWithPath: "/nonexistent/price-history.json"))

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-split-home-\(UUID().uuidString)")
        let root = home.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .auto, watcherMode: .manual, probeStatsCache: false),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path]),
            homeDirectory: home)

        let sampler = ResourceSampler()
        sampler.start()
        let started = Date()
        // Detached at the app loop's priority, and not awaited as a task, so
        // the cycle runs at the priority the app gives it (see
        // `RealStoreUpgradeProbe`).
        let outcome: Result<ScanCoordinator.ScanReport, Error> = await withCheckedContinuation { done in
            Task.detached(priority: ScanCoordinator.loopPriority) {
                do { done.resume(returning: .success(try await coordinator.runOnce())) }
                catch { done.resume(returning: .failure(error)) }
            }
        }
        let wall = Date().timeIntervalSince(started)
        let usage = sampler.stop()
        let report = try outcome.get()
        let p = report.phaseTimings
        log(String(format: "cycle %.1f s wall · project recompute %.1f s · %.2f cores average", wall,
                   p.projectRecomputeMs / 1000, usage.averageCores))
        log(String(format: "memory: peak footprint %.0f MB at +%.0f s · peak resident %.0f MB · lifetime max %.0f MB",
                   Double(usage.peakFootprint) / 1e6, usage.peakFootprintAt,
                   Double(usage.peakResident) / 1e6, Double(usage.lifetimeMaxFootprint) / 1e6))
        log("scan: \(coordinator.formatReport(report))")

        let ctx = ModelContext(container)
        let version = try ctx.fetch(FetchDescriptor<ClaudeCodeMeta>(predicate: #Predicate { $0.key == key }))
        #expect(version.first?.value == ScanCoordinator.currentCostRecomputeVersion)

        // 1. Every row's models add up to it.
        let global: [any ProjectDailyReadable] = try ctx.fetch(FetchDescriptor<ProjectDailyAggregate>())
        let scoped: [any ProjectDailyReadable] = try ctx.fetch(FetchDescriptor<AccountProjectDailyAggregate>())
        for (name, rows) in [("project", global), ("account-project", scoped)] {
            let c = Self.check(rows) { "\($0.projectPath.hashValue)|\($0.date)" }
            log(String(format: "%@: %d row(s), %d model share(s), %d mismatched, %d undecodable, "
                       + "max |Σ model cost − row| per part %.3g, split %.2f MB",
                       name as NSString, c.rows, c.models, c.mismatched, c.undecodable, c.maxCostDiff,
                       Double(c.bytes) / 1e6))
            for line in c.firstBad { log("  \(name) bad: \(line)") }
            #expect(c.mismatched == 0 && c.undecodable == 0, "\(name) rows whose models do not sum to the row")
        }

        // 2. Every project's share of a model on a day adds up to that
        //    model's daily row: the turns went under the right model.
        var byDayModel: [String: CostBreakdown] = [:]
        for row in global {
            for (model, b) in row.modelBreakdowns {
                byDayModel[DailyAggregate.makeKey(date: row.date, model: model), default: .zero] += b
            }
        }
        let daily = try ctx.fetch(FetchDescriptor<DailyAggregate>())
        var dayMismatch = 0
        var dayMaxCost = 0.0
        for d in daily {
            let share = byDayModel.removeValue(forKey: d.dateModelKey) ?? .zero
            let diff = abs(share.total - d.totalCostUSD)
            dayMaxCost = max(dayMaxCost, diff)
            if share.tokens != d.tokens || diff > 1e-6 { dayMismatch += 1 }
        }
        log(String(format: "daily: %d (date, model) row(s), %d differ from their projects' shares, "
                   + "%d share(s) with no daily row, max cost Δ %.3g", daily.count, dayMismatch,
                   byDayModel.count, dayMaxCost))
        #expect(dayMismatch == 0)
        #expect(byDayModel.isEmpty)

        // 3. Per account: each (project, date)'s account rows against its
        //    global row, by model. Logged rather than asserted — the
        //    unattributed sentinel's NUL truncation (reported separately)
        //    collapses unattributed rows, so a store with unattributed turns
        //    differs here for a reason that is not the split.
        var accountsByBucket: [String: [String: CostBreakdown]] = [:]
        for row in scoped {
            for (model, b) in row.modelBreakdowns {
                accountsByBucket["\(row.projectPath)|\(row.date)", default: [:]][model, default: .zero] += b
            }
        }
        var accountMismatch = 0
        for row in global {
            let summed = accountsByBucket["\(row.projectPath)|\(row.date)"] ?? [:]
            if summed.mapValues(\.tokens) != row.modelBreakdowns.mapValues(\.tokens) { accountMismatch += 1 }
        }
        log("per-account split vs global split: \(accountMismatch) of \(global.count) bucket(s) differ")
        let blank = try ctx.fetchCount(FetchDescriptor<AccountProjectDailyAggregate>(predicate: #Predicate {
            $0.accountId == "" }))
        log("per-account project rows whose account reads back as \"\": \(blank)")

        // 4. Columns unchanged by the rebuild.
        let projectAfter = try Self.columnTotals(ProjectDailyAggregate.self, ctx)
        let dailyAfter = try Self.columnTotals(DailyAggregate.self, ctx)
        log("project tokens before \(projectBefore.tokens.all) after \(projectAfter.tokens.all); "
            + "daily before \(dailyBefore.tokens.all) after \(dailyAfter.tokens.all)")
        #expect(projectAfter.tokens == projectBefore.tokens)
        #expect(dailyAfter.tokens == dailyBefore.tokens)
        #expect(projectAfter.rows == projectBefore.rows)

        // 5. Session top models re-picked by all five parts.
        var changed = 0
        var sessions = 0
        for s in try ctx.fetch(FetchDescriptor<SessionInfo>()) {
            sessions += 1
            if let was = topBefore[s.sessionId], was != s.topModel { changed += 1 }
        }
        log("sessions: \(sessions), top model changed on \(changed)")
    }
}
