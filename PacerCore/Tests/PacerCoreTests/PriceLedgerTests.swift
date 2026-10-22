import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// #296: the dated price ledger, at-time pricing, the curated file, catalog
/// change recording, and the component cost columns.
@Suite("Price ledger")
struct PriceLedgerTests {

    static let day: TimeInterval = 86_400
    static let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    static func rates(_ input: Double, read: Double? = nil) -> PriceRates {
        PriceRates(input: input / 1e6, output: input * 5 / 1e6,
                   cacheRead: (read ?? input * 0.1) / 1e6,
                   cacheWrite5m: input * 1.25 / 1e6, cacheWrite1h: input * 2 / 1e6)
    }

    static func record(
        _ model: String, _ rates: PriceRates, from: Date, to: Date? = nil,
        source: PriceSource = .litellm, reviewedAt: Date? = nil
    ) -> PriceRecordValue {
        PriceRecordValue(
            key: CanonicalModelID(model: model), rates: rates,
            effectiveFrom: from, effectiveTo: to, source: source, reviewedAt: reviewedAt)
    }

    static let oneMillionReads = TokenBreakdown(cacheReadTokens: 1_000_000)

    // MARK: At-time pricing

    @Test func samplesEitherSideOfABoundaryTakeTheirSidesRate() {
        let boundary = Self.t0.addingTimeInterval(10 * Self.day)
        let ledger = PriceLedger(records: [
            Self.record("claude-x", Self.rates(2, read: 0.2), from: Self.t0, to: boundary),
            Self.record("claude-x", Self.rates(2, read: 0.1), from: boundary),
        ])
        let before = ledger.cost(model: "claude-x", at: boundary.addingTimeInterval(-1),
                                 breakdown: Self.oneMillionReads)
        let after = ledger.cost(model: "claude-x", at: boundary, breakdown: Self.oneMillionReads)
        #expect(abs(before.total - 0.20) < 1e-9)
        #expect(abs(after.total - 0.10) < 1e-9)
        #expect(before.flags.isEmpty && after.flags.isEmpty)
    }

    @Test func pastUsageIsNeverRepricedAtTodaysRate() {
        // A price rise today must not touch yesterday.
        let today = Self.t0.addingTimeInterval(30 * Self.day)
        let ledger = PriceLedger(records: [
            Self.record("claude-x", Self.rates(2), from: Self.t0, to: today),
            Self.record("claude-x", Self.rates(3), from: today),
        ])
        let yesterday = ledger.cost(model: "claude-x", at: today.addingTimeInterval(-Self.day),
                                    breakdown: TokenBreakdown(inputTokens: 1_000_000))
        #expect(abs(yesterday.total - 2.0) < 1e-9)
    }

    @Test func aSampleBeforeEveryRecordIsPricedByTheEarliestAndFlagged() {
        let ledger = PriceLedger(records: [
            Self.record("claude-x", Self.rates(2), from: Self.t0),
            Self.record("claude-x", Self.rates(3), from: Self.t0.addingTimeInterval(Self.day)),
        ])
        let early = ledger.cost(model: "claude-x", at: Self.t0.addingTimeInterval(-Self.day),
                                breakdown: TokenBreakdown(inputTokens: 1_000_000))
        #expect(abs(early.total - 2.0) < 1e-9)
        #expect(early.flags.contains(.outsideWindow))
        #expect(early.pricedBy.first?.hasPrefix("~") == true)
    }

    @Test func noRecordAtAllIsUnpricedNotSilentlyFree() {
        let cost = PriceLedger.empty.cost(model: "claude-x", at: Self.t0,
                                          breakdown: TokenBreakdown(inputTokens: 1_000))
        #expect(cost.total == 0)
        #expect(cost.flags.contains(.unpriced))
        #expect(cost.pricedBy == [PriceLedger.noneToken(CanonicalModelID(model: "claude-x"))])
    }

    // MARK: Precedence

