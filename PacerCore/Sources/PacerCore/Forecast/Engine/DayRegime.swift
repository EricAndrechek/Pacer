import Foundation

/// The coarsest, strongest usage regime: weekday vs weekend. On real data this
/// is a *7× split* (probability of actively burning tokens 0.30 on weekdays vs
/// 0.041 on weekends), which is exactly why a weekday-blind projection wrecks
/// weekend numbers — running a Tuesday-shaped curve through a near-idle Saturday.
/// Every regime-aware model in the engine gates on this first.
public enum DayRegime: String, Sendable, Equatable, CaseIterable {
    case weekday
    case weekend

    /// Classify a date by its weekday in the given calendar (1 = Sunday,
    /// 7 = Saturday in Gregorian).
    public static func of(_ date: Date, calendar: Calendar) -> DayRegime {
        let wd = calendar.component(.weekday, from: date)
        return (wd == 1 || wd == 7) ? .weekend : .weekday
    }
}
