import Foundation
import SwiftData

/// `ProjectDailyAggregate`, split by account.
///
/// Third in the pattern `AccountDailyAggregate` established, and the first
/// where the rollup carries more than sums: session and model counts, a last-
/// active timestamp, and three JSON side-tables. Those are computed by one
/// algorithm — `ProjectRollupValues.compute` — which both this and the global
/// rollup call, so the two cannot disagree about what a bucket contains.
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
    public var sessionCount: Int
    public var modelCount: Int
    public var lastActive: Date
    public var sessionIdsJSON: Data
    public var modelTokensJSON: Data
    public var modelCostJSON: Data

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
        lastActive: Date, sessionIdsJSON: Data, modelTokensJSON: Data,
        modelCostJSON: Data
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
        self.modelTokensJSON = modelTokensJSON
        self.modelCostJSON = modelCostJSON
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
    public var totalCostUSD: Double = 0
    public var sessionIds: Set<String> = []
    public var modelTokens: [String: Int64] = [:]
    public var modelCost: [String: Double] = [:]
    public var lastActive: Date = .distantPast

    public var sessionCount: Int { sessionIds.count }
    public var modelCount: Int { modelTokens.count }
    public var sessionIdsJSON: Data { (try? JSONEncoder().encode(Array(sessionIds))) ?? Data() }
    public var modelTokensJSON: Data { (try? JSONEncoder().encode(modelTokens)) ?? Data() }
    public var modelCostJSON: Data { (try? JSONEncoder().encode(modelCost)) ?? Data() }

    public init() {}

    /// Fold one sample in. Cost uses the same per-sample path every other
    /// rollup uses: prefer Claude Code's stored value when present, fall back
    /// to tokens × pricing. This was once `sourceCostUSD ?? 0`, which treated
    /// every line without a stored cost as free — the reason the Projects tab
    /// once showed $0 across the board.
    public mutating func add<S: AggregatableSample>(
        _ sample: S, mode: CostMode, snapshot: PricingTable.Snapshot
    ) {
        inputTokens += sample.breakdown.inputTokens
        outputTokens += sample.breakdown.outputTokens
        cacheReadTokens += sample.breakdown.cacheReadTokens
        cacheCreation5mTokens += sample.breakdown.cacheCreation5mTokens
        cacheCreation1hTokens += sample.breakdown.cacheCreation1hTokens

        let cost = CostCalculator.cost(
            storedCostUSD: sample.sourceCostUSD,
            model: sample.model,
            breakdown: sample.breakdown,
            mode: mode,
            snapshot: snapshot
        )
        totalCostUSD += cost
        if let sid = sample.sessionId, !sid.isEmpty { sessionIds.insert(sid) }
        modelTokens[sample.model, default: 0] +=
            sample.breakdown.inputTokens + sample.breakdown.outputTokens
        modelCost[sample.model, default: 0] += cost
        if sample.sampledAt > lastActive { lastActive = sample.sampledAt }
    }
}


/// The stored shape both project rollups share.
///
/// Lets `ProjectRollupValues` hydrate from and write back to either one, so
/// the decode-merge-encode the incremental path performs exists once rather
/// than once per table. Adding a fourth rollup means conforming, not copying.
public protocol ProjectRollupRow: AnyObject {
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
    var modelTokensJSON: Data { get set }
    var modelCostJSON: Data { get set }
}

extension ProjectDailyAggregate: ProjectRollupRow {}
extension AccountProjectDailyAggregate: ProjectRollupRow {}

public extension ProjectRollupValues {
    /// Rebuild the running totals from a stored row, so new samples can be
    /// folded in without re-reading the bucket's whole history.
    ///
    /// Empty or corrupt JSON decodes to nothing, which makes the bucket behave
    /// as though it had no prior contributors — the same result a first insert
    /// would produce, and the same tolerance the path had before this was
    /// shared.
    init(hydrating row: some ProjectRollupRow) {
        self.init()
        inputTokens = row.inputTokens
        outputTokens = row.outputTokens
        cacheReadTokens = row.cacheReadTokens
        cacheCreation5mTokens = row.cacheCreation5mTokens
        cacheCreation1hTokens = row.cacheCreation1hTokens
        totalCostUSD = row.totalCostUSD
        lastActive = row.lastActive
        let decoder = JSONDecoder()
        if !row.sessionIdsJSON.isEmpty,
           let decoded = try? decoder.decode([String].self, from: row.sessionIdsJSON) {
            sessionIds = Set(decoded)
        }
        if !row.modelTokensJSON.isEmpty,
           let decoded = try? decoder.decode([String: Int64].self, from: row.modelTokensJSON) {
            modelTokens = decoded
        }
        if !row.modelCostJSON.isEmpty,
           let decoded = try? decoder.decode([String: Double].self, from: row.modelCostJSON) {
            modelCost = decoded
        }
    }

    func write(to row: some ProjectRollupRow) {
        row.inputTokens = inputTokens
        row.outputTokens = outputTokens
        row.cacheReadTokens = cacheReadTokens
        row.cacheCreation5mTokens = cacheCreation5mTokens
        row.cacheCreation1hTokens = cacheCreation1hTokens
        row.totalCostUSD = totalCostUSD
        row.sessionCount = sessionCount
        row.modelCount = modelCount
        row.lastActive = lastActive
        row.sessionIdsJSON = sessionIdsJSON
        row.modelTokensJSON = modelTokensJSON
        row.modelCostJSON = modelCostJSON
    }
}


/// The read shape shared by both project rollups.
///
/// Lets the Projects view and `CollectionUsageRollup` consume either table
/// without knowing which, so the account scope is a change of source rather
/// than a second copy of the view.
public protocol ProjectDailyReadable {
    var projectPath: String { get }
    var date: String { get }
    var inputTokens: Int64 { get }
    var outputTokens: Int64 { get }
    var cacheReadTokens: Int64 { get }
    var totalCostUSD: Double { get }
    var sessionCount: Int { get }
    var modelCount: Int { get }
    var lastActive: Date { get }
    /// The per-model side-tables the project detail view breaks down by.
    var modelTokensJSON: Data { get }
    var modelCostJSON: Data { get }
}

extension ProjectDailyAggregate: ProjectDailyReadable {}
extension AccountProjectDailyAggregate: ProjectDailyReadable {}
