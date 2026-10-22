import Foundation
import SwiftData

/// `ProjectDailyAggregate`, split by account.
///
/// Third in the pattern `AccountDailyAggregate` established, and the first
/// where the rollup carries more than sums: session and model counts, a last-
/// active timestamp, and two JSON side-tables (session ids, and the bucket
/// split by model). Those are computed by one algorithm — `ProjectRollupValues`
/// — which both this and the global rollup call, so the two cannot disagree
/// about what a bucket contains.
///
/// See `AccountDailyAggregate` for why the global rollup's key is left alone,
/// and `make verify-data` for the check that keeps the two in step.
@Model
public final class AccountProjectDailyAggregate {
    /// `"<accountId>|<projectPath>|<date>"`.
    @Attribute(.unique) public var accountProjectDateKey: String

    public var accountId: String
    public var projectPath: String
    public var date: String

    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheCreation5mTokens: Int64
    public var cacheCreation1hTokens: Int64
    public var totalCostUSD: Double
    /// `totalCostUSD` split by category (#296). The total is always written
    /// as the sum of these five, so they agree by construction; see
    /// `RollupCostColumns`.
    public var costInput: Double = 0
    public var costOutput: Double = 0
    public var costCacheRead: Double = 0
    public var costCacheWrite5m: Double = 0
    public var costCacheWrite1h: Double = 0
    public var sessionCount: Int
    public var modelCount: Int
    public var lastActive: Date
    public var sessionIdsJSON: Data
    /// See `ProjectDailyAggregate.modelBreakdownJSON`.
    public var modelBreakdownJSON: Data?

    #Index<AccountProjectDailyAggregate>(
        [\.accountProjectDateKey],
        [\.date],
        [\.accountId, \.projectPath]
    )

    public static func makeKey(
        accountId: String, projectPath: String, date: String
    ) -> String {
        "\(accountId)|\(projectPath)|\(date)"
    }

    public init(
        accountId: String, projectPath: String, date: String,
        inputTokens: Int64, outputTokens: Int64, cacheReadTokens: Int64,
        cacheCreation5mTokens: Int64, cacheCreation1hTokens: Int64,
        totalCostUSD: Double, sessionCount: Int, modelCount: Int,
        lastActive: Date, sessionIdsJSON: Data, modelBreakdownJSON: Data?
    ) {
        self.accountProjectDateKey = Self.makeKey(
            accountId: accountId, projectPath: projectPath, date: date)
        self.accountId = accountId
        self.projectPath = projectPath
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.totalCostUSD = totalCostUSD
        self.sessionCount = sessionCount
        self.modelCount = modelCount
        self.lastActive = lastActive
        self.sessionIdsJSON = sessionIdsJSON
        self.modelBreakdownJSON = modelBreakdownJSON
    }
}

/// Everything a project-day bucket contains, computed once from its samples.
///
/// Factored out so the global rollup and the per-account one are written from
/// the *same* numbers rather than from two copies of the same loop. The
/// project rollup is the first with non-additive fields — distinct session
/// and model counts — where "recompute it twice" and "recompute it once and
/// write it twice" are genuinely different, because a session spanning an
/// account switch belongs to both accounts' sets and to one global set.
public struct ProjectRollupValues: Sendable {
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var cacheReadTokens: Int64 = 0
    public var cacheCreation5mTokens: Int64 = 0
    public var cacheCreation1hTokens: Int64 = 0
    /// Cost by category; `totalCostUSD` is its sum.
    public var cost = CostComponents.zero
    public var totalCostUSD: Double { cost.total }
    /// The ledger tokens behind `cost` (kept on the global rollup only —
    /// the per-account rows are rebuilt with their global bucket).
    public var pricedBy = PricedBy()
    public var sessionIds: Set<String> = []
    /// The bucket split by model: all five token parts and the cost of each.
    /// Summed per sample from the same `sample.breakdown` and the same priced
    /// components as the columns above, so the models add up to the row.
    public var modelBreakdowns: [String: CostBreakdown] = [:]
    public var lastActive: Date = .distantPast

    public var sessionCount: Int { sessionIds.count }
    public var modelCount: Int { modelBreakdowns.count }
    public var sessionIdsJSON: Data { (try? JSONEncoder().encode(Array(sessionIds))) ?? Data() }
    public var modelBreakdownJSON: Data { ProjectModelBreakdowns.encode(modelBreakdowns) }

    /// The five token columns as one value.
    public var tokens: TokenBreakdown {
        TokenBreakdown(
            inputTokens: inputTokens, outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreation5mTokens: cacheCreation5mTokens,
            cacheCreation1hTokens: cacheCreation1hTokens)
    }

    public init() {}

