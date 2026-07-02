import Foundation

/// Picks a small, evenly-spaced, **right-anchored** set of labels for a
/// categorical (band) date axis whose x-values are `YYYY-MM-DD` strings —
/// the shape every band date chart in the app uses (the 30-day dashboard
/// chart, the Models trend). Two problems it solves once, instead of each
/// chart re-rolling its own stride:
///
///   1. **Edge clipping.** A label forced onto the leftmost band centers
///      under a bar whose center sits only half a band-width from the
///      plot's leading edge, so it overflows and clips. Anchoring the
///      stride at the *newest* date (and dropping a surviving index 0)
///      keeps the first label off that edge and guarantees the newest bar
///      — the one the user cares about most — is always labeled.
///   2. **Varying span.** Ranges run from a week to a year or more.
///      Individual-day labels read well for short spans but crowd past a
///      couple of months, so beyond `dayThreshold` days we switch to one
///      label per month (marking the first present day of each month).
///
/// Returns the exact x-values to mark plus a `label(_:)` for each, so a
/// caller's axis stays a couple of lines:
/// ```
/// let axis = pacerDateAxis(dates)
/// .chartXAxis { AxisMarks(values: axis.values) { v in
///     AxisValueLabel { Text(axis.label(v.as(String.self) ?? "")) } } }
/// ```
public struct PacerDateAxis {
    /// The `YYYY-MM-DD` x-values to place a mark at (a subset of the input).
    public let values: [String]
    private let monthly: Bool
    private let straddlesYear: Bool

    init(values: [String], monthly: Bool, straddlesYear: Bool) {
        self.values = values
        self.monthly = monthly
        self.straddlesYear = straddlesYear
    }

    /// Display text for a marked value: `MM-DD` at day granularity, month
    /// name (`Apr`, or `Apr ’26` when the span crosses a year) at month
    /// granularity. Falls back to the raw value if it isn't a date.
    public func label(_ value: String) -> String {
        monthly ? Self.monthLabel(value, withYear: straddlesYear)
                : Self.dayLabel(value)
    }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `2026-04-30` → `04-30`. Year is dropped at this density; the user
    /// knows their own recent context.
    static func dayLabel(_ ymd: String) -> String {
        guard ymd.count == 10 else { return ymd }
        return String(ymd.suffix(5))
    }

    /// `2026-04-30` → `Apr` (or `Apr ’26` across a year boundary).
    static func monthLabel(_ ymd: String, withYear: Bool) -> String {
        guard ymd.count >= 7,
              let year = Int(ymd.prefix(4)),
              let month = Int(ymd.dropFirst(5).prefix(2)),
              month >= 1, month <= 12
        else { return ymd }
        let name = monthNames[month - 1]
        return withYear ? "\(name) ’\(String(format: "%02d", year % 100))" : name
    }
}

/// Build a right-anchored, span-aware axis for a set of `YYYY-MM-DD` dates.
/// `target` is the rough number of day-labels to aim for on short spans.
/// `dayThreshold` is the day count above which the axis flips to monthly
/// labels (default ~14 weeks, so the 90-day view still labels days).
public func pacerDateAxis(_ dates: [String], target: Int = 6, dayThreshold: Int = 100) -> PacerDateAxis {
    let sorted = Array(Set(dates)).sorted()
    guard sorted.count > 1 else {
        return PacerDateAxis(values: sorted, monthly: false, straddlesYear: false)
    }
    let straddlesYear = Set(sorted.map { $0.prefix(4) }).count > 1

    if sorted.count <= dayThreshold {
        let picks = interiorIndices(count: sorted.count, target: target).map { sorted[$0] }
        return PacerDateAxis(values: picks, monthly: false, straddlesYear: straddlesYear)
    }

    // Month granularity: the first present day of each month. Drop any month
    // marker that lands on the range's first or last band (those clip), then
    // thin toward `target` if there are still too many.
    var firstOfMonth: [String] = []
    var lastMonth = ""
    for d in sorted {
        let m = String(d.prefix(7))
        if m != lastMonth { firstOfMonth.append(d); lastMonth = m }
    }
    let interiorMonths = firstOfMonth.filter { $0 != sorted.first && $0 != sorted.last }
    let values = interiorMonths.count <= target
        ? interiorMonths
        : interiorIndices(count: interiorMonths.count, target: target).map { interiorMonths[$0] }
    return PacerDateAxis(values: values, monthly: true, straddlesYear: straddlesYear)
}

/// Up to `target` evenly-spaced indices strictly INTERIOR to `0..<count`
/// (never the two edge bands, whose centered labels overflow the plot edge
/// and clip). Ascending, deduped.
private func interiorIndices(count n: Int, target: Int) -> [Int] {
    guard n > 2, target > 0 else { return [] }
    let k = max(1, min(target, n - 2))
    var picks = Set<Int>()
    for j in 1...k {
        let idx = Int((Double(j) * Double(n - 1) / Double(k + 1)).rounded())
        picks.insert(min(max(idx, 1), n - 2))
    }
    return picks.sorted()
}
