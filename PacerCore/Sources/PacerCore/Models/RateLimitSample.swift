import Foundation
import SwiftData

/// One observation of Claude Code's rate-limit window state. Two windows
/// are tracked: the 5-hour rolling block and the 7-day rolling block.
/// Source labels which probe wrote the row — `statusline` for sub-second
/// `pacertap` pushes during active sessions, `oauth` for the 5-minute
/// background poll of `/api/oauth/usage`. We keep the history rather
/// than overwriting so the dashboard can show the curve and we can spot
/// data divergence between sources.
@Model
public final class RateLimitSample {
    // Hot predicates the read path actually uses:
    //   - `sortBy(\.sampledAt, .reverse) + fetchLimit: N` is the
    //     "give me the most recent samples" shape used by HeroStrip,
    //     MenuBarLabel, MenuStatusContent, NotificationsHost, and all
    //     three pace widgets. Without an index, every refetch was a
    //     full-table sort.
    //   - `predicate: sampledAt >= cutoff` is used by PaceChartCard
    //     and PaceChartWidget for the 8-day window. Range scan over
    //     the same index.
    //   - The compound `(sampledAt, window)` helps the inner-loop
    //     bucketing where the chart code filters to one window key
    //     after fetching.
    // The OAuth poller writes 2 rows every 5 minutes; after a year
    // that's ~200K rows. The unindexed scans were the longest-running
    // queries in the read path; they just weren't visible because
    // each one was sub-10ms.
    #Index<RateLimitSample>(
        [\.sampledAt],
        [\.sampledAt, \.window]
    )

    public var sampledAt: Date
    /// `"five_hour"` or `"seven_day"`. String rather than enum so old
    /// rows don't fail to decode if we add a new window kind later
    /// (Anthropic could add e.g. a 1h or 30d window).
    public var window: String
    /// Percentage of the window consumed, 0–100. Server returns this
    /// pre-computed; we don't divide here.
    public var usedPercentage: Double
    /// When the rolling window rolls over. `nil` when the server
    /// returned `resets_at: null` (rare — happens for some account
    /// transitions and certain API-only states). Surfaced as nil
    /// rather than synthesizing a sentinel so the dashboard can
    /// distinguish "no reset time available" from "resets at the
    /// epoch."
    public var resetsAt: Date?
    /// `"statusline"` or `"oauth"`. Lets the read path prefer one source
    /// over the other when both are fresh, and lets us debug-compare.
    public var source: String

    public init(
        sampledAt: Date,
        window: String,
        usedPercentage: Double,
        resetsAt: Date?,
        source: String
    ) {
        self.sampledAt = sampledAt
        self.window = window
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.source = source
    }
}
