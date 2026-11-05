import Foundation
import PacerCore

/// One account's loaded pace history, reduced to what the dashboard's pace
/// card draws from it: per window, the newest reading, the 30-minute burn rate
/// and the decimated actual line (`PaceChartView.Data.cycle`), plus the
/// account-level facts the columns share.
///
/// **Why it exists (#367).** The card used to derive all of this inside
/// `body`. That is a walk over every loaded point (38,448 on a four-account
/// store, 27.5k for one account) several times over: bucketing by window, a
/// sorted set of reading times for the poll gap, two copies of each window for
/// the burn rate, the cycle filter, a sort and the decimation, and for each
/// scoped column a filter of the whole scoped bag, twice. And `body` re-ran on
/// every poll's account save, every series top-up, every forecast pass and
/// every minute: 100–150 ms of main thread each time on a Debug build,
/// ~300 stalls an hour with the dashboard open.
///
/// Now it is built once per data change and once per minute, **off the main
/// actor**, and the card's `body` assembles its columns from it. The values are
/// produced by the same builders as before (`PaceChartView.Data.cycle`,
/// `RecentBurn.percentPerHour`, `ReadingFreshness.typicalGap`) over the same
/// inputs, so what is drawn is identical; `PaceSeriesPrepTests` holds the old
/// in-body derivation beside this one and requires equal output.
///
/// `preparedAt` is the clock the values were judged at: the line's "now" tail
/// and the burn rate's half-hour lookback. The card re-prepares on its minute
/// tick, which is the same clock its `body` used to read.
public struct PaceSeriesPrep: Sendable, Equatable {

    /// The fixed windows' lengths, shared with the card's column sort.
    public static let fiveHourDuration: TimeInterval = 5 * 3600
    public static let sevenDayDuration: TimeInterval = 7 * 86400

    /// One fixed window (5-hour or 7-day) of one account.
    public struct Fixed: Sendable, Equatable {
        /// The window's newest reading in load order (the history is
        /// newest-first): the number the column shows. Nil before the first.
        public let latest: LimitSamplePoint?
        /// `RecentBurn.percentPerHour` over the window's readings at
        /// `preparedAt`.
        public let recentBurn: Double?
        /// The projection-free actual line (`PaceChartView.Data.cycle(fixed:)`).
        public let baseChart: PaceChartView.Data?
    }

    /// One scoped (`limits[]`) window of one account, in `latestBatch` order.
    public struct Scoped: Sendable, Equatable {
        /// The latest poll's row for the identity: label, group, severity,
        /// binding flag and the reading the column shows.
        public let row: ScopedWindowRow
        /// `WindowSpec.scopedDuration(group:)`.
        public let duration: TimeInterval
        public let recentBurn: Double?
        /// `PaceChartView.Data.cycle(scoped:history:)`.
        public let baseChart: PaceChartView.Data?
    }

    public let preparedAt: Date
    /// The first fixed reading in load order (newest-first), the yardstick a
    /// column uses to tell "quiet everywhere" from "this account stopped".
    public let newestFixedAt: Date?
    /// `ReadingFreshness.typicalGap` over every fixed reading.
    public let typicalPollGap: TimeInterval?
    /// The latest poll had a 7-day window and no 5-hour one (#361): no 5-hour
    /// column, and no 5-hour forecast to ask for.
    public let hasNoFiveHourWindow: Bool
    /// Any fixed reading, or a scoped window in the latest poll: the card's
    /// "there is something to draw" test.
    public let hasReading: Bool
    public let fiveHour: Fixed
    public let sevenDay: Fixed
    public let scoped: [Scoped]

    public init(preparedAt: Date, newestFixedAt: Date?, typicalPollGap: TimeInterval?,
                hasNoFiveHourWindow: Bool, hasReading: Bool,
                fiveHour: Fixed, sevenDay: Fixed, scoped: [Scoped]) {
        self.preparedAt = preparedAt
        self.newestFixedAt = newestFixedAt
        self.typicalPollGap = typicalPollGap
        self.hasNoFiveHourWindow = hasNoFiveHourWindow
        self.hasReading = hasReading
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.scoped = scoped
    }

