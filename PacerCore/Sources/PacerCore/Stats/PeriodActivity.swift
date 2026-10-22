import Foundation

/// A period's activity as a summary card draws it: how many of the period's
/// slots (days, or a day's hours) had any use, and a strip of cells across the
/// period, each cell's height the period's trend (sessions a day) where the
/// screen has one.
///
/// Built from rollup keys only — the days a daily rollup has rows for, the
/// hours an hourly one does — never from `TokenSample`, and in a screen's
/// cached derive step rather than its body.
///
/// The period is every slot from its first to its last, inclusive: History's
/// "Last 30 days" is the 31 calendar days its query reads (the cut-off day
/// through today), so "N of 31 days" counts exactly the days the card's other
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
        /// The trend's value per slot over the cell (its mean, so a short
        /// oldest cell compares with full ones); 0 when there is no trend.
        public let value: Double

        public var id: String { first }

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
    /// Whether the cells carry a trend (`value`), or only which slots were
    /// active.
    public let hasTrend: Bool

    public static let empty = PeriodActivity(
        unit: .day, slots: 0, active: 0, cells: [], slotsPerCell: 1,
        start: nil, end: nil, firstActive: nil, lastActive: nil, hasTrend: false)

    /// The most cells a strip draws before it buckets: a 90-day range (91
    /// days, the cut-off day included) still draws a cell a day.
    public static let defaultMaxCells = 92

    // MARK: Days

    /// Every day from `start` through `end` (`yyyy-MM-dd`, inclusive).
    ///
    /// - Parameters:
    ///   - active: the days with any use. Days outside the period are ignored.
    ///   - trend: a value per day (sessions), or nil for a strip that shows
    ///     only which days were active.
    ///   - maxCells: above this many days, cells cover a week each (two, four
    ///     … for a very long period), ending on `end`.
    public static func days(
        active: Set<String>,
        trend: [String: Double]? = nil,
        from start: String,
        through end: String,
        maxCells: Int = defaultMaxCells
    ) -> PeriodActivity {
        let keys: [String] = dayKeys(from: start, through: end)
        guard !keys.isEmpty else { return .empty }
        let inPeriod: Set<String> = active.intersection(keys)
        return build(
            unit: .day, keys: keys, isActive: { inPeriod.contains($0) },
            value: { trend?[$0] ?? 0 }, hasTrend: trend != nil,
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

    /// A day's 24 hours, 0 through 23, one cell each.
    public static func hours(active: Set<Int>, trend: [Int: Double]? = nil) -> PeriodActivity {
        let keys: [String] = (0..<24).map(String.init)
        return build(
            unit: .hour, keys: keys,
            isActive: { key in Int(key).map(active.contains) ?? false },
            value: { key in Int(key).flatMap { trend?[$0] } ?? 0 },
            hasTrend: trend != nil, bucket: 1)
    }

    // MARK: Building

    private static func build(
        unit: Unit, keys: [String], isActive: (String) -> Bool,
        value: (String) -> Double, hasTrend: Bool, bucket: Int
    ) -> PeriodActivity {
        let flags: [Bool] = keys.map(isActive)
        let values: [Double] = keys.map(value)
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
                active: active, value: span > 0 ? sum / Double(span) : 0))
            upper = lower
        }
        cells.reverse()
        let activeKeys: [String] = zip(keys, flags).filter { $0.1 }.map { $0.0 }
        return PeriodActivity(
            unit: unit, slots: keys.count, active: activeKeys.count, cells: cells,
            slotsPerCell: bucket, start: keys.first, end: keys.last,
            firstActive: activeKeys.first, lastActive: activeKeys.last, hasTrend: hasTrend)
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
