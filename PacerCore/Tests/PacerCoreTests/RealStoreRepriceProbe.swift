import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Re-prices a frozen COPY of a real store with this build, and checks the
/// result (AGENTS.md rule 8). Opt-in, and never the live store:
///
///     sqlite3 "file:<live store>?mode=ro" ".backup '/tmp/copy.sqlite'"
///     cp "<App Group>/litellm-pricing.cache.json" /tmp/catalog.json
///     PACER_REPRICE_PROBE_STORE=/tmp/copy.sqlite \
///     PACER_REPRICE_PROBE_CATALOG=/tmp/catalog.json \
///     PACER_ISOLATED_DEFAULTS=1 swift test --filter RealStoreRepriceProbe
///
/// Opening the copy runs this build's lightweight migration on it; the first
/// scan cycle then takes the `costRecomputeVersion` rebuild and the ledger
/// sync, exactly as an upgrading user's first launch would. The scan reads an
/// empty Claude root, so no transcripts are touched — the samples already in
/// the copy are the input.
///
/// Reports, and fails on: any rollup row whose five cost components don't sum
/// to its total; any (date, model) whose stored cost differs from a fresh
/// at-time recompute over its raw samples; the six per-field token totals
/// changing across the rebuild.
@Suite("Real-store reprice probe",
       .enabled(if: ProcessInfo.processInfo.environment["PACER_REPRICE_PROBE_STORE"] != nil))
struct RealStoreRepriceProbe {

    struct Totals: Equatable, CustomStringConvertible {
        var rows = 0
        var input: Int64 = 0, output: Int64 = 0, read: Int64 = 0, cc5m: Int64 = 0, cc1h: Int64 = 0
        var description: String {
            "rows=\(rows) input=\(input) output=\(output) cacheRead=\(read) cc5m=\(cc5m) cc1h=\(cc1h) "
                + "all=\(input + output + read + cc5m + cc1h)"
        }
    }

    @ScanActor
    static func tokenTotals(_ context: ModelContext) throws -> Totals {
        var t = Totals()
        var d = FetchDescriptor<TokenSample>()
        d.propertiesToFetch = [\.inputTokens, \.outputTokens, \.cacheReadTokens,
                               \.cacheCreation5mTokens, \.cacheCreation1hTokens]
        try context.enumerate(d, batchSize: 10_000) { s in
            t.rows += 1
            t.input += s.inputTokens; t.output += s.outputTokens; t.read += s.cacheReadTokens
            t.cc5m += s.cacheCreation5mTokens; t.cc1h += s.cacheCreation1hTokens
        }
        return t
    }

    @ScanActor
    static func dailyCosts(_ context: ModelContext) throws -> [String: Double] {
        var out: [String: Double] = [:]
        for row in try context.fetch(FetchDescriptor<DailyAggregate>()) {
            out[row.dateModelKey] = row.totalCostUSD
        }
        return out
    }