    /// Build from one account's loaded history.
    ///
    /// - Parameters:
    ///   - fixed: the account's 5-hour and 7-day readings, newest first (the
    ///     card's load order).
    ///   - scoped: its model/surface-scoped readings, newest first.
    ///   - windows: the newest scoped rows, which decide the scoped column set.
    ///   - now: the clock the line's tail and the burn rate are judged at.
    public static func prepare(fixed: [LimitSamplePoint], scoped: [ScopedSamplePoint],
                               windows: [ScopedWindowRow], now: Date) -> PaceSeriesPrep {
        // One pass over the fixed rows: split by window (order kept) and find
        // the newest of each, for the 5-hour rule.
        var five: [LimitSamplePoint] = []
        var seven: [LimitSamplePoint] = []
        var latest: Date?
        var latestFive: Date?
        var latestSeven: Date?
        for s in fixed {
            if s.window == RateLimitWindowName.fiveHour {
                five.append(s)
                if s.sampledAt > (latestFive ?? .distantPast) { latestFive = s.sampledAt }
            } else if s.window == RateLimitWindowName.sevenDay {
                seven.append(s)
                if s.sampledAt > (latestSeven ?? .distantPast) { latestSeven = s.sampledAt }
            }
            if s.sampledAt > (latest ?? .distantPast) { latest = s.sampledAt }
        }
        // `LimitSamplePoint.latestBatch`'s rule, folded into the pass above
        // so the history is walked once.
        var noFiveHour = false
        if let latest {
            let cutoff = latest.addingTimeInterval(-2)
            noFiveHour = LimitSamplePoint.hasNoFiveHourWindow(
                hasFiveHour: (latestFive ?? .distantPast) >= cutoff,
                hasSevenDay: (latestSeven ?? .distantPast) >= cutoff)
        }

        func fixedWindow(_ samples: [LimitSamplePoint], duration: TimeInterval) -> Fixed {
            Fixed(
                latest: samples.first,
                recentBurn: RecentBurn.percentPerHour(
                    readings: samples.map { .init(at: $0.sampledAt, percent: $0.usedPercentage, resetsAt: $0.resetsAt) },
                    now: now, duration: duration),
                baseChart: .cycle(fixed: samples, duration: duration, now: now))
        }

        // The scoped bag holds every identity; each column reads its own. One
        // grouping pass (order kept) instead of a filter of the whole bag per
        // column, twice. The cycle builder filters on identity again, which on
        // a pre-grouped history keeps every row, so its line is the same.
        let rows = windows.latestBatch()
        let wanted = Set(rows.map(\.identity))
        var byIdentity: [String: [ScopedSamplePoint]] = [:]
        for s in scoped where wanted.contains(s.identity) {
            byIdentity[s.identity, default: []].append(s)
        }
        let scopedWindows = rows.map { row -> Scoped in
            let duration = WindowSpec.scopedDuration(group: row.group)
            let history = byIdentity[row.identity] ?? []
            return Scoped(
                row: row, duration: duration,
                recentBurn: RecentBurn.percentPerHour(
                    readings: history.map { .init(at: $0.sampledAt, percent: $0.percent, resetsAt: $0.resetsAt) },
                    now: now, duration: duration),
                baseChart: .cycle(scoped: row, history: history, duration: duration, now: now))
        }

        return PaceSeriesPrep(
            preparedAt: now,
            newestFixedAt: fixed.first?.sampledAt,
            typicalPollGap: ReadingFreshness.typicalGap(readingTimes: fixed.map(\.sampledAt)),
            hasNoFiveHourWindow: noFiveHour,
            hasReading: latest != nil || !rows.isEmpty,
            fiveHour: fixedWindow(five, duration: fiveHourDuration),
            sevenDay: fixedWindow(seven, duration: sevenDayDuration),
            scoped: scopedWindows)
    }
}
