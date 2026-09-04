import Foundation
import SwiftData

/// `SessionInfo`, split by account.
///
/// Fourth and last in the pattern. A session is the one rollup where the split
/// is genuinely a *split* rather than a partition of independent buckets: a
/// conversation that spans an account switch has real usage on both sides, so
/// it has a row per account and the global row is their sum. Its `firstSeenAt`
/// / `lastSeenAt` are that account's first and last turns within the session,
/// not the session's.
@Model
public final class AccountSessionInfo {
    /// `"<accountId>|<sessionId>"`.
    @Attribute(.unique) public var accountSessionKey: String

    public var accountId: String
    public var sessionId: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var projectPath: String
    public var ccVersion: String?
    public var cumulativeCostUSD: Double
    public var cumulativeInputTokens: Int64
    public var cumulativeOutputTokens: Int64
    public var cumulativeCacheReadTokens: Int64
    public var cumulativeCacheCreation5mTokens: Int64
    public var cumulativeCacheCreation1hTokens: Int64
    public var topModel: String

    #Index<AccountSessionInfo>(
        [\.accountSessionKey],
        [\.accountId],
        [\.lastSeenAt],
        // "This account's most recently touched session", which is what the
        // Now tile and the toolbar pill ask for under a scope.
        [\.accountId, \.lastSeenAt]
    )

    public static func makeKey(accountId: String, sessionId: String) -> String {
        "\(accountId)|\(sessionId)"
    }

    public init(
        accountId: String, sessionId: String,
        firstSeenAt: Date, lastSeenAt: Date, projectPath: String,
        ccVersion: String?, cumulativeCostUSD: Double,
        cumulativeInputTokens: Int64, cumulativeOutputTokens: Int64,
        cumulativeCacheReadTokens: Int64,
        cumulativeCacheCreation5mTokens: Int64,
        cumulativeCacheCreation1hTokens: Int64,
        topModel: String
    ) {
        self.accountSessionKey = Self.makeKey(accountId: accountId, sessionId: sessionId)
        self.accountId = accountId
        self.sessionId = sessionId
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.projectPath = projectPath
        self.ccVersion = ccVersion
        self.cumulativeCostUSD = cumulativeCostUSD
        self.cumulativeInputTokens = cumulativeInputTokens
        self.cumulativeOutputTokens = cumulativeOutputTokens
        self.cumulativeCacheReadTokens = cumulativeCacheReadTokens
        self.cumulativeCacheCreation5mTokens = cumulativeCacheCreation5mTokens
        self.cumulativeCacheCreation1hTokens = cumulativeCacheCreation1hTokens
        self.topModel = topModel
    }

    public var totalTokens: Int64 {
        cumulativeInputTokens + cumulativeOutputTokens + cumulativeCacheReadTokens
            + cumulativeCacheCreation5mTokens + cumulativeCacheCreation1hTokens
    }
}

/// Everything a session bucket contains, computed once from its samples.
///
/// Same purpose as `ProjectRollupValues`: `topModel` is chosen by comparing
/// per-model totals, which is not a sum, so the global and per-account rows
/// have to be produced by one algorithm rather than two copies of it.
public struct SessionRollupValues: Sendable {
    public var firstSeenAt: Date = .distantFuture
    public var lastSeenAt: Date = .distantPast
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var cacheReadTokens: Int64 = 0
    public var cacheCreation5mTokens: Int64 = 0
    public var cacheCreation1hTokens: Int64 = 0
    public var totalCostUSD: Double = 0
    public var modelTokens: [String: Int64] = [:]
    public var projectPath: String?
    public var ccVersion: String?
    public var firstModel: String?

    public init() {}

    /// The model with the most tokens, falling back to the first seen — the
    /// row's `topModel`.
    public var topModel: String {
        modelTokens.max { $0.value < $1.value }?.key ?? firstModel ?? ""
    }

    public mutating func add<S: AggregatableSample>(
        _ sample: S, mode: CostMode, snapshot: PricingTable.Snapshot
    ) {
        if sample.sampledAt < firstSeenAt { firstSeenAt = sample.sampledAt }
        if sample.sampledAt > lastSeenAt {
            lastSeenAt = sample.sampledAt
            ccVersion = sample.ccVersion ?? ccVersion
            projectPath = sample.projectPath ?? projectPath
        }
        inputTokens += sample.breakdown.inputTokens
        outputTokens += sample.breakdown.outputTokens
        cacheReadTokens += sample.breakdown.cacheReadTokens
        cacheCreation5mTokens += sample.breakdown.cacheCreation5mTokens
        cacheCreation1hTokens += sample.breakdown.cacheCreation1hTokens
        totalCostUSD += CostCalculator.cost(
            storedCostUSD: sample.sourceCostUSD,
            model: sample.model,
            breakdown: sample.breakdown,
            mode: mode,
            snapshot: snapshot
        )
        modelTokens[sample.model, default: 0] +=
            sample.breakdown.inputTokens + sample.breakdown.outputTokens
        if firstModel == nil { firstModel = sample.model }
    }
}
