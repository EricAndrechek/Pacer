import Foundation

/// Does a sample belong to the rate-limit cycle that resets at a given
/// instant?
///
/// Every sample carries its own `resetsAt`, so cycle membership is a direct
/// property of the row rather than an inference from its timestamp. But the
/// server re-serializes `resets_at` on every response and the value **jitters
/// by a few hundred milliseconds** between polls — a single 7-day cycle
/// routinely carries a couple thousand rows with a couple thousand *distinct*
/// reset instants. So membership can never be exact equality; it has to be
/// "within half a window", which is unambiguous because consecutive resets are
/// always a full window apart.
///
/// This lives in one place because both sample tables need the identical rule:
/// `RateLimitSample` (the fixed 5h/7d blocks) and `UsageLimitSample` (every
/// scoped `limits[]` window). The scoped chart originally filtered on `==` and
/// therefore plotted a single point — the newest reading — instead of the
/// cycle's curve.
public enum RateLimitCycle {
    /// Whether a sample whose own reset is `sampleReset` belongs to the cycle
    /// resetting at `resets`.
    ///
    /// - A `nil` sample reset counts as in-cycle: the server returns
    ///   `resets_at: null` for the post-reset 0%-used readings, before the new
    ///   window re-anchors on your next message (#100).
    /// - Otherwise the sample is in-cycle when its reset is within half a
    ///   window of this cycle's, which absorbs the sub-second jitter while
    ///   still excluding the neighboring cycle.
    @inlinable
    public static func contains(
        sampleReset: Date?, resets: Date, duration: TimeInterval
    ) -> Bool {
        guard let sampleReset else { return true }
        return abs(sampleReset.timeIntervalSince(resets)) < duration / 2
    }
}