    @Test func curatedOutranksCatalog() {
        let ledger = PriceLedger(records: [
            Self.record("claude-x", Self.rates(2, read: 0.2), from: Self.t0),
            Self.record("claude-x", Self.rates(2, read: 0.1), from: Self.t0, source: .curated,
                        reviewedAt: Self.t0.addingTimeInterval(100 * Self.day)),
        ])
        let c = ledger.cost(model: "claude-x", at: Self.t0.addingTimeInterval(Self.day),
                            breakdown: Self.oneMillionReads)
        #expect(abs(c.total - 0.10) < 1e-9)
        #expect(c.pricedBy.first?.hasPrefix("curated|") == true)
    }

    @Test func aCatalogChangeAfterReviewOverridesAnOpenCuratedRecord() {
        let reviewed = Self.t0.addingTimeInterval(5 * Self.day)
        let change = Self.t0.addingTimeInterval(20 * Self.day)
        let ledger = PriceLedger(records: [
            Self.record("claude-x", Self.rates(2), from: Self.t0, source: .curated, reviewedAt: reviewed),
            Self.record("claude-x", Self.rates(2), from: Self.t0, to: change),
            Self.record("claude-x", Self.rates(3), from: change),
        ])
        let input = TokenBreakdown(inputTokens: 1_000_000)
        // Before the change the curated record decides; after it, the news.
        #expect(abs(ledger.cost(model: "claude-x", at: change.addingTimeInterval(-1), breakdown: input).total - 2) < 1e-9)
        #expect(abs(ledger.cost(model: "claude-x", at: change, breakdown: input).total - 3) < 1e-9)
    }

    @Test func aCatalogChangeTheReviewerSawDoesNotOverride() {
        let change = Self.t0.addingTimeInterval(20 * Self.day)
        let ledger = PriceLedger(records: [
            Self.record("claude-x", Self.rates(2), from: Self.t0, source: .curated,
                        reviewedAt: change.addingTimeInterval(Self.day)),
            Self.record("claude-x", Self.rates(3), from: change),
        ])
        let cost = ledger.cost(model: "claude-x", at: change.addingTimeInterval(Self.day),
                               breakdown: TokenBreakdown(inputTokens: 1_000_000))
        #expect(abs(cost.total - 2) < 1e-9)
    }

    // MARK: Components

    @Test func componentsSumToTheTotal() {
        let ledger = PriceLedger(records: [Self.record("claude-x", Self.rates(3), from: .distantPast)])
        let b = TokenBreakdown(inputTokens: 1_234, outputTokens: 5_678, cacheReadTokens: 91_011,
                               cacheCreation5mTokens: 1_213, cacheCreation1hTokens: 1_415)
        let c = ledger.cost(model: "claude-x", at: Self.t0, breakdown: b).components
        #expect(c.total == c.input + c.output + c.cacheRead + c.cacheWrite5m + c.cacheWrite1h)
        #expect(abs(c.input - 1_234 * 3e-6) < 1e-12)
        #expect(abs(c.cacheWrite1h - 1_415 * 6e-6) < 1e-12)
    }

    @Test func aStoredCostIsApportionedAndStillSumsToItself() {
        let ledger = PriceLedger(records: [Self.record("claude-x", Self.rates(3), from: .distantPast)])
        let b = TokenBreakdown(inputTokens: 1_000, outputTokens: 1_000)
        let auto = CostCalculator.sampleCost(
            storedCostUSD: 0.5, model: "claude-x", sampledAt: Self.t0, breakdown: b,
            mode: .auto, ledger: ledger)
        #expect(auto.total == 0.5)
        // Split like the priced cost: output is 5x input per token.
        #expect(abs(auto.components.output / auto.components.input - 5) < 1e-9)
        let display = CostCalculator.sampleCost(
            storedCostUSD: 0.5, model: "unknown-model", sampledAt: Self.t0, breakdown: b,
            mode: .display, ledger: ledger)
        #expect(display.total == 0.5)
    }

    // MARK: Curated file

    @Test func bundledCuratedFileDecodes() throws {
        let file = try CuratedPriceHistory.bundled()
        #expect(file.asOf > Date(timeIntervalSince1970: 1_760_000_000))
        #expect(file.records.allSatisfy { $0.curated })
    }

