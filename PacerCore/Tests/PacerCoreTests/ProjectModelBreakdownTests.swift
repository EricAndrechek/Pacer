import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The project rollups' split by model (`modelBreakdownJSON`, cost recompute
/// "19"): every model's five token parts and the cost of each, summed per
/// sample beside the row's own columns, through every write path.
@Suite("Project model breakdowns")
struct ProjectModelBreakdownTests {

    static let day: TimeInterval = 86_400
    /// Midday UTC, so a date string is the same day in any test timezone.
    static let d0 = Date(timeIntervalSince1970: 1_790_078_400)   // 2026-09-22 12:00Z

    static let models = ["claude-x", "claude-y", "claude-z"]

    /// A distinct rate per part, so a part priced at another's rate shows.
    static let rates = PriceRates(input: 3e-6, output: 15e-6, cacheRead: 0.3e-6,
                                  cacheWrite5m: 3.75e-6, cacheWrite1h: 6e-6)

    static let pricing = PricingTable.Snapshot(pricingByModel: [:], ledger: PriceLedger(records: models.map {
        PriceRecordValue(key: CanonicalModelID(model: $0), rates: rates,
                         effectiveFrom: .distantPast, effectiveTo: nil, source: .litellm, reviewedAt: nil)
    }))

    static func container() throws -> ModelContainer {
        try ModelContainer(for: Schema(PacerStore.allModelTypes),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// A different magnitude per part, and a different value per sample, so
    /// a part summed into another's field cannot land on the right number.
    static func tokens(_ i: Int) -> TokenBreakdown {
        let n = Int64(i)
        return TokenBreakdown(inputTokens: 11 + n, outputTokens: 2_200 + 3 * n,
                              cacheReadTokens: 330_000 + 7 * n, cacheCreation5mTokens: 44_000 + 5 * n,
                              cacheCreation1hTokens: 5_500 + 11 * n)
    }

    struct Spec {
        var dayIndex: Int
        var model: String
        var project: String
        var account: String?
        var i: Int
        var storedCost: Double? = nil
    }

    @discardableResult
    static func insert(_ specs: [Spec], into context: ModelContext) -> [TokenSample] {
        specs.map { spec in
            let at = d0.addingTimeInterval(Double(spec.dayIndex) * day + Double(spec.i))
            let t = tokens(spec.i)
            let s = TokenSample(
                sampledAt: at, date: TokenSample.formatDate(at), model: spec.model,
                inputTokens: t.inputTokens, outputTokens: t.outputTokens,
                cacheReadTokens: t.cacheReadTokens, cacheCreation5mTokens: t.cacheCreation5mTokens,
                cacheCreation1hTokens: t.cacheCreation1hTokens, sourceCostUSD: spec.storedCost,
                dedupKey: "m\(spec.i):r\(spec.i)", sessionId: "s-\(spec.i % 4)",
                projectPath: spec.project)
            s.accountId = spec.account
            context.insert(s)
            return s
        }
    }

    static func pairs(_ samples: [TokenSample]) -> Set<ProjectDatePair> {
        Set(samples.map { ProjectDatePair(projectPath: $0.projectPath!, date: $0.date) })
    }

    /// Three models over two projects and three accounts, some turns with
    /// Claude Code's stored cost (apportioned) and some priced.
    ///
    /// No unattributed turns: `AccountDailyAggregate.unattributedKey` starts
    /// with U+0000, which SQLite truncates, so every unattributed per-account
    /// row of a table reads back as "" and they collide on one unique key.
    /// That is its own bug, reported separately; these tests are about the
    /// split.
    static func mixedSpecs(days: Int) -> [Spec] {
        var out: [Spec] = []
        var i = 0
        for d in 0..<days {
            for (m, model) in models.enumerated() {
                for project in ["/acme/app", "/globex/site"] where (d + m) % 3 != 2 || project == "/acme/app" {
                    i += 1
                    let account: String? = ["acct-1", "acct-2", "acct-3"][i % 3]
                    out.append(Spec(dayIndex: d, model: model, project: project, account: account, i: i,
                                    storedCost: i % 4 == 0 ? 0.01 * Double(i) : nil))
                }
            }
        }
        return out
    }

    @ScanActor
    static func recompute(_ pairs: Set<ProjectDatePair>, container: ModelContainer, context: ModelContext,
                          chunk: Int? = nil) async throws {
        let r = ProjectAggregateRecomputer(container: container, context: context, mode: .auto, pricing: pricing)
        if let chunk {
            let ordered = pairs.sorted { ($0.date, $0.projectPath) < ($1.date, $1.projectPath) }
            for start in stride(from: 0, to: ordered.count, by: chunk) {
                let slice = Set(ordered[start..<min(start + chunk, ordered.count)])
                _ = try await r.recompute(pairs: slice, polluted: slice)
            }
        } else {
            _ = try await r.recompute(pairs: pairs, polluted: pairs)
        }
        try context.save()
    }

    /// Fails unless the row's models add up to its own columns: tokens
    /// exactly, cost per part and in total to float rounding.
    static func expectSplitSumsToRow(_ row: any ProjectDailyReadable, sourceLocation: SourceLocation = #_sourceLocation) {
        let models = row.modelBreakdowns
        #expect(models.count == row.modelCount, sourceLocation: sourceLocation)
        #expect(!models.isEmpty, sourceLocation: sourceLocation)
        let sum = models.values.reduce(CostBreakdown.zero, +)
        #expect(sum.tokens == row.tokens, "\(row.projectPath) \(row.date)", sourceLocation: sourceLocation)
        for part in CostComponent.allCases {
            #expect(abs(sum.cost[part] - row.costComponents[part]) < 1e-12,
                    "\(part) \(row.projectPath) \(row.date)", sourceLocation: sourceLocation)
        }
        #expect(abs(sum.total - row.totalCostUSD) < 1e-12, sourceLocation: sourceLocation)
    }

    // MARK: - Encoding

    @Test func theStoredFormIsPinned() throws {
        // `make verify-data` reads these positions in SQL, so they are a
        // format, not an implementation detail.
        let b = CostBreakdown(
            cost: CostComponents(input: 0.5, output: 0.25, cacheRead: 0.125, cacheWrite5m: 2, cacheWrite1h: 4),
            tokens: TokenBreakdown(inputTokens: 1, outputTokens: 20, cacheReadTokens: 300,
                                   cacheCreation5mTokens: 4_000, cacheCreation1hTokens: 50_000))
        let data = ProjectModelBreakdowns.encode(["m-b": b, "m-a": .zero])
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text == #"{"m-a":{"c":[0,0,0,0,0],"t":[0,0,0,0,0]},"#
            + #""m-b":{"c":[0.5,0.25,0.125,2,4],"t":[1,20,300,4000,50000]}}"#)
    }

    @Test func eachPartRoundTripsToItsOwnField() throws {
        let b = CostBreakdown(
            cost: CostComponents(input: 0.1, output: 0.02, cacheRead: 0.003, cacheWrite5m: 0.0004,
                                 cacheWrite1h: 1.0 / 3.0),
            tokens: TokenBreakdown(inputTokens: 1, outputTokens: 20, cacheReadTokens: 300,
                                   cacheCreation5mTokens: 4_000, cacheCreation1hTokens: Int64.max / 3))
        let decoded = try #require(ProjectModelBreakdowns.decode(ProjectModelBreakdowns.encode(["m": b])))
        #expect(decoded == ["m": b])
        let got = try #require(decoded["m"])
        #expect(got.tokens.cacheCreation1hTokens == Int64.max / 3)
        #expect(got.cost.cacheWrite1h == 1.0 / 3.0)   // exact, not near
    }

    @Test func absentDataIsNoModelsAndMalformedDataIsNotASplit() {
        #expect(ProjectModelBreakdowns.decode(nil) == [:])
        #expect(ProjectModelBreakdowns.decode(Data()) == [:])
        #expect(ProjectModelBreakdowns.decode(Data("not json".utf8)) == nil)
        // The shape the old `modelTokensJSON` stored.
        #expect(ProjectModelBreakdowns.decode(Data(#"{"m":123}"#.utf8)) == nil)
        // Four parts, not five.
        #expect(ProjectModelBreakdowns.decode(Data(#"{"m":{"c":[0,0,0,0],"t":[0,0,0,0,0]}}"#.utf8)) == nil)
    }

    // MARK: - Write paths

    @ScanActor
    @Test func eachPartLandsInItsOwnFieldAtItsOwnPrice() async throws {
        let container = try Self.container()
        let context = ModelContext(container)
        let samples = Self.insert([Spec(dayIndex: 0, model: "claude-x", project: "/acme/app", account: nil, i: 0)],
                                  into: context)
        try context.save()
        try await Self.recompute(Self.pairs(samples), container: container, context: context)

        let row = try #require(try context.fetch(FetchDescriptor<ProjectDailyAggregate>()).first)
        let got = try #require(row.modelBreakdowns["claude-x"])
        let t = Self.tokens(0)
        #expect(got.tokens == t)
        #expect(got.cost.input == Double(t.inputTokens) * Self.rates.input)
        #expect(got.cost.output == Double(t.outputTokens) * Self.rates.output)
        #expect(got.cost.cacheRead == Double(t.cacheReadTokens) * Self.rates.cacheRead)
        #expect(got.cost.cacheWrite5m == Double(t.cacheCreation5mTokens) * Self.rates.cacheWrite5m)
        #expect(got.cost.cacheWrite1h == Double(t.cacheCreation1hTokens) * Self.rates.cacheWrite1h)
        #expect(got.cost == row.costComponents)
        #expect(got.tokens == row.tokens)
    }

    @ScanActor
    @Test func perPairPathSplitSumsToEveryRowAndToEachModelsSamples() async throws {
        let container = try Self.container()
        let context = ModelContext(container)
        let samples = Self.insert(Self.mixedSpecs(days: 4), into: context)
        try context.save()
        let pairs = Self.pairs(samples)
        #expect(pairs.count < 64)   // the per-pair path
        try await Self.recompute(pairs, container: container, context: context)

        let rows = try context.fetch(FetchDescriptor<ProjectDailyAggregate>())
        #expect(rows.count == pairs.count)
        for row in rows {
            Self.expectSplitSumsToRow(row)
            // And each model holds exactly its own samples' tokens.
            for (model, b) in row.modelBreakdowns {
                let own = samples.filter { $0.projectPath == row.projectPath && $0.date == row.date
                    && $0.model == model }
                #expect(b.tokens == own.reduce(TokenBreakdown.zero) { $0 + $1.breakdown })
                let cost = own.reduce(CostComponents.zero) {
                    $0 + CostCalculator.sampleCost($1, mode: .auto, snapshot: Self.pricing).components
                }
                #expect(abs(b.cost.total - cost.total) < 1e-12)
            }
        }
    }

    @ScanActor
    @Test func perAccountRowsSplitByModelAndSumToTheGlobalSplit() async throws {
        let container = try Self.container()
        let context = ModelContext(container)
        let samples = Self.insert(Self.mixedSpecs(days: 3), into: context)
        try context.save()
        try await Self.recompute(Self.pairs(samples), container: container, context: context)

        let global = try context.fetch(FetchDescriptor<ProjectDailyAggregate>())
        let scoped = try context.fetch(FetchDescriptor<AccountProjectDailyAggregate>())
        #expect(Set(scoped.map(\.accountId)) == ["acct-1", "acct-2", "acct-3"])
        for row in scoped { Self.expectSplitSumsToRow(row) }
        for g in global {
            let accounts: [any ProjectDailyReadable] = scoped.filter {
                $0.projectPath == g.projectPath && $0.date == g.date
            }
            let summed = ProjectModelBreakdowns.sum(accounts)
            #expect(Set(summed.keys) == Set(g.modelBreakdowns.keys))
            for (model, b) in g.modelBreakdowns {
                #expect(summed[model]?.tokens == b.tokens)
                #expect(abs((summed[model]?.total ?? -1) - b.total) < 1e-12)
            }
        }
    }

    /// Every project and per-account row, with its split, as comparable text.
    /// Costs to 1e-9 dollars: the paths add the same samples in different
    /// orders, which moves the last bits of a sum.
    @ScanActor
    static func dump(_ context: ModelContext) throws -> [String] {
        func split(_ row: any ProjectDailyReadable) -> String {
            row.modelBreakdowns.sorted { $0.key < $1.key }.map { model, b in
                let parts = CostComponent.allCases.map { "\(b.tokens[$0]):\((b.cost[$0] * 1e9).rounded())" }
                return "\(model)=" + parts.joined(separator: ",")
            }.joined(separator: " ")
        }
        let global = try context.fetch(FetchDescriptor<ProjectDailyAggregate>()).map {
            "G \($0.projectDateKey) \($0.modelCount) \($0.sessionCount) \(split($0))"
        }
        let scoped = try context.fetch(FetchDescriptor<AccountProjectDailyAggregate>()).map {
            "A \($0.accountProjectDateKey) \($0.modelCount) \($0.sessionCount) \(split($0))"
        }
        return (global + scoped).sorted()
    }

    @ScanActor
    @Test func bulkPathEqualsPerPairPath() async throws {
        let specs = Self.mixedSpecs(days: 40)
        let bulkContainer = try Self.container()
        let bulk = ModelContext(bulkContainer)
        let pairs = Self.pairs(Self.insert(specs, into: bulk))
        try bulk.save()
        #expect(pairs.count >= 64)   // the bulk worker
        try await Self.recompute(pairs, container: bulkContainer, context: bulk)

        let perPairContainer = try Self.container()
        let perPair = ModelContext(perPairContainer)
        Self.insert(specs, into: perPair)
        try perPair.save()
        try await Self.recompute(pairs, container: perPairContainer, context: perPair, chunk: 20)

        let a = try Self.dump(ModelContext(bulkContainer))
        let b = try Self.dump(ModelContext(perPairContainer))
        #expect(a.count == b.count)
        #expect(a == b)
        for row in try ModelContext(bulkContainer).fetch(FetchDescriptor<ProjectDailyAggregate>()) {
            Self.expectSplitSumsToRow(row)
        }
    }

    @ScanActor
    @Test func fastPathEqualsAFullRebuild() async throws {
        let container = try Self.container()
        let context = ModelContext(container)
        let persister = try SamplePersister(context: context)
        let recomputer = ProjectAggregateRecomputer(container: container, context: context,
                                                    mode: .auto, pricing: Self.pricing)
        func entry(_ i: Int, _ model: String) -> ParsedUsageEntry {
            ParsedUsageEntry(timestamp: Self.d0.addingTimeInterval(Double(i)), model: model,
                             breakdown: Self.tokens(i), storedCostUSD: nil, dedupKey: "m\(i):r\(i)",
                             sessionId: "s-1", projectPath: "/acme/app", claudeCodeVersion: nil,
                             isApiErrorMessage: false)
        }
        _ = try persister.insert(entry(1, "claude-x"))
        try persister.flush()
        _ = try await recomputer.recompute(pairs: persister.dirtyProjectDates)
        try context.save()

        // A later cycle's turns, one of them a model the row has not seen.
        persister.clearDirtyPairs()
        _ = try persister.insert(entry(2, "claude-x"))
        _ = try persister.insert(entry(3, "claude-y"))
        try persister.flush()
        let fast = try await recomputer.recompute(
            pairs: persister.dirtyProjectDates, pending: persister.pendingProjectSamples,
            polluted: persister.pollutedProjectPairs)
        #expect(fast.fastPathApplied == 1)
        try context.save()
        let afterFast = try Self.dump(context)
        let row = try #require(try context.fetch(FetchDescriptor<ProjectDailyAggregate>()).first)
        Self.expectSplitSumsToRow(row)
        #expect(row.modelCount == 2)

        let pair = ProjectDatePair(projectPath: "/acme/app", date: row.date)
        let full = try await recomputer.recompute(pairs: [pair], polluted: [pair])
        #expect(full.fastPathApplied == 0)
        try context.save()
        #expect(try Self.dump(context) == afterFast)
    }

    @ScanActor
    @Test func fastPathRebuildsARowWrittenBeforeTheSplit() async throws {
        // A row from before cost recompute "19" has columns but no split.
        // Adding a turn's share to it would leave its models summing to one
        // turn; the bucket is rebuilt from its samples instead.
        let container = try Self.container()
        let context = ModelContext(container)
        let persister = try SamplePersister(context: context)
        let recomputer = ProjectAggregateRecomputer(container: container, context: context,
                                                    mode: .auto, pricing: Self.pricing)
        func entry(_ i: Int) -> ParsedUsageEntry {
            ParsedUsageEntry(timestamp: Self.d0.addingTimeInterval(Double(i)), model: "claude-x",
                             breakdown: Self.tokens(i), storedCostUSD: nil, dedupKey: "m\(i):r\(i)",
                             sessionId: "s-1", projectPath: "/acme/app", claudeCodeVersion: nil,
                             isApiErrorMessage: false)
        }
        _ = try persister.insert(entry(1))
        try persister.flush()
        _ = try await recomputer.recompute(pairs: persister.dirtyProjectDates)
        for row in try context.fetch(FetchDescriptor<ProjectDailyAggregate>()) { row.modelBreakdownJSON = nil }
        for row in try context.fetch(FetchDescriptor<AccountProjectDailyAggregate>()) { row.modelBreakdownJSON = nil }
        try context.save()

        persister.clearDirtyPairs()
        _ = try persister.insert(entry(2))
        try persister.flush()
        let stats = try await recomputer.recompute(
            pairs: persister.dirtyProjectDates, pending: persister.pendingProjectSamples,
            polluted: persister.pollutedProjectPairs)
        #expect(stats.fastPathApplied == 0)
        try context.save()
        let row = try #require(try context.fetch(FetchDescriptor<ProjectDailyAggregate>()).first)
        Self.expectSplitSumsToRow(row)
        #expect(row.modelBreakdowns["claude-x"]?.tokens == Self.tokens(1) + Self.tokens(2))
        for scoped in try context.fetch(FetchDescriptor<AccountProjectDailyAggregate>()) {
            Self.expectSplitSumsToRow(scoped)
        }
    }

    // MARK: - Read API

    @ScanActor
    @Test func sumAcrossAProjectsDaysEqualsItsTotals() async throws {
        let container = try Self.container()
        let context = ModelContext(container)
        let samples = Self.insert(Self.mixedSpecs(days: 5), into: context)
        try context.save()
        try await Self.recompute(Self.pairs(samples), container: container, context: context)

        let rows: [any ProjectDailyReadable] = try context.fetch(FetchDescriptor<ProjectDailyAggregate>())
            .filter { $0.projectPath == "/acme/app" }
        let byModel = ProjectModelBreakdowns.sum(rows)
        let totals = ProjectUsageTotals(rows: rows)
        #expect(Set(byModel.keys) == Set(Self.models))
        #expect(byModel.values.reduce(TokenBreakdown.zero) { $0 + $1.tokens } == totals.tokens)
        #expect(abs(byModel.values.reduce(0) { $0 + $1.total } - totals.cost) < 1e-9)
        for model in Self.models {
            let own = samples.filter { $0.projectPath == "/acme/app" && $0.model == model }
            #expect(byModel[model]?.tokens == own.reduce(TokenBreakdown.zero) { $0 + $1.breakdown })
        }
    }

    // MARK: - Rebuild

    @ScanActor
    @Test func costRecomputeNineteenFillsTheSplitOnStoredRows() async throws {
        #expect(ScanCoordinator.currentCostRecomputeVersion == "19")

        // A store as "18" left it: samples, and a project row with its
        // columns but no split.
        let container = try Self.container()
        let context = ModelContext(container)
        let samples = Self.insert(Self.mixedSpecs(days: 2), into: context)
        try await Self.recompute(Self.pairs(samples), container: container, context: context)
        for row in try context.fetch(FetchDescriptor<ProjectDailyAggregate>()) { row.modelBreakdownJSON = nil }
        for row in try context.fetch(FetchDescriptor<AccountProjectDailyAggregate>()) { row.modelBreakdownJSON = nil }
        context.insert(ClaudeCodeMeta(key: ClaudeCodeMetaKey.costRecomputeVersion, value: "18"))
        try context.save()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pacer-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ScanCoordinator(
            container: container,
            configuration: .init(costMode: .display, watcherMode: .manual, probeStatsCache: false),
            resolver: ClaudePathResolver(environment: ["CLAUDE_CONFIG_DIR": root.path]),
            homeDirectory: root)
        _ = try await coordinator.runOnce()

        let after = ModelContext(container)
        let key = ClaudeCodeMetaKey.costRecomputeVersion
        let version = try after.fetch(FetchDescriptor<ClaudeCodeMeta>(predicate: #Predicate { $0.key == key }))
        #expect(version.first?.value == "19")
        let rows = try after.fetch(FetchDescriptor<ProjectDailyAggregate>())
        #expect(rows.count == Self.pairs(samples).count)
        for row in rows { Self.expectSplitSumsToRow(row) }
        for row in try after.fetch(FetchDescriptor<AccountProjectDailyAggregate>()) { Self.expectSplitSumsToRow(row) }
    }

    // MARK: - Session top model

    @ScanActor
    @Test func sessionTopModelCountsEveryPart() async throws {
        // claude-x has more input + output; claude-y moved far more tokens,
        // nearly all cache reads — what a Claude Code session is made of.
        let container = try Self.container()
        let context = ModelContext(container)
        for (i, (model, t)) in [
            ("claude-x", TokenBreakdown(inputTokens: 5_000, outputTokens: 5_000)),
            ("claude-y", TokenBreakdown(inputTokens: 10, outputTokens: 10, cacheReadTokens: 900_000)),
        ].enumerated() {
            let at = Self.d0.addingTimeInterval(Double(i))
            context.insert(TokenSample(
                sampledAt: at, date: TokenSample.formatDate(at), model: model,
                inputTokens: t.inputTokens, outputTokens: t.outputTokens, cacheReadTokens: t.cacheReadTokens,
                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, dedupKey: "m\(i):r\(i)",
                sessionId: "sess", projectPath: "/acme/app"))
        }
        try context.save()
        _ = try await SessionInfoRecomputer(container: container, context: context, mode: .auto,
                                            pricing: Self.pricing)
            .recompute(sessionIds: ["sess"], polluted: ["sess"])
        try context.save()
        #expect(try context.fetch(FetchDescriptor<SessionInfo>()).first?.topModel == "claude-y")
        #expect(try context.fetch(FetchDescriptor<AccountSessionInfo>()).first?.topModel == "claude-y")
    }
}

@Suite("Unattributed sentinel")
struct UnattributedSentinelTests {
    @Test("unattributed rows survive a save: the key is not cut short by SQLite")
    func unattributedRowsRoundTrip() throws {
        let container = try ModelContainer(
            for: AccountDailyAggregate.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let key: String = AccountDailyAggregate.unattributedKey
        for date in ["2026-10-01", "2026-10-02"] {
            context.insert(AccountDailyAggregate(
                accountId: key, date: date, model: "claude-x",
                inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
                cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: 0))
        }
        try context.save()
        let rows: [AccountDailyAggregate] = try ModelContext(container).fetch(FetchDescriptor<AccountDailyAggregate>())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.accountId == key })
    }
}
