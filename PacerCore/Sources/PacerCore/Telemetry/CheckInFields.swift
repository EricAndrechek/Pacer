import Foundation

/// The pure parts of the daily check-in's fields, apart from the app target so
/// they can be tested (docs/telemetry-plan.md, "Check-in core").
public enum CheckInFields {

    /// The distinct plan tiers on this Mac, sorted and joined with `+`, the
    /// `default_claude_` prefix dropped: `max_20x`, `max_5x+max_20x`. `none`
    /// when there are no accounts. Input is the already-sanitized tier.
    public static func plans(tiers: [String]) -> String {
        let prefix = "default_claude_"
        let names = Set(tiers.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 })
        return names.isEmpty ? "none" : names.sorted().joined(separator: "+")
    }

    /// Whether the 5-hour window exists for the scope being reported: for one
    /// account its own flag (`scoped`, nil when that account is unknown), for
    /// all accounts only when not every one lacks it. No accounts yet is
    /// "unknown", so the window is kept.
    public static func reportsFiveHour(scopedHasNoFiveHour scoped: Bool?, allHaveNoFiveHour flags: [Bool],
                                       scopedToAccount: Bool) -> Bool {
        if scopedToAccount { return !(scoped ?? false) }
        return flags.isEmpty || flags.contains(false)
    }

    // MARK: - Install date

    /// The day this install was first seen, "YYYY-MM-DD" in local time.
    /// - `stored` is what an earlier launch saved; it always wins.
    /// - Otherwise the earliest evidence the store holds (`earliestEvidence`,
    ///   e.g. the oldest account's `firstSeenAt`), else `now`.
    /// Returns the day and whether it must be saved.
    public static func installFirstSeen(stored: String?, earliestEvidence: Date?, now: Date,
                                        calendar: Calendar = .current) -> (day: String, save: Bool) {
        if let stored, parse(stored, calendar: calendar) != nil { return (stored, false) }
        let basis = min(earliestEvidence ?? now, now)
        return (format(basis, calendar: calendar), true)
    }

    /// Whole days from the first-seen day to `now`; never negative.
    public static func installAgeDays(firstSeen: String, now: Date, calendar: Calendar = .current) -> Int {
        guard let start = parse(firstSeen, calendar: calendar) else { return 0 }
        let days = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day ?? 0
        return max(days, 0)
    }

    static func format(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func parse(_ day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 2000 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