    @Test func curatedFileRatesArePerMillionAndDatesAreUTC() throws {
        let json = """
        {"schema":1,"asOf":"2026-10-21","records":[
          {"model":"claude-sonnet-5","effectiveFrom":"2026-06-30","effectiveTo":"2026-09-01",
           "perMTok":{"input":2,"output":10,"cacheWrite5m":2.5,"cacheWrite1h":4,"cacheRead":0.2},
           "note":"introductory"}]}
        """
        let file = try CuratedPriceHistory.decode(Data(json.utf8))
        let r = try #require(file.records.first)
        #expect(abs(r.rates.input - 2e-6) < 1e-18)
        #expect(abs(r.rates.cacheRead - 0.2e-6) < 1e-18)
        #expect(r.effectiveFrom == Date(timeIntervalSince1970: 1_782_777_600))   // 2026-06-30Z
        #expect(r.reviewedAt == file.asOf)
        #expect(r.key == CanonicalModelID(model: "claude-sonnet-5"))
    }

    @Test func aMalformedCuratedFileIsRejectedWhole() {
        let negative = """
        {"schema":1,"asOf":"2026-10-21","records":[{"model":"x","effectiveFrom":"2026-01-01",
          "perMTok":{"input":-1,"output":1,"cacheWrite5m":1,"cacheWrite1h":1,"cacheRead":1}}]}
        """
        #expect(throws: (any Error).self) { try CuratedPriceHistory.decode(Data(negative.utf8)) }
        let future = #"{"schema":2,"asOf":"2026-10-21","records":[]}"#
        #expect(throws: (any Error).self) { try CuratedPriceHistory.decode(Data(future.utf8)) }
    }

    // MARK: Catalog sync

    static func catalog(_ entries: [String: (Double, Double)]) -> [String: LiteLLMModelPricing] {
        entries.mapValues { input, read in
            LiteLLMModelPricing(
                inputCostPerToken: input / 1e6, outputCostPerToken: input * 5 / 1e6,
                cacheCreationInputTokenCost: input * 1.25 / 1e6,
                cacheCreationInputTokenCostAbove1hr: input * 2 / 1e6,
                cacheReadInputTokenCost: read / 1e6,
                inputCostPerTokenAbove200kTokens: nil, outputCostPerTokenAbove200kTokens: nil,
                cacheCreationInputTokenCostAbove200kTokens: nil,
                cacheReadInputTokenCostAbove200kTokens: nil,
                cacheCreationInputTokenCostAbove1hrAbove200kTokens: nil,
                maxInputTokens: nil, maxOutputTokens: nil)
        }
    }

    static func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(PacerStore.allModelTypes),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func anUnchangedRefreshWritesNoRecords() throws {
        let context = ModelContext(try Self.container())
        let catalog = Self.catalog(["claude-x": (2, 0.2)])
        let first = try PriceLedgerStore.sync(context: context, catalog: catalog, curated: .empty, now: Self.t0)
        #expect(first.opened.filter { $0.key.model == "claude-x" }.count == 1)
        let again = try PriceLedgerStore.sync(
            context: context, catalog: catalog, curated: .empty, now: Self.t0.addingTimeInterval(Self.day))
        #expect(!again.changed)
        #expect(try context.fetchCount(FetchDescriptor<PriceRecord>()) == first.ledger.records.count)
    }

    @Test func aChangedRefreshClosesTheOpenRecordAndOpensANewOne() throws {
        let context = ModelContext(try Self.container())
        _ = try PriceLedgerStore.sync(context: context, catalog: Self.catalog(["claude-x": (2, 0.2)]),
                                      curated: .empty, now: Self.t0)
        let change = Self.t0.addingTimeInterval(3 * Self.day)
        let result = try PriceLedgerStore.sync(
            context: context, catalog: Self.catalog(["claude-x": (2, 0.1)]), curated: .empty, now: change)
        #expect(result.closed.count == 1)
        #expect(result.opened.count == 1)
        let records = result.ledger.records(for: CanonicalModelID(model: "claude-x"))
        #expect(records.count == 2)
        #expect(records[0].effectiveTo == change && records[1].effectiveFrom == change)
        // At-time: before the change still prices at the old cache-read rate.
        let before = result.ledger.cost(model: "claude-x", at: change.addingTimeInterval(-60),
                                        breakdown: Self.oneMillionReads)
        #expect(abs(before.total - 0.2) < 1e-9)
    }

