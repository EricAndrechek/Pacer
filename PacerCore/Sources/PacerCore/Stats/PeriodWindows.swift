import Foundation

/// The dashboard's day windows — today, the last 7 days, this month — as
/// `YYYY-MM-DD` bounds, and when two of them would print the same numbers.
///
/// The dashboard rule is that no number is printed twice, and the windows
/// nest: the month holds this week's last days, the 30-day chart holds the
/// month. Two windows summed from the same daily rows add up to the same
/// cost, tokens and breakdown exactly when the same days are active in both.
/// That happens on ordinary days — the 1st (the month is today), the 7th
/// (the month is this week), a new install's first weeks (30 days, the month
/// and this week are all one set of days) — and on those days the longer
/// window's numbers would repeat a card above it.
public struct PeriodWindows: Sendable, Equatable {
    public let today: String
    /// Six days before today: the start of "This week", whose seven days run
    /// through today (`WeeklyComparisonCard`).
    public let weekStart: String
    public let monthStart: String

    public init(now: Date, calendar: Calendar = .current) {
        today = TokenSample.formatDate(now)
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        weekStart = TokenSample.formatDate(weekAgo)
        let first = calendar.dateInterval(of: .month, for: now)?.start ?? now
        monthStart = TokenSample.formatDate(first)
    }

    /// The dates of `active` that fall in this week.
    public func week(_ active: Set<String>) -> Set<String> {
        active.filter { $0 >= weekStart && $0 <= today }
    }

    /// The dates of `active` that fall in this month, through today.
    public func month(_ active: Set<String>) -> Set<String> {
        active.filter { $0 >= monthStart && $0 <= today }
    }

    /// Whether a window whose active days are `window` adds up to the same
    /// numbers as today or this week, given every active day in `active`.
    /// An empty window repeats nothing: it has no numbers to print.
    public func repeatsTodayOrWeek(_ window: Set<String>, in active: Set<String>) -> Bool {
        guard !window.isEmpty else { return false }
        let todayOnly: Set<String> = active.contains(today) ? [today] : []
        return window == todayOnly || window == week(active)
    }
}
