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

/// Which account's usage the app is showing.
///
/// Persisted, because it is a reading posture rather than a transient filter:
/// someone who works in one account all afternoon should not have to re-pick
/// it every time the dashboard reopens.
///
/// Spend and tokens read `accountId` directly: nil means every account, and
/// "every account" is a real answer because costs add up. Rate limits read
/// `limitAccountId` instead, because they do not: two accounts' 5-hour
/// windows cannot be summed into a third number, so "all accounts" resolves
/// to the active login — the same thing every gauge showed before accounts
/// existed.
@MainActor
@Observable
public final class UsageScope {
    public static let shared = UsageScope()

    /// Lives in the App Group suite, not `.standard`: the widget extension is
    /// a separate process and cannot see the app's standard defaults, so a
    /// scope stored there would be invisible to every widget by construction.
    public nonisolated static let key = "PacerUsageScopeAccountId"

    /// The active login, mirrored here so a rate-limit view can react to it.
    ///
    /// Also in App Group defaults, for the same reason the scope is: the
    /// widget extension is a separate process, and its gauges have to resolve
    /// "all accounts" the same way the window does or the two disagree on one
    /// screen. Persisted rather than derived so a cold start resolves it
    /// before the first poll lands.
    public nonisolated static let activeKey = "PacerActiveAccountId"

    /// nil means every account combined.
    public private(set) var accountId: String?
    public private(set) var activeAccountId: String?

    private init() {
        accountId = PacerPreferences.store.string(forKey: Self.key)
        activeAccountId = PacerPreferences.store.string(forKey: Self.activeKey)
    }

    /// Which account's rate-limit history to read: the picked scope, else the
    /// active login. Never nil-means-all — see the type's doc comment.
    public var limitAccountId: String? { accountId ?? activeAccountId }

    /// Called by the poller when the active login changes.
    ///
    /// A nil is "we do not know yet", not "there is no active account", so it
    /// leaves the stored value alone. The poller publishes before its first
    /// response resolves an org, and clearing on that would blank every gauge
    /// on the widget side of the app group for the first few seconds of every
    /// launch — for no gain, since the previous value is still the right one.
    public func setActiveAccount(_ id: String?) {
        guard let id, id != activeAccountId else { return }
        activeAccountId = id
        PacerPreferences.store.set(id, forKey: Self.activeKey)
    }

    public var isAll: Bool { accountId == nil }

    public func select(_ accountId: String?) {
        self.accountId = accountId
        if let accountId {
            PacerPreferences.store.set(accountId, forKey: Self.key)
        } else {
            PacerPreferences.store.removeObject(forKey: Self.key)
        }
    }

    /// Set the scope for this process only, without persisting it.
    ///
    /// The diagnostic renderer runs as a second instance against the real
    /// store: it has to look at the dashboard through each scope in turn, and
    /// `select` would write every one of those into the App Group defaults the
    /// *running* app reads — leaving the user's scope wherever the render
    /// happened to stop.
    public func selectEphemeral(_ accountId: String?) {
        self.accountId = accountId
    }

    /// The scope as any process can read it, including the widget extension
    /// which has no `UsageScope` instance of its own.
    ///
    /// `nonisolated` because it is a plain defaults read with no shared
    /// mutable state, and its callers — the widget timelines and the CSV
    /// exporter — run outside the main actor.
    public nonisolated static var storedAccountId: String? {
        PacerPreferences.store.string(forKey: key)
    }

    /// The rate-limit scope for those same out-of-process readers.
    public nonisolated static var storedLimitAccountId: String? {
        storedAccountId ?? storedActiveAccountId
    }

    /// The active login alone, ignoring what the window is showing.
    ///
    /// What a *decision* reads, as opposed to a display: the forecast engine
    /// and the alert evaluator both use this. An alert that a display filter
    /// could silence is a footgun — scope the window to work in the morning
    /// and stop hearing about personal spend all day — and the engine's
    /// projections are the active login's by construction.
    public nonisolated static var storedActiveAccountId: String? {
        PacerPreferences.store.string(forKey: activeKey)
    }

    /// Stands in for "no account selected" in a scoped `@Query`, so the
    /// predicate is always well-formed. Matches nothing — when the scope is
    /// "all accounts" the card reads the global table instead, and the scoped
    /// query costs an indexed miss.
    public nonisolated static let noAccountSentinel = "\u{0000}none"
}

/// Scope-aware reads for processes with no `UsageScope` instance — the widget
/// extension and the CSV exporter both run outside the app's view tree.
///
/// The scope lives in App Group defaults precisely so these can see it: a
/// widget showing every account while the window beside it shows one would be
/// two answers to the same question on one screen.
public enum ScopedReads {
    /// Daily rows for the stored scope, normalised to `DailyRow`.
    public static func daily(
        _ context: ModelContext,
        wherePredicate globalPredicate: Predicate<DailyAggregate>? = nil,
        scopedPredicate: (String) -> Predicate<AccountDailyAggregate>
    ) -> [DailyRow] {
        if let acct = UsageScope.storedAccountId {
            var d = FetchDescriptor<AccountDailyAggregate>(predicate: scopedPredicate(acct))
            d.sortBy = [SortDescriptor(\.date, order: .reverse)]
            return ((try? context.fetch(d)) ?? []).map(\.dailyRow)
        }
        var d = FetchDescriptor<DailyAggregate>(predicate: globalPredicate)
        d.sortBy = [SortDescriptor(\.date, order: .reverse)]
        return ((try? context.fetch(d)) ?? []).map(\.dailyRow)
    }
}