    @Test func aFirstSightingStartsAtTheCuratedStart() throws {
        let context = ModelContext(try Self.container())
        let launch = Self.t0.addingTimeInterval(-40 * Self.day)
        let curated = CuratedPriceHistory(asOf: Self.t0, records: [
            Self.record("claude-x", Self.rates(2), from: launch, to: launch.addingTimeInterval(Self.day),
                        source: .curated, reviewedAt: Self.t0),
        ])
        let result = try PriceLedgerStore.sync(
            context: context, catalog: Self.catalog(["claude-x": (2, 0.2)]), curated: curated, now: Self.t0)
        let catalogRecord = try #require(result.ledger.records(for: CanonicalModelID(model: "claude-x"))
            .first { !$0.curated })
        #expect(catalogRecord.effectiveFrom == launch)
    }

    @Test func aCatalogRefreshNeverTouchesCuratedRows() throws {
        let context = ModelContext(try Self.container())
        let curated = CuratedPriceHistory(asOf: Self.t0, records: [
            Self.record("claude-x", Self.rates(2, read: 0.1), from: Self.t0, source: .curated,
                        reviewedAt: Self.t0),
        ])
        _ = try PriceLedgerStore.sync(context: context, catalog: Self.catalog(["claude-x": (2, 0.2)]),
                                      curated: curated, now: Self.t0)
        let result = try PriceLedgerStore.sync(
            context: context, catalog: Self.catalog(["claude-x": (2, 0.3)]), curated: curated,
            now: Self.t0.addingTimeInterval(Self.day))
        let kept = try #require(result.ledger.records.first { $0.curated })
        #expect(kept == curated.records[0])
        #expect(result.curatedChanged == 0)
    }

    @Test func onlyTrackedModelsEnterTheLedger() {
        let catalog = Self.catalog(["claude-x": (2, 0.2), "gpt-9": (1, 0.1), "openrouter/claude-x": (9, 1)])
        let ids = Set(PriceLedger.catalogTemplates(catalog).map(\.key.model))
        #expect(ids.contains("claude-x"))
        #expect(!ids.contains("gpt-9"))
        #expect(!ids.contains("openrouter/claude-x"))
        let withUsed = PriceLedger.catalogTemplates(catalog, alsoInclude: [CanonicalModelID.parse("gpt-9")])
        #expect(withUsed.contains { $0.key.model == "gpt-9" })
    }
}

/// The invariant the component columns exist for, on every rollup a real
/// scan writes.
@Suite("Rollup cost components")
struct RollupCostComponentTests {

