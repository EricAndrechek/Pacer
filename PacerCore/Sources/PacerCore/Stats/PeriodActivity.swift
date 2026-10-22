import Foundation

/// A period's activity as a summary card draws it: how many of the period's
/// slots (days, or a day's hours) had any use, and a strip of cells across the
/// period, each cell's height what the period cost per slot there.
///
/// Cost on every strip (round 7): History and a project draw cost per day, a
/// day draws cost per hour. Round 6 drew sessions a day on History and a
/// project and cost an hour on a day, and the owner asked why the same green
/// strip meant two things on two screens. The cards lead with cost, so the
/// strip under the big figure says where that figure was spent.
///
/// Built from rollup rows only — a daily rollup's days and costs, an hourly
/// one's hours — never from `TokenSample`, and in a screen's cached derive
/// step rather than its body.
///
/// The period is every slot from its first to its last, inclusive: History's
/// "Last 30 days" is the 30 calendar days its query reads (`TimeRange.since`
/// through today), so "N of 30 days" counts exactly the days the card's other
/// numbers were summed over.
public struct PeriodActivity: Equatable, Sendable {
    public enum Unit: String, Sendable {
        case day
        case hour
    }

    /// One drawn cell: a slot, or for a long period a run of them (a week).
    public struct Cell: Equatable, Sendable, Identifiable {
        /// The cell's first and last slot: `yyyy-MM-dd` keys, or hours "0"–"23".
        public let first: String
        public let last: String
        /// Slots the cell covers: 1, or the bucket size. The oldest cell of a
        /// bucketed period can be shorter, since cells end on the period's
        /// last slot.
        public let span: Int
        /// Slots in the cell that had activity.
        public let active: Int
        /// What the cell's slots cost, summed.
        public let cost: Double

        public var id: String { first }

        /// The cell's cost per slot: its height. A mean rather than the sum,
        /// so a short oldest week compares with full ones, and a week's column
        /// reads on the same scale as a day's ("cost per day").
        public var costPerSlot: Double {
            span > 0 ? cost / Double(span) : 0
        }

        /// The share of the cell's slots that had activity, 0...1.
        public var activeShare: Double {
            span > 0 ? Double(active) / Double(span) : 0
        }
    }

    public let unit: Unit
    /// Slots in the period.
    public let slots: Int
    /// Slots with activity.
    public let active: Int
    /// The strip, oldest first; at most the `maxCells` it was built with.
    public let cells: [Cell]
    /// Slots each cell covers (the oldest may cover fewer).
    public let slotsPerCell: Int
    /// The period's first and last slot.
    public let start: String?
    public let end: String?
    /// The first and last slot with activity.
    public let firstActive: String?
    public let lastActive: String?

    public static let empty = PeriodActivity(
        unit: .day, slots: 0, active: 0, cells: [], slotsPerCell: 1,
        start: nil, end: nil, firstActive: nil, lastActive: nil)

    /// The most cells a strip draws before it buckets: a 90-day range still
    /// draws a cell a day, with a little room for a "Lifetime" of a quarter.
    public static let defaultMaxCells = 92

    // MARK: Days

    /// Every day from `start` through `end` (`yyyy-MM-dd`, inclusive).
    ///
    /// - Parameters:
    ///   - active: the days with any use. Days outside the period are ignored.
    ///     A day can be active at $0 (every model unpriced); it is drawn as a
    ///     stub, not a gap.
    ///   - cost: each day's cost; a day without an entry cost nothing.
    ///   - maxCells: above this many days, cells cover a week each (two, four
    ///     … for a very long period), ending on `end`.
    public static func days(
        active: Set<String>,
        cost: [String: Double] = [:],
        from start: String,
        through end: String,
        maxCells: Int = defaultMaxCells
    ) -> PeriodActivity {
        let keys: [String] = dayKeys(from: start, through: end)
        guard !keys.isEmpty else { return .empty }
        let inPeriod: Set<String> = active.intersection(keys)
        return build(
            unit: .day, keys: keys, isActive: { inPeriod.contains($0) },
            cost: { cost[$0] ?? 0 },
            bucket: dayBucket(slots: keys.count, maxCells: maxCells))
    }

    /// Cells per bucket for a period of `slots` days: 1 while the days fit,
    /// otherwise whole weeks, as few as fit.
    static func dayBucket(slots: Int, maxCells: Int) -> Int {
        let cap: Int = max(1, maxCells)
        guard slots > cap else { return 1 }
        let weeks: Int = (slots + 7 * cap - 1) / (7 * cap)
        return 7 * max(1, weeks)
    }

    // MARK: Hours

    /// A day's 24 hours, 0 through 23, one cell each, with each hour's cost.
    public static func hours(active: Set<Int>, cost: [Int: Double] = [:]) -> PeriodActivity {
        let keys: [String] = (0..<24).map(String.init)
        return build(
            unit: .hour, keys: keys,
            isActive: { key in Int(key).map(active.contains) ?? false },
            cost: { key in Int(key).flatMap { cost[$0] } ?? 0 },
            bucket: 1)
    }

    // MARK: Building

    private static func build(
        unit: Unit, keys: [String], isActive: (String) -> Bool,
        cost: (String) -> Double, bucket: Int
    ) -> PeriodActivity {
        let flags: [Bool] = keys.map(isActive)
        let values: [Double] = keys.map(cost)
        var cells: [Cell] = []
        // Cells end on the period's last slot, so the newest cell is always
        // whole and only the oldest can be short.
        var upper: Int = keys.count
        while upper > 0 {
            let lower: Int = max(0, upper - bucket)
            let span: Int = upper - lower
            let active: Int = flags[lower..<upper].filter { $0 }.count
            let sum: Double = values[lower..<upper].reduce(0, +)
            cells.append(Cell(
                first: keys[lower], last: keys[upper - 1], span: span,
                active: active, cost: sum))
            upper = lower
        }
        cells.reverse()
        let activeKeys: [String] = zip(keys, flags).filter { $0.1 }.map { $0.0 }
        return PeriodActivity(
            unit: unit, slots: keys.count, active: activeKeys.count, cells: cells,
            slotsPerCell: bucket, start: keys.first, end: keys.last,
            firstActive: activeKeys.first, lastActive: activeKeys.last)
    }

    /// `yyyy-MM-dd` keys from `start` through `end`, inclusive; empty when
    /// either does not parse or `end` is before `start`.
    ///
    /// Stepped in UTC: the keys are calendar days, so stepping them where no
    /// day is 23 or 25 hours long gives each exactly once.
    static func dayKeys(from start: String, through end: String) -> [String] {
        guard let from = keyFormatter.date(from: start),
              let to = keyFormatter.date(from: end),
              from <= to else { return [] }
        var keys: [String] = []
        var day: Date = from
        while day <= to {
            keys.append(keyFormatter.string(from: day))
            guard let next = utc.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return keys
    }

    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    /// Read-only after first use, which `DateFormatter` is safe for.
    nonisolated(unsafe) private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = utc
        f.timeZone = utc.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
