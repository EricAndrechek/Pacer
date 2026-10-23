import Foundation

/// The burn rate over the last few polls, measured rather than modelled.
///
/// The engine's `slopePercentPerHour` reads a 90-minute lookback on a session
/// window and 24 hours on a weekly one, which is right for a forecast and
/// wrong for a decision you are making now: it deliberately smooths away the
/// burst you are in the middle of. This is the other number — first-to-last
/// over the last half hour, no weighting, no fit.
///
/// **Poll resolution is the floor and it is not ours to lower.** A single
/// token is polled every 5 minutes (`OAuthPollScheduler.Tuning`, whose
/// per-token invariant is what keeps Pacer off Anthropic's ~30-minute
/// throttle), so a 30-minute lookback is six readings on a well-fed account
/// and two on an account with one token. Below two readings there is no slope
/// and this returns nil rather than a confident zero.
public enum RecentBurn {

    /// One reading, flattened so both sample tables feed the same maths.
    public struct Reading: Sendable, Equatable {
        public let at: Date
        public let percent: Double
        public let resetsAt: Date?

        public init(at: Date, percent: Double, resetsAt: Date?) {
            self.at = at
            self.percent = percent
            self.resetsAt = resetsAt
        }
    }

    /// Default lookback. Long enough to hold two readings at the slowest
    /// cadence, short enough that a burst still dominates it.
    public static let defaultLookback: TimeInterval = 1800

    /// Percentage points per hour across `lookback`, or nil when the readings
    /// cannot support one.
    ///
    /// **Same cycle only.** A window that reset inside the lookback went from
    /// 90% to 0%, and a slope fitted across that is a large negative number
    /// describing nothing. Membership uses `RateLimitCycle`, so the
    /// sub-second drift in the server's reset time is absorbed rather than
    /// read as a rollover.
    public static func percentPerHour(
        readings: [Reading],
        now: Date = Date(),
        duration: TimeInterval,
        lookback: TimeInterval = defaultLookback
    ) -> Double? {
        let cutoff = now.addingTimeInterval(-lookback)
        let sorted = readings.filter { $0.at >= cutoff }.sorted { $0.at < $1.at }
        guard let newest = sorted.last else { return nil }
        // Anchor on the newest reading's cycle: anything older that belongs to
        // a previous one is a different window's worth of usage.
        let anchor = newest.resetsAt
        let inCycle = sorted.filter { reading in
            guard let anchor else { return true }
            return RateLimitCycle.contains(sampleReset: reading.resetsAt,
                                           resets: anchor, duration: duration)
        }
        guard let first = inCycle.first, inCycle.count >= 2 else { return nil }
        let hours = newest.at.timeIntervalSince(first.at) / 3600
        // Two readings from the same instant (two poller lanes landing
        // together) are one reading for this purpose.
        guard hours > 1.0 / 3600 else { return nil }
        return (newest.percent - first.percent) / hours
    }

    /// Under this a window counts as not moving: it would print "+0.0".
    public static let idleBelow = 0.05

    /// The burn-rate chip on a window's card (#318), from the same 30-minute
    /// figure `pacer report` prints as "now": "+16%/hr", "+0.4%/hr", or
    /// "idle" when the readings have not moved. Nil when the readings cannot
    /// support a rate (fewer than two in the lookback): no chip, rather than
    /// a confident "idle".
    ///
    /// It replaced the "behind" / "on pace" / "danger" badges, which repeated
    /// what the number's colour, the "/ 68%" pace mark and the chart already
    /// show. The burn rate is new: how fast the window is moving right now.
    /// Grey on every card, so the forecast chip beside it is the one that
    /// carries a colour.
    public static func chipText(_ percentPerHour: Double?) -> String? {
        guard let rate = percentPerHour else { return nil }
        guard rate >= idleBelow else { return "idle" }
        return rate >= 9.95 ? String(format: "+%.0f%%/hr", rate) : String(format: "+%.1f%%/hr", rate)
    }
}