    @ScanActor
    @Test func componentsSumToTotalOnEveryRollupRow() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pacer-components-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("projects/-tmp-components")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var lines: [String] = []
        for (i, model) in ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"].enumerated() {
            for j in 0..<3 {
                lines.append("""
                {"type":"assistant","timestamp":"2026-10-0\(i + 1)T1\(j):00:00.000Z","sessionId":"s\(j)",\
                "cwd":"/tmp/p\(j)","requestId":"r\(i)\(j)","message":{"id":"m\(i)\(j)","model":"\(model)",\
                "stop_reason":"end_turn","usage":{"input_tokens":\(100 + j),"output_tokens":\(900 + i),\
                "cache_read_input_tokens":\(50_000 + j),"cache_creation_input_tokens":\(3_000 + i),\
                "cache_creation":{"ephemeral_5m_input_tokens":\(1_000 + i),"ephemeral_1h_input_tokens":2000}}}}
                """)
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let container = try PriceLedgerTests.container()
        await SampleCostCache.reload()
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .calculate, watcherMode: .manual, probeStatsCache: false),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path]))
        _ = try await coordinator.runOnce()

        let context = ModelContext(container)
        func check<T: PersistentModel & RollupCostColumns>(_ type: T.Type) throws -> Int {
            let rows = try context.fetch(FetchDescriptor<T>())
            for row in rows {
                let c = row.costComponents
                #expect(row.rollupTotalCostUSD == c.total, "\(T.self): \(row.rollupTotalCostUSD) vs \(c.total)")
                #expect(c.total > 0, "\(T.self) priced at zero")
            }
            return rows.count
        }
        let counts = [
            try check(DailyAggregate.self), try check(HourlyAggregate.self),
            try check(ProjectDailyAggregate.self), try check(SessionInfo.self),
            try check(AccountDailyAggregate.self), try check(AccountHourlyAggregate.self),
            try check(AccountProjectDailyAggregate.self), try check(AccountSessionInfo.self),
        ]
        // Unattributed account rows collapse into one in an in-memory store
        // (the NUL in `AccountDailyAggregate.unattributedKey` does not
        // survive storage), so only the global rollups' counts are pinned.
        #expect(Array(counts.prefix(4)) == [3, 9, 9, 3])
        #expect(counts.dropFirst(4).allSatisfy { $0 > 0 })

        // And every rollup slices the same spend.
        let daily = try context.fetch(FetchDescriptor<DailyAggregate>()).reduce(0) { $0 + $1.totalCostUSD }
        let sessions = try context.fetch(FetchDescriptor<SessionInfo>()).reduce(0) { $0 + $1.cumulativeCostUSD }
        #expect(abs(daily - sessions) < 1e-9)
        // The ledger was synced into the store.
        #expect(try context.fetchCount(FetchDescriptor<PriceRecord>()) > 0)
    }
}

/// Splitting Claude Code's stored `costUSD` into the five parts (#340).
@Suite("Stored cost split")
struct StoredCostSplitTests {
    static let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    static let tokens = TokenBreakdown(
        inputTokens: 1_000, outputTokens: 10_000, cacheReadTokens: 1_000_000,
        cacheCreation5mTokens: 20_000, cacheCreation1hTokens: 0)

    @Test("display mode splits a stored cost by what each part costs, not by tokens")
    func displayModeSplitsByPrice() {
        let rates = PriceRates(input: 2e-6, output: 10e-6, cacheRead: 0.2e-6,
                               cacheWrite5m: 2.5e-6, cacheWrite1h: 4e-6)
        let ledger = PriceLedger(records: [PriceRecordValue(
            key: CanonicalModelID(model: "claude-x"), rates: rates,
            effectiveFrom: .distantPast, source: .curated)])
        let cost = CostCalculator.sampleCost(
            storedCostUSD: 1.0, model: "claude-x", sampledAt: Self.t0,
            breakdown: Self.tokens, mode: .display, ledger: ledger)
        // Ledger cost: input 0.002, output 0.1, reads 0.2, 5m 0.05 = 0.352.
        let reads: Double = cost.components.cacheRead
        let output: Double = cost.components.output
        #expect(abs(cost.total - 1.0) < 1e-9)
        #expect(abs(reads - 0.2 / 0.352) < 1e-9)
        #expect(abs(output - 0.1 / 0.352) < 1e-9)
    }

    @Test("an unpriced model's stored cost is split at list-price ratios")
    func unpricedFallsBackToListRatios() {
        let parts = CostComponents.apportion(1.0, like: .zero, tokens: Self.tokens)
        // Weights: input 1,000×1 + output 10,000×5 + reads 1,000,000×0.1
        //          + 5m 20,000×1.25 = 176,000.
        let reads: Double = parts.cacheRead
        let output: Double = parts.output
        #expect(abs(reads - 100_000.0 / 176_000.0) < 1e-9)
        #expect(abs(output - 50_000.0 / 176_000.0) < 1e-9)
        #expect(abs(parts.total - 1.0) < 1e-9)
    }
}
