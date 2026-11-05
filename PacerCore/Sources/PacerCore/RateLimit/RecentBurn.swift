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

    /// Two readings closer than this are one reading: two poller lanes landing
    /// together.
    static let minSpan: TimeInterval = 1

    /// Percentage points per hour across `lookback`, or nil when the readings
    /// cannot support one.
    ///
    /// **Same cycle only.** A window that reset inside the lookback went from
    /// 90% to 0%, and a slope fitted across that is a large negative number
    /// describing nothing. `currentCycle` keeps the newest reading's cycle,
    /// which also holds when that reading carries no reset (#339). Never
    /// negative, then: inside one cycle usage does not fall.
    ///
    /// Nil when the newest reading's own window had closed by `now`: what it
    /// measured was the last cycle's burn, and the next reading starts a new
    /// one.
    public static func percentPerHour(
        readings: [Reading],
        now: Date = Date(),
        duration: TimeInterval,
        lookback: TimeInterval = defaultLookback
    ) -> Double? {
        let cutoff = now.addingTimeInterval(-lookback)
        // Ties by percent: two lanes landing in the same instant are not a
        // drop, and within a cycle the higher of them is the later state.
        let sorted = readings.filter { $0.at >= cutoff }
            .sorted { ($0.at, $0.percent) < ($1.at, $1.percent) }
        let cycle = currentCycle(sorted, duration: duration)
        guard let first = cycle.first, let newest = cycle.last, cycle.count >= 2 else { return nil }
        if let reset = newest.resetsAt, reset <= now { return nil }
        let seconds = newest.at.timeIntervalSince(first.at)
        guard seconds >= minSpan else { return nil }
        return (newest.percent - first.percent) / (seconds / 3600)
    }

    /// The newest reading's cycle: the run of readings back from it that
    /// stays in one window. The run stops at the first reading that
    ///
    /// - is higher than the one after it. Usage never falls inside a window,
    ///   so a fall is a reset wherever the anchors say; that includes an
    ///   off-schedule reset that kept the old anchor, and a reading at 0%
    ///   whose `resets_at` is null because the new window has not opened yet;
    /// - carries a reset at or before the newest reading: its window had
    ///   already closed;
    /// - carries a reset outside the run's anchor (`RateLimitCycle.contains`,
    ///   never `==`: the server's reset jitters in the milliseconds). The
    ///   anchor is the newest reset in the run, so a newest reading with
    ///   null `resets_at` takes the one before it.
    ///
    /// A null reset, on its own, stops nothing: it is the server's 0% at the
    /// start of a window and says nothing about which one.
    ///
    /// Anchoring on the newest reading's reset alone (#339) let every older
    /// reading in whenever that reset was null, which the server sends at 0%
    /// on about a quarter of 5-hour readings: right after a reset, 9% → 0%
    /// read −19%/h and held there for the half hour. Replayed on the owner's
    /// store (a moment every 10 minutes over every reading of four
    /// accounts), 142 of 15,396 five-hour moments and 6 of 18,521 weekly ones
    /// read negative; none do now.
    static func currentCycle(_ sorted: [Reading], duration: TimeInterval) -> ArraySlice<Reading> {
        guard let newest = sorted.last else { return [] }
        var anchor = newest.resetsAt
        var start = sorted.endIndex - 1
        while start > sorted.startIndex {
            let earlier = sorted[start - 1]
            if earlier.percent > sorted[start].percent { break }
            if let reset = earlier.resetsAt {
                if reset <= newest.at { break }
                if let anchor, !RateLimitCycle.contains(sampleReset: reset, resets: anchor, duration: duration) {
                    break
                }
                anchor = anchor ?? reset
            }
            start -= 1
        }
        return sorted[start...]
    }

    /// Under this a window counts as not moving: it would print "+0.0".
    public static let idleBelow = 0.05

    /// The burn-rate chip on a window's card (#318), from the same 30-minute
    /// figure `pacer report` prints as "now": "+16%/hr" or "+0.4%/hr". Nil
    /// when the readings have not moved, and when they cannot support a rate
    /// (fewer than two in the lookback).
    ///
    /// It replaced the "behind" / "on pace" / "danger" badges, which repeated
    /// what the number's colour, the "/ 68%" pace mark and the chart already
    /// show. The burn rate is new: how fast the window is moving right now.
    /// Grey on every card, so the forecast chip beside it is the one that
    /// carries a colour.
    ///
    /// There is no "idle" chip any more (round 4): beside "holds until reset"
    /// it said the same thing twice, and on a window at 0% it was the only
    /// chip and said nothing anyone needed (`chipRow`).
    public static func chipText(_ percentPerHour: Double?) -> String? {
        guard let rate = percentPerHour, rate >= idleBelow else { return nil }
        return rate >= 9.95 ? String(format: "+%.0f%%/hr", rate) : String(format: "+%.1f%%/hr", rate)
    }

    /// Which chips a window's card draws under its number.
    public struct ChipRow: Sendable, Equatable {
        /// The burn-rate chip's words (`chipText`), nil for none.
        public let burn: String?
        /// Whether the forecast chip (`ForecastChip.make`) is drawn. It can
        /// still have nothing to say.
        public let showsForecast: Bool

        public init(burn: String?, showsForecast: Bool) {
            self.burn = burn
            self.showsForecast = showsForecast
        }
    }

    /// The card's chip row (#318, the owner's round-4 rules):
    ///
    ///     moving                    "+16%/hr"  and the forecast chip
    ///     idle, above 0%            the forecast chip only ("holds until reset")
    ///     idle, at 0%               no chip at all
    ///     no rate (under two readings)   the forecast chip only
    ///
    /// "Idle" is the readings' own half hour (`idleBelow`), not the engine's
    /// slope. `shownPercent` is the number the card shows, the live estimate
    /// or the reading; "at 0%" is what it writes as zero ("0%", "0.0%"). An
    /// idle window at 0% has nothing to hold, and a forecast there could
    /// only be the engine's rhythm guessing at a window nobody is using.
    public static func chipRow(percentPerHour: Double?, shownPercent: Double) -> ChipRow {
        guard let rate = percentPerHour, rate < idleBelow else {
            return ChipRow(burn: chipText(percentPerHour), showsForecast: true)
        }
        return ChipRow(burn: nil, showsForecast: PacerMeterFormat.tenths(shownPercent) > 0)
    }
}
