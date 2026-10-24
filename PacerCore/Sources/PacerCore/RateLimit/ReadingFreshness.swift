import Foundation

/// When an account's limit readings stop counting as current.
///
/// A reading is stale when its account has fallen well behind the freshest
/// reading Pacer holds for any account: others are being read and this one is
/// not, which is what a cswap switch-away or a broken token looks like. "Well
/// behind" is measured in the account's OWN poll gaps (#302). A fixed 3-minute
/// rule fired between every pair of ordinary polls of a background account,
/// which Pacer reads every 350–360 s (p90 600 s): 96–99% of those gaps exceeded
/// it, so background accounts' forecasts blinked off for 34–49% of their live
/// minutes. The active lane, polled about once a minute, still trips after
/// 3 minutes.
public enum ReadingFreshness {

    /// Never stale sooner than this: the active lane's cadence, roughly a
    /// minute, times a margin.
    public static let minimumLag: TimeInterval = 3 * 60

    /// How many of its usual poll gaps an account may fall behind. 2.5 clears a
    /// background account's p90 gap (600 s against a 350–360 s median) while
    /// still catching an account that has stopped being read within a few polls.
    public static let gapMultiple = 2.5

    /// Gaps the typical cadence is taken over: recent enough to follow the
    /// adaptive poller as it slows down and speeds up.
    public static let recentGaps = 12

    /// Readings closer together than this are one poll (#308). An account
    /// with several tokens is polled through one lane per token, and when
    /// those lanes come due together (#350) it lands a burst of readings
    /// seconds apart and then nothing for minutes. Taken one by one,
    /// six of every seven gaps were 4–7 s, the "usual gap" read as seconds,
    /// and every ordinary pause between rounds tripped the 3-minute floor: on
    /// a real store that withheld the active account's weekly lines for
    /// 10–35 minutes at a time, a dozen times a day. Well under the fastest
    /// real cadence (the active lane, about a minute), so steady polls never
    /// merge.
    public static let pollBurst: TimeInterval = 30

    /// The account's usual poll gap: the median gap between its most recent
    /// polls, or nil with fewer than two. Any order; duplicates (one poll
    /// stores a row per window) collapse, and so does a burst of readings
    /// within `pollBurst` of each other, dated by its last reading — the one
    /// staleness is measured from.
    public static func typicalGap(readingTimes: [Date]) -> TimeInterval? {
        let times = Set(readingTimes.map { $0.timeIntervalSince1970.rounded() }).sorted()
        var polls: [TimeInterval] = []
        for t in times {
            if let last = polls.last, t - last <= pollBurst {
                polls[polls.count - 1] = t
            } else {
                polls.append(t)
            }
        }
        guard polls.count >= 2 else { return nil }
        let recent = Array(polls.suffix(recentGaps + 1))
        let gaps = zip(recent.dropFirst(), recent).map { $0 - $1 }.sorted()
        let n = gaps.count
        return n % 2 == 1 ? gaps[n / 2] : (gaps[n / 2 - 1] + gaps[n / 2]) / 2
    }

    /// How far behind the freshest reading this account may fall.
    public static func allowedLag(typicalGap: TimeInterval?) -> TimeInterval {
        max(minimumLag, gapMultiple * (typicalGap ?? 0))
    }

    /// True when this account has stopped being read while others carry on.
    public static func isStale(readingAt: Date?, newestAnyAccountAt: Date?,
                               typicalGap: TimeInterval?) -> Bool {
        guard let readingAt, let newestAnyAccountAt else { return false }
        return newestAnyAccountAt.timeIntervalSince(readingAt) > allowedLag(typicalGap: typicalGap)
    }
}