    /// Fold one sample in. Cost uses the same per-sample path every other
    /// rollup uses: prefer Claude Code's stored value when present, fall back
    /// to tokens × pricing. This was once `sourceCostUSD ?? 0`, which treated
    /// every line without a stored cost as free — the reason the Projects tab
    /// once showed $0 across the board.
    public mutating func add<S: AggregatableSample>(
        _ sample: S, mode: CostMode, snapshot: PricingTable.Snapshot
    ) {
        let tokens = sample.breakdown
        inputTokens += tokens.inputTokens
        outputTokens += tokens.outputTokens
        cacheReadTokens += tokens.cacheReadTokens
        cacheCreation5mTokens += tokens.cacheCreation5mTokens
        cacheCreation1hTokens += tokens.cacheCreation1hTokens

        let priced = CostCalculator.sampleCost(sample, mode: mode, snapshot: snapshot)
        cost += priced.components
        pricedBy.add(priced.pricedBy)
        if let sid = sample.sessionId, !sid.isEmpty { sessionIds.insert(sid) }
        // All five parts and their costs, as the columns take them. This was
        // input + output and a total only, so a project's By model card could
        // show neither its models' real tokens nor what each part cost.
        modelBreakdowns[sample.model, default: .zero] += CostBreakdown(
            cost: priced.components, tokens: tokens)
        if sample.sampledAt > lastActive { lastActive = sample.sampledAt }
    }
}


/// The stored shape both project rollups share.
///
/// Lets `ProjectRollupValues` hydrate from and write back to either one, so
/// the decode-merge-encode the incremental path performs exists once rather
/// than once per table. Adding a fourth rollup means conforming, not copying.
public protocol ProjectRollupRow: RollupCostColumns {
    var inputTokens: Int64 { get set }
    var outputTokens: Int64 { get set }
    var cacheReadTokens: Int64 { get set }
    var cacheCreation5mTokens: Int64 { get set }
    var cacheCreation1hTokens: Int64 { get set }
    var totalCostUSD: Double { get set }
    var sessionCount: Int { get set }
    var modelCount: Int { get set }
    var lastActive: Date { get set }
    var sessionIdsJSON: Data { get set }
    var modelBreakdownJSON: Data? { get set }
}

extension ProjectDailyAggregate: ProjectRollupRow {}
extension AccountProjectDailyAggregate: ProjectRollupRow {}

public extension ProjectRollupValues {
    /// Rebuild the running totals from a stored row, so new samples can be
    /// folded in without re-reading the bucket's whole history.
    ///
    /// Nil when the row's split by model cannot be advanced exactly: it does
    /// not decode, or its models' tokens do not add up to the row's own
    /// columns — a row written before the split was stored, or a corrupt one.
    /// Folding new samples into it would leave the models summing to less
    /// than the row for good, so the caller rebuilds the bucket from its
    /// samples instead. Corrupt session ids still decode to none, as they
    /// always have: an empty set is a legal value there (a bucket whose
    /// samples carried no session id), so emptiness proves nothing.
    init?(hydrating row: some ProjectRollupRow) {
        self.init()
        inputTokens = row.inputTokens
        outputTokens = row.outputTokens
        cacheReadTokens = row.cacheReadTokens
        cacheCreation5mTokens = row.cacheCreation5mTokens
        cacheCreation1hTokens = row.cacheCreation1hTokens
        cost = row.costComponents
        if let global = row as? ProjectDailyAggregate {
            pricedBy = PricedBy(stored: global.pricedByRecordIds)
        }
        lastActive = row.lastActive
        if !row.sessionIdsJSON.isEmpty,
           let decoded = try? JSONDecoder().decode([String].self, from: row.sessionIdsJSON) {
            sessionIds = Set(decoded)
        }
        guard let models = ProjectModelBreakdowns.decode(row.modelBreakdownJSON),
              models.count == row.modelCount,
              models.values.reduce(TokenBreakdown.zero, { $0 + $1.tokens }) == tokens
        else { return nil }
        modelBreakdowns = models
    }

    func write(to row: some ProjectRollupRow) {
        row.inputTokens = inputTokens
        row.outputTokens = outputTokens
        row.cacheReadTokens = cacheReadTokens
        row.cacheCreation5mTokens = cacheCreation5mTokens
        row.cacheCreation1hTokens = cacheCreation1hTokens
        row.costComponents = cost
        if let global = row as? ProjectDailyAggregate {
            let stored = pricedBy.stored
            if stored != global.pricedByRecordIds { global.pricedByRecordIds = stored }
        }
        row.sessionCount = sessionCount
        row.modelCount = modelCount
        row.lastActive = lastActive
        row.sessionIdsJSON = sessionIdsJSON
        row.modelBreakdownJSON = modelBreakdownJSON
    }
}


/// The read shape shared by both project rollups.
///
/// Lets the Projects view and `CollectionUsageRollup` consume either table
/// without knowing which, so the account scope is a change of source rather
/// than a second copy of the view.
public protocol ProjectDailyReadable: RollupTokenColumns {
    var projectPath: String { get }
    var date: String { get }
    var totalCostUSD: Double { get }
    /// `totalCostUSD` split into its five priced parts (#296); both tables
    /// get it from `RollupCostColumns`.
    var costComponents: CostComponents { get }
    var sessionCount: Int { get }
    var modelCount: Int { get }
    var lastActive: Date { get }
    /// The side-tables consumers break down by: the row split by model (read
    /// it as `modelBreakdowns`), and the distinct session ids the CSV export
    /// counts.
    var modelBreakdownJSON: Data? { get }
    var sessionIdsJSON: Data { get }
}

extension ProjectDailyAggregate: ProjectDailyReadable {}
extension AccountProjectDailyAggregate: ProjectDailyReadable {}
