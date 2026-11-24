import Foundation

/// When a window's readings show it continuously, and when they do not (#421).
///
/// Pacer sees a window climb only while it is reading it. Readings stop while
/// Pacer is not running, while the Mac sleeps, while a login has lapsed or a
/// lane is throttled, and while a switcher leaves an account unread; the
/// server's meter keeps counting all the while. The next reading then lands
/// the whole climb at once: on the owner's store one weekly window went 0% →
/// 23% across a 14-hour gap, and three accounts came back from 50–61 hours
/// unread. Anything that reads a rate between two readings has to know that
/// the stretch between them was not watched, or it reads the gap as a burn.
///
/// This is the one definition. A reading's value after a gap is known; when
/// the meter got there is not, so it is a level, not a tick, and no rate is
/// measured across the gap that precedes it.
///
/// Derived from the readings' own times, never stored: every poll writes a
/// row, so the rows are the record of when Pacer was reading. Why it stopped
/// (asleep, quit, a lapsed login) is not recoverable from them, and nothing
/// here needs it.
public enum ReadingCoverage {

    /// Readings closer together than this are one poll (#308). An account
    /// with several tokens is polled through one lane per token, and when
    /// those lanes come due together (#350) it lands a burst of readings
    /// seconds apart and then nothing for minutes. Well under the fastest
    /// real cadence (the active lane, about a minute), so steady polls never
    /// merge. `ReadingFreshness` counts an account's cadence in polls of this
    /// definition. Rates need no merging of their own: `minRateSpan` is ten
    /// of these, so no burst is ever measured as a rate, and merging chains:
    /// a stream read faster than this (`fiveHourAnswersAreUnchanged` reads
    /// one every 25 s) would fold into a single poll.
    public static let pollBurst: TimeInterval = 30

    /// Consecutive polls further apart than this leave a gap in coverage.
    ///
    /// Six polls at the per-token floor (`OAuthPollScheduler.Tuning`, five
    /// minutes), and twice the longest Pacer stands aside for another
    /// client (fifteen). On the owner's store an ordinary background
    /// account's polls are 350–360 s apart (p90 600 s), and gaps over this
    /// are rare: 4–80 per account-window over months, outside the account
    /// read every minute.
    ///
    /// Fixed rather than counted in the account's own polls, as
    /// `ReadingFreshness` counts them: that rule asks whether this account
    /// fell behind the others, and when every account stops at once (Pacer
    /// quit, the Mac asleep; all four accounts on the owner's store, for 14
    /// hours, on 2026-11-13) none falls behind. The question here is whether
    /// the meter could have moved unseen, which does not depend on what the
    /// other accounts were doing.
    ///
    /// The live meter pairs readings up to an hour apart
    /// (`SpendMeterFitter.maxPairGap`): that is a fit-quality threshold for
    /// spend against the meter, which wants the longer pairs, not a claim
    /// about when the climb happened.
    public static let maxGap: TimeInterval = 30 * 60

    /// The shortest span a rate between readings is measured over.
    ///
    /// The server's meter is whole points and a tick (the first reading at a
    /// new point) is dated only to within one poll: five minutes at the
    /// per-token floor. Over a shorter span the rate is mostly that dating
    /// error, and one point over 16 seconds is 222%/h. Five minutes is also
    /// the floor the engine's descriptive slope always had.
    ///
    /// Replayed at every reading of the owner's store (#421), the rates over
    /// 50%/h weekly or 200%/h five-hourly — 222%/h and 183%/h weekly, 549%/h
    /// five-hourly, each over readings seconds apart right after a gap of two
    /// days or more — are gone. See `RecentBurnReplayProbe`.
    public static let minRateSpan: TimeInterval = 5 * 60

    /// True when two consecutive polls leave a gap between them.
    public static func isGap(from earlier: Date, to later: Date) -> Bool {
        later.timeIntervalSince(earlier) > maxGap
    }

    /// The run of `items`, oldest first, that reaches the newest without a
    /// gap: everything after the last gap. Empty for empty input.
    public static func continuousRun<C: BidirectionalCollection>(
        _ items: C, at: (C.Element) -> Date
    ) -> C.SubSequence {
        guard var start = items.indices.last else { return items[...] }
        while start > items.startIndex {
            let earlier = items.index(before: start)
            if isGap(from: at(items[earlier]), to: at(items[start])) { break }
            start = earlier
        }
        return items[start...]
    }
}