    @ScanActor
    @Test func repriceACopyOfTheRealStore() async throws {
        let env = ProcessInfo.processInfo.environment
        let storePath = try #require(env["PACER_REPRICE_PROBE_STORE"])
        let storeURL = URL(fileURLWithPath: storePath)
        // Refuse the live store outright, however the path is spelled.
        if let live = try? PacerStore.storeURL() {
            #expect(storeURL.resolvingSymlinksInPath().path != live.resolvingSymlinksInPath().path)
            guard storeURL.resolvingSymlinksInPath().path != live.resolvingSymlinksInPath().path else { return }
        }

        func log(_ s: String) { print("[reprice] \(s)") }
        let started = Date()
        let container = try PacerStore.makeModelContainer(at: storeURL)
        let context = ModelContext(container)
        let before = try Self.tokenTotals(context)
        let costsBefore = try Self.dailyCosts(context)
        log("opened copy (migration applied) in \(Int(Date().timeIntervalSince(started))) s")
        log("before  TOTALS \(before)")

        // Pricing inputs: an explicit catalog copy and the bundled curated
        // file (a nonexistent cache path keeps the App Group copy out of it).
        let table = PricingTable()
        try await table.ensureLoaded(cacheURL: env["PACER_REPRICE_PROBE_CATALOG"].map(URL.init(fileURLWithPath:)))
        await SampleCostCache.reload(table, curatedCacheURL: URL(fileURLWithPath: "/nonexistent/price-history.json"))

        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-reprice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: emptyRoot.appendingPathComponent("projects"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .auto, watcherMode: .manual, probeStatsCache: false),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": emptyRoot.path]))
        let report = try await coordinator.runOnce()
        log("scan: \(coordinator.formatReport(report))")
        log("rebuild took \(Int(Date().timeIntervalSince(started))) s total")

        let after = try Self.tokenTotals(ModelContext(container))
        log("after   TOTALS \(after)")
        #expect(after == before, "token totals moved across the rebuild")

        let ctx = ModelContext(container)
        let ledger = SampleCostCache.current().ledger
        log("ledger: \(try ctx.fetchCount(FetchDescriptor<PriceRecord>())) PriceRecord row(s), "
            + "\(ledger.records.filter(\.curated).count) curated, provisional=\(ledger.isProvisional)")

        // 1. Components sum to the total on every row of every rollup.
        func worst<T: PersistentModel & RollupCostColumns>(_ type: T.Type) throws -> (Int, Double) {
            var maxDiff = 0.0, n = 0
            for row in try ctx.fetch(FetchDescriptor<T>()) {
                n += 1
                maxDiff = max(maxDiff, abs(row.rollupTotalCostUSD - row.costComponents.total))
            }
            return (n, maxDiff)
        }
        let tables: [(String, (Int, Double))] = [
            ("daily", try worst(DailyAggregate.self)), ("hourly", try worst(HourlyAggregate.self)),
            ("project", try worst(ProjectDailyAggregate.self)), ("session", try worst(SessionInfo.self)),
            ("acct-daily", try worst(AccountDailyAggregate.self)),
            ("acct-hourly", try worst(AccountHourlyAggregate.self)),
            ("acct-project", try worst(AccountProjectDailyAggregate.self)),
            ("acct-session", try worst(AccountSessionInfo.self)),
        ]
        for (name, (n, d)) in tables {
            log("components: \(name) \(n) row(s), max |total - Σcomponents| = \(d)")
            #expect(d < 1e-9, "\(name) components do not sum to the total")
        }

        // 2. Stored cost equals a fresh at-time recompute, for every day.
        var fresh: [String: Double] = [:]
        var flagged: [String: Int] = [:]
        let snapshot = SampleCostCache.current()
        try ctx.enumerate(FetchDescriptor<TokenSample>(), batchSize: 10_000) { s in
            let c = CostCalculator.sampleCost(s, mode: .auto, snapshot: snapshot)
            fresh[DailyAggregate.makeKey(date: s.date, model: s.model), default: 0] += c.total
            if !c.flags.isEmpty { flagged[s.model, default: 0] += 1 }
        }
        let stored = try Self.dailyCosts(ctx)
        var mismatched = 0
        var byModel: [String: (before: Double, after: Double, fresh: Double)] = [:]
        for (key, value) in stored {
            let model = String(key.split(separator: "|", maxSplits: 1).last ?? "")
            var m = byModel[model] ?? (0, 0, 0)
            m.before += costsBefore[key] ?? 0
            m.after += value
            m.fresh += fresh[key] ?? 0
            byModel[model] = m
            if abs(value - (fresh[key] ?? 0)) > 1e-6 { mismatched += 1 }
        }
        log("at-time recompute: \(stored.count) (date, model) bucket(s), \(mismatched) differ from stored")
        #expect(mismatched == 0)
        for (model, m) in byModel.sorted(by: { $0.value.after > $1.value.after }) {
            log(String(format: "  %-28@ before $%10.2f  after $%10.2f  fresh $%10.2f  Δ %+9.2f  flagged %d",
                       model as NSString, m.before, m.after, m.fresh, m.after - m.before,
                       flagged[model] ?? 0))
        }

        // 3. Sonnet 5.5, day by day: the mispriced week.
        let sonnet = stored.keys.filter { $0.hasSuffix("|claude-sonnet-5-5") }.sorted()
        for key in sonnet {
            let b = costsBefore[key] ?? 0, a = stored[key] ?? 0
            if abs(a - b) > 0.005 {
                log(String(format: "  sonnet-5-5 %@ $%.2f → $%.2f", String(key.prefix(10)) as NSString, b, a))
            }
        }
    }
}
