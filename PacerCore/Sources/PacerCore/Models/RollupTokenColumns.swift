import Foundation

/// The five token columns every rollup row carries, read as one value (#215).
///
/// A view asks a row for `tokens` and then for `.all`, `.uncached`,
/// `.cacheReadTokens` or `.cacheWrite` — it never adds the columns itself.
/// Adding them by hand is how three definitions of "tokens" came to coexist:
/// input + output on most screens, input + output + cache reads on a few, all
/// five nowhere. `TokenBreakdown` is the definition; this is the one way a
/// stored row reaches it.
public protocol RollupTokenColumns {
    var inputTokens: Int64 { get }
    var outputTokens: Int64 { get }
    var cacheReadTokens: Int64 { get }
    var cacheCreation5mTokens: Int64 { get }
    var cacheCreation1hTokens: Int64 { get }
}

public extension RollupTokenColumns {
    var tokens: TokenBreakdown {
        TokenBreakdown(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreation5mTokens: cacheCreation5mTokens,
            cacheCreation1hTokens: cacheCreation1hTokens)
    }
}

extension DailyAggregate: RollupTokenColumns {}
extension HourlyAggregate: RollupTokenColumns {}
extension ProjectDailyAggregate: RollupTokenColumns {}
extension AccountDailyAggregate: RollupTokenColumns {}
extension AccountHourlyAggregate: RollupTokenColumns {}
extension AccountProjectDailyAggregate: RollupTokenColumns {}
extension DailyRow: RollupTokenColumns {}
extension HourlyRow: RollupTokenColumns {}

// The session rollups name their columns `cumulative…`, so they map by hand —
// once, here.

public extension SessionInfo {
    var tokens: TokenBreakdown {
        TokenBreakdown(
            inputTokens: cumulativeInputTokens,
            outputTokens: cumulativeOutputTokens,
            cacheReadTokens: cumulativeCacheReadTokens,
            cacheCreation5mTokens: cumulativeCacheCreation5mTokens,
            cacheCreation1hTokens: cumulativeCacheCreation1hTokens)
    }
}

public extension AccountSessionInfo {
    var tokens: TokenBreakdown {
        TokenBreakdown(
            inputTokens: cumulativeInputTokens,
            outputTokens: cumulativeOutputTokens,
            cacheReadTokens: cumulativeCacheReadTokens,
            cacheCreation5mTokens: cumulativeCacheCreation5mTokens,
            cacheCreation1hTokens: cumulativeCacheCreation1hTokens)
    }
}

public extension SessionRow {
    var tokens: TokenBreakdown {
        TokenBreakdown(
            inputTokens: cumulativeInputTokens,
            outputTokens: cumulativeOutputTokens,
            cacheReadTokens: cumulativeCacheReadTokens,
            cacheCreation5mTokens: cumulativeCacheCreation5mTokens,
            cacheCreation1hTokens: cumulativeCacheCreation1hTokens)
    }
}
