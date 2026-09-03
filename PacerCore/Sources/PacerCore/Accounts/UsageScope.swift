import Foundation
import SwiftData

/// One row of a daily rollup, independent of which table it came from.
///
/// `DailyAggregate` (all accounts) and `AccountDailyAggregate` (one account)
/// hold the same numbers sliced differently, and a card should not care which
/// it is rendering. Normalising at the boundary means the scope switch is a
/// change of source, not a second copy of every card.
public struct DailyRow: Sendable, Equatable, Identifiable {
    public let date: String
    public let model: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheCreation5mTokens: Int64
    public let cacheCreation1hTokens: Int64
    public let totalCostUSD: Double

    public var id: String { "\(date)|\(model)" }
    public var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadTokens
            + cacheCreation5mTokens + cacheCreation1hTokens
    }

    public init(
        date: String, model: String,
        inputTokens: Int64, outputTokens: Int64, cacheReadTokens: Int64,
        cacheCreation5mTokens: Int64, cacheCreation1hTokens: Int64,
        totalCostUSD: Double
    ) {
        self.date = date
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.totalCostUSD = totalCostUSD
    }
}

public extension DailyAggregate {
    var dailyRow: DailyRow {
        DailyRow(date: date, model: model,
                 inputTokens: inputTokens, outputTokens: outputTokens,
                 cacheReadTokens: cacheReadTokens,
                 cacheCreation5mTokens: cacheCreation5mTokens,
                 cacheCreation1hTokens: cacheCreation1hTokens,
                 totalCostUSD: totalCostUSD)
    }
}

public extension AccountDailyAggregate {
    var dailyRow: DailyRow {
        DailyRow(date: date, model: model,
                 inputTokens: inputTokens, outputTokens: outputTokens,
                 cacheReadTokens: cacheReadTokens,
                 cacheCreation5mTokens: cacheCreation5mTokens,
                 cacheCreation1hTokens: cacheCreation1hTokens,
                 totalCostUSD: totalCostUSD)
    }
}

/// One row of an hourly rollup, independent of which table it came from.
/// The hourly counterpart to `DailyRow`.
public struct HourlyRow: Sendable, Equatable, Identifiable {
    public let date: String
    public let hour: Int
    public let model: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let totalCostUSD: Double
    /// Turns in the bucket. The global rollup stores it; the per-account one
    /// does not, so a scoped row reports 0 — used only for a "quiet hour"
    /// hint, never for a number the user reads.
    public let sampleCount: Int

    public var id: String { "\(date)|\(hour)|\(model)" }

    public init(date: String, hour: Int, model: String,
                inputTokens: Int64, outputTokens: Int64, totalCostUSD: Double,
                sampleCount: Int = 0) {
        self.date = date
        self.hour = hour
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalCostUSD = totalCostUSD
        self.sampleCount = sampleCount
    }
}

public extension HourlyAggregate {
    var hourlyRow: HourlyRow {
        HourlyRow(date: date, hour: hour, model: model,
                  inputTokens: inputTokens, outputTokens: outputTokens,
                  totalCostUSD: totalCostUSD, sampleCount: sampleCount)
    }
}

public extension AccountHourlyAggregate {
    var hourlyRow: HourlyRow {
        HourlyRow(date: date, hour: hour, model: model,
                  inputTokens: inputTokens, outputTokens: outputTokens,
                  totalCostUSD: totalCostUSD)
    }
}

/// One session, independent of which table it came from.
///
/// Completes the set alongside `DailyRow` and `HourlyRow` so the drill-down
/// modals can render either the global or the per-account session table.
public struct SessionRow: Sendable, Equatable, Identifiable {
    public let sessionId: String
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let projectPath: String
    public let ccVersion: String?
    public let cumulativeCostUSD: Double
    public let cumulativeInputTokens: Int64
    public let cumulativeOutputTokens: Int64
    public let cumulativeCacheReadTokens: Int64
    public let cumulativeCacheCreation5mTokens: Int64
    public let cumulativeCacheCreation1hTokens: Int64
    public let topModel: String

    public var id: String { sessionId }
    public var totalTokens: Int64 {
        cumulativeInputTokens + cumulativeOutputTokens + cumulativeCacheReadTokens
            + cumulativeCacheCreation5mTokens + cumulativeCacheCreation1hTokens
    }

    public init(
        sessionId: String, firstSeenAt: Date, lastSeenAt: Date, projectPath: String,
        ccVersion: String?, cumulativeCostUSD: Double,
        cumulativeInputTokens: Int64, cumulativeOutputTokens: Int64,
        cumulativeCacheReadTokens: Int64, cumulativeCacheCreation5mTokens: Int64,
        cumulativeCacheCreation1hTokens: Int64, topModel: String
    ) {
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
}

public extension SessionInfo {
    var sessionRow: SessionRow {
        SessionRow(
            sessionId: sessionId, firstSeenAt: firstSeenAt, lastSeenAt: lastSeenAt,
            projectPath: projectPath, ccVersion: ccVersion,
            cumulativeCostUSD: cumulativeCostUSD,
            cumulativeInputTokens: cumulativeInputTokens,
            cumulativeOutputTokens: cumulativeOutputTokens,
            cumulativeCacheReadTokens: cumulativeCacheReadTokens,
            cumulativeCacheCreation5mTokens: cumulativeCacheCreation5mTokens,
            cumulativeCacheCreation1hTokens: cumulativeCacheCreation1hTokens,
            topModel: topModel)
    }
}

public extension AccountSessionInfo {
    var sessionRow: SessionRow {
        SessionRow(
            sessionId: sessionId, firstSeenAt: firstSeenAt, lastSeenAt: lastSeenAt,
            projectPath: projectPath, ccVersion: ccVersion,
            cumulativeCostUSD: cumulativeCostUSD,
            cumulativeInputTokens: cumulativeInputTokens,
            cumulativeOutputTokens: cumulativeOutputTokens,
            cumulativeCacheReadTokens: cumulativeCacheReadTokens,
            cumulativeCacheCreation5mTokens: cumulativeCacheCreation5mTokens,
            cumulativeCacheCreation1hTokens: cumulativeCacheCreation1hTokens,
            topModel: topModel)
    }
}

/// Which account's usage the cost and token views are showing.
///
/// Rate limits are always the active account's — they are a property of the
/// login, not a view preference — so this governs spend and tokens only.
///
/// Persisted, because it is a reading posture rather than a transient filter:
/// someone who works in one account all afternoon should not have to re-pick
/// it every time the dashboard reopens.
@MainActor
@Observable
public final class UsageScope {
    public static let shared = UsageScope()

    private static let key = "PacerUsageScopeAccountId"

    /// nil means every account combined.
    public private(set) var accountId: String?

    private init() {
        accountId = UserDefaults.standard.string(forKey: Self.key)
    }

    public var isAll: Bool { accountId == nil }

    public func select(_ accountId: String?) {
        self.accountId = accountId
        if let accountId {
            UserDefaults.standard.set(accountId, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }

    /// Stands in for "no account selected" in a scoped `@Query`, so the
    /// predicate is always well-formed. Matches nothing — when the scope is
    /// "all accounts" the card reads the global table instead, and the scoped
    /// query costs an indexed miss.
    public static let noAccountSentinel = "\u{0000}none"
}
