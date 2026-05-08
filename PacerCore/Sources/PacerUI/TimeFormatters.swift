import Foundation

/// Locale-aware time formatting helpers used by chart axes and reset
/// captions across the dashboard, MenuBarExtra, and widgets.
///
/// All cached `DateFormatter`s live as static lets on a private type
/// namespace so they're lazy on first access (not file-scope) — that's
/// the only form that survived the widget-bundle crash investigation.

// MARK: - Hour-of-day labels

public enum PacerHourStyle {
    case compact, regular
}

/// Compact hour-of-day label, locale-aware.
///   - `.compact` → `"3p"` / `"15"` (tight axes like the 5h pace chart)
///   - `.regular` → `"3 PM"` / `"15:00"` (wider axes like today-by-hour)
public func pacerHour(_ date: Date, style: PacerHourStyle = .compact) -> String {
    let cal = Calendar.current
    let h24 = cal.component(.hour, from: date)
    if pacerUses24HourClock {
        switch style {
        case .compact: return String(format: "%d", h24)
        case .regular: return String(format: "%02d:00", h24)
        }
    }
    let h12 = ((h24 + 11) % 12) + 1
    let suffix = h24 < 12 ? "AM" : "PM"
    switch style {
    case .compact:
        return "\(h12)\(suffix == "PM" ? "p" : "a")"
    case .regular:
        return "\(h12) \(suffix)"
    }
}

/// `true` when the user's locale uses a 24-hour clock. Cached on first
/// read; the system locale rarely changes mid-session and we don't
/// want to re-derive on every chart axis tick.
public let pacerUses24HourClock: Bool = {
    let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
    return !template.contains("a")
}()

// MARK: - Clock-time labels

/// Wall-clock time. Locale-aware: 12h locales get `"3:47 PM"`, 24h
/// locales get `"15:47"`. Used in pace-chart "resets at" labels.
public func pacerClockTime(_ date: Date) -> String {
    Cached.clockTime.string(from: date)
}

/// Short weekday + time, used by the 7-day pace chart's reset label.
/// Returns e.g. `"Mon 3 PM"` / `"Mon 15:00"` depending on locale.
public func pacerWeekdayClock(_ date: Date) -> String {
    let f = pacerUses24HourClock ? Cached.weekdayClock24 : Cached.weekdayClock12
    return f.string(from: date)
}

/// Three-letter weekday abbreviation, locale-aware. `"Mon"`, `"Tue"`.
public func pacerWeekdayShort(_ date: Date) -> String {
    Cached.weekday.string(from: date)
}

// MARK: - Relative time

/// Relative time string that avoids `RelativeDateTimeFormatter`'s
/// default "in 0 seconds" / "0 seconds ago" output near zero. Anything
/// within 5 seconds clamps to a single reader-friendly word: future →
/// "now", past → "just now". Used by every freshness/reset chip.
public func pacerRelative(
    _ date: Date,
    style: RelativeDateTimeFormatter.UnitsStyle = .abbreviated
) -> String {
    let interval = date.timeIntervalSinceNow
    if abs(interval) < 5 {
        return interval >= 0 ? "now" : "just now"
    }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = style
    return f.localizedString(for: date, relativeTo: Date())
}

// MARK: - Reset caption

/// "resets in 2h · 9 PM" (5h cycle) / "resets in 4d · Mon 3 PM" (7d
/// cycle). The dashboard pace-card's reset line — promoted into a
/// shared helper so the gauge widget, the pace-chart widget, and any
/// future menu-bar surface all print the same string.
public func pacerResetCaption(resetsAt: Date, durationSeconds: TimeInterval) -> String {
    let rel = pacerRelative(resetsAt, style: .short)
    let clock = durationSeconds <= 6 * 3600
        ? pacerClockTime(resetsAt)
        : pacerWeekdayClock(resetsAt)
    return "resets \(rel) · \(clock)"
}

// MARK: - Cached formatters

private enum Cached {
    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEE"
        return f
    }()
    static let clockTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    static let weekdayClock12: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEE h a"
        return f
    }()
    static let weekdayClock24: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEE H:mm"
        return f
    }()
}
