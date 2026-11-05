import Foundation

/// The burn rate over the last few polls, measured rather than modelled.
///
/// The engine's `slopePercentPerHour` reads a 90-minute lookback on a session
/// window and 24 hours on a weekly one, which is right for a forecast and
/// wrong for a decision you are making now: it deliberately smooths away the
/// burst you are in the middle of. This is the other number — first-to-last
/// over the last half hour, no weighting, no fit — for as long as the
/// readings can resolve one over that half hour.
///
/// **Poll resolution is the floor and it is not ours to lower.** A single
/// token is polled every 5 minutes (`OAuthPollScheduler.Tuning`, whose
/// per-token invariant is what keeps Pacer off Anthropic's ~30-minute
/// throttle), so a 30-minute lookback is six readings on a well-fed account
/// and two on an account with one token. Below two readings there is no slope
/// and this returns nil rather than a confident zero.
///
/// **Whole points are the other floor (#358).** The server reports every
/// window in whole percent. A 5-hour window burning a tenth of its even pace
/// (2%/h) climbs a point every half hour, so half an hour resolves it. A
/// weekly window at 1–4%/h — several times its even pace of 0.6%/h — often
/// climbs no point in half an hour at all, and first-to-last read exactly 0
/// while it was plainly rising: on the owner's store, 840 of the 2,331
/// weekly moments that rose over the next half hour had been called 0. So
/// when the half hour climbed fewer than `resolvingPoints`, the rate comes
/// from the ticks instead (`fromTicks`), reaching back as far as
/// `lookbackLimit`: the span over which one point is a tenth of the window's
/// even pace, the same resolution the half hour gives a 5-hour window. That
/// is the half hour itself on a 5-hour window, whose answers are therefore
/// unchanged, and 16.8 hours on a weekly one.
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

    /// How far back the rate may reach for a window of `duration` when the
    /// lookback climbed too little to measure: a tenth of the window, never
    /// less than `lookback`. A point over this span is a tenth of the window's
    /// even pace (100% per `duration`), which is the resolution `lookback`
    /// gives the 5-hour window it was chosen for. A caller that hands over
    /// readings this far back gets the weekly rate (#358); one that hands
    /// over only the last half hour gets the half-hour answer, as before.
    ///
    /// Not shorter: replayed on the owner's store (`RecentBurnReplayProbe`),
    /// a six-hour reach called 340 of the 4,089 weekly moments that rose
    /// over the next two hours 0, against 218 at this one. Not longer: past
    /// it, a point is under a tenth of the window's even pace, a rate too
    /// slow to be worth reaching further back to see.
    public static func lookbackLimit(duration: TimeInterval,
                                     lookback: TimeInterval = defaultLookback) -> TimeInterval {
        max(lookback, duration / 10)
    }

    /// The climb, in whole points, the lookback must show for first-to-last
    /// over it to stand. Below it the readings moved by at most one step of
    /// their own resolution, and first-to-last is 0 or a full point's worth
    /// of rate depending only on where the ticks happened to fall.
    static let resolvingPoints = 2.0

    /// Two readings closer than this are one reading: two poller lanes landing
    /// together.
    static let minSpan: TimeInterval = 1

    /// Percentage points per hour across `lookback`, or across the ticks
    /// back to `lookbackLimit` when `lookback` climbed less than
    /// `resolvingPoints`; nil when the readings cannot support one.
    ///
    /// **Same cycle only.** A window that reset inside the lookback went from
    /// 90% to 0%, and a slope fitted across that is a large negative number
    /// describing nothing. `currentCycle` keeps the newest reading's cycle,
    /// which also holds when that reading carries no reset (#339). Never
    /// negative, then: inside one cycle usage does not fall.
    ///
    /// Nil when the newest reading is older than `lookback`, and when its own
    /// window had closed by `now`: what it measured was the last cycle's
    /// burn, and the next reading starts a new one.
    public static func percentPerHour(
        readings: [Reading],
        now: Date = Date(),
        duration: TimeInterval,
        lookback: TimeInterval = defaultLookback
    ) -> Double? {
        let recentCutoff = now.addingTimeInterval(-lookback)
        let cutoff = now.addingTimeInterval(-lookbackLimit(duration: duration, lookback: lookback))
        let sorted = ascending(readings.filter { $0.at >= cutoff })
        let cycle = currentCycle(sorted, duration: duration)
        guard let newest = cycle.last, newest.at >= recentCutoff else { return nil }
        if let reset = newest.resetsAt, reset <= now { return nil }
        if let first = cycle.first(where: { $0.at >= recentCutoff }),
           newest.percent - first.percent >= resolvingPoints,
           newest.at.timeIntervalSince(first.at) >= minSpan {
            return perHour(newest.percent - first.percent, over: newest.at.timeIntervalSince(first.at))
        }
        return fromTicks(cycle)
    }

    /// `readings` oldest first. Ties by percent: two lanes landing in the same
    /// instant are not a drop, and within a cycle the higher of them is the
    /// later state.
    ///
    /// A weekly window hands over up to 16.8 hours of readings, thousands on
    /// a busy account, and the callers already hold them in time order (the
    /// card newest first), so an ordered input is reversed or kept rather
    /// than sorted on every draw.
    static func ascending(_ readings: [Reading]) -> [Reading] {
        let before = { (a: Reading, b: Reading) in (a.at, a.percent) <= (b.at, b.percent) }
        if zip(readings, readings.dropFirst()).allSatisfy(before) { return readings }
        if zip(readings, readings.dropFirst()).allSatisfy({ before($1, $0) }) { return readings.reversed() }
        return readings.sorted { ($0.at, $0.percent) < ($1.at, $1.percent) }
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
    /// store (`RecentBurnReplayProbe`, a moment every 10 minutes over every
    /// reading of four accounts), 142 of 15,396 five-hour moments and 6 of
    /// 18,521 weekly ones read negative; none do now.
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

    /// The rate from the readings' ticks (#358), for a cycle whose lookback
    /// climbed less than `resolvingPoints`.
    ///
    /// A tick is the first reading at a new whole point. The server's meter
    /// is floored (`LiveMeter`), so at a tick it sits at the bottom of its
    /// point, to within one poll: between two ticks the climb is known
    /// exactly, which first-to-last between two arbitrary readings is not.
    /// So the rate is the climb from the latest tick at least
    /// `resolvingPoints` below the last one (else the earliest tick there
    /// is) to the last tick, over the time between them.
    ///
    /// Then the readings since the last tick: they held, so the meter has
    /// climbed less than one point since it. The rate is never more than one
    /// point over that hold, which is what brings it down once a burst ends,
    /// rather than holding the rate of the climb that stopped. A burst that
    /// stopped an hour ago reads at most 1%/h, and it does not read 0: it
    /// may still be climbing inside its point.
    ///
    /// With fewer than two ticks, first-to-last across the cycle, under the
    /// same cap. With none, 0: the readings did not climb a point across the
    /// whole of `lookbackLimit`, which is the resolution this number stops
    /// at.
    ///
    /// Replayed on the owner's store (`RecentBurnReplayProbe`: every weekly
    /// reading of four accounts, a moment every 10 minutes, scored against
    /// the climb over the next two hours), against the half hour alone: the
    /// moments that rose but were called 0 went from 1,711 to 218 of 4,089,
    /// the rising moments' mean error from 2.04 to 1.84 points per hour and
    /// their bias from −0.21 to +0.01. The moments that then held read
    /// 0.14%/h on average, against 0.08: "under a point since the tick" is an
    /// upper bound, and a week that has stopped pays a few hundredths of a
    /// point an hour for it.
    static func fromTicks(_ cycle: ArraySlice<Reading>) -> Double? {
        guard let first = cycle.first, let newest = cycle.last,
              newest.at.timeIntervalSince(first.at) >= minSpan else { return nil }
        var ticks: [Reading] = []
        for (earlier, later) in zip(cycle, cycle.dropFirst()) where later.percent > earlier.percent {
            ticks.append(later)
        }
        guard let last = ticks.last else { return 0 }
        let apart = { (tick: Reading) in last.at.timeIntervalSince(tick.at) >= minSpan }
        var rate: Double
        if let start = ticks.last(where: { apart($0) && last.percent - $0.percent >= resolvingPoints })
            ?? ticks.first(where: apart) {
            rate = perHour(last.percent - start.percent, over: last.at.timeIntervalSince(start.at))
        } else {
            rate = perHour(newest.percent - first.percent, over: newest.at.timeIntervalSince(first.at))
        }
        let held = newest.at.timeIntervalSince(last.at)
        if held > 0 { rate = min(rate, perHour(1, over: held)) }
        return rate
    }

    private static func perHour(_ points: Double, over seconds: TimeInterval) -> Double {
        points / (seconds / 3600)
    }

    /// Under this a window counts as not moving: it would print "+0.0".
    public static let idleBelow = 0.05

    /// The burn-rate chip on a window's card (#318), from the same figure
    /// `pacer report` prints as "now" (`percentPerHour`): "+16%/hr" or
    /// "+0.4%/hr". Nil when the readings have not moved, and when they cannot
    /// support a rate (fewer than two).
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
    /// "Idle" is the readings' own rate (`idleBelow`), not the engine's
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
