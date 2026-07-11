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
    /// Which account (`Account.id`) this sample belongs to. Optional +
    /// additive: existing rows decode as nil, which every read treats as
    /// "the active account" (they were all the single account's history).
    /// The multi-account poller stamps this going forward, and the
    /// active-account timeline swap (`OAuthPoller.setActiveAccount`) keeps
    /// this table holding exactly the active account's rows — so no read
    /// site has to filter on it. See `Account`.
    public var accountId: String?

    public init(
        sampledAt: Date,
        window: String,
        usedPercentage: Double,
        resetsAt: Date?,
        source: String,
        accountId: String? = nil
    ) {
        self.sampledAt = sampledAt
        self.window = window
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.source = source
        self.accountId = accountId
    }
}

public extension Sequence where Element == RateLimitSample {
    /// Samples that belong to the cycle resetting at `resets` — i.e. with
    /// the stragglers from neighboring cycles dropped.
    ///
    /// Each sample carries its own `resetsAt`, so cycle membership is a
    /// direct property of the row, not an inference from its timestamp.
    /// A sample is in-cycle when its `resetsAt` matches `resets` (within
    /// half a window — consecutive resets are always ≥ one window apart,
    /// while a single cycle's `resets_at` only jitters by ~1s across
    /// polls), or when it's `nil` (the server returns `resets_at: null`
    /// for the post-reset 0%-used readings, before the new window
    /// re-anchors on your next message).
    ///
    /// The chart consumers used to scope a cycle purely by timestamp
    /// (`sampledAt >= resets - duration`). Because the 7-day reset lands
    /// almost exactly one window after the previous one, the prior cycle's
    /// *final* high-usage sample — taken within milliseconds of the new
    /// `cycleStart` — slipped past that `>=` and got plotted as the first
    /// point, drawing a spurious near-vertical line (red, since at the
    /// cycle's start any usage is far over the ~0% pace target) at the
    /// chart's left edge. Filtering on the sample's own reset removes it
    /// regardless of sub-second boundary jitter.
    func inCycle(resetting resets: Date, duration: TimeInterval) -> [RateLimitSample] {
        let tolerance = duration / 2
        return filter { sample in
            guard let sampleReset = sample.resetsAt else { return true }
            return abs(sampleReset.timeIntervalSince(resets)) < tolerance
        }
    }
}
