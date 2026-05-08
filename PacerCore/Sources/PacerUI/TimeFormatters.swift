import Foundation

/// Locale-aware time formatting helpers, used by chart axes and reset
/// captions across the app, MenuBarExtra, and widgets. Mirrors what
/// `App/Views/Components/PacerDesign.swift` historically had file-local
/// — promoted into PacerUI so widgets and the dashboard print the same
/// strings.
///
/// Cached `DateFormatter`s on a type namespace (lazy on first access,
/// not file-scope) — file-scoped lazy lets crashed the widget bundle
/// during the gallery-discovery investigation; type-scoped statics
/// survived. Same pattern that's already in `Widgets/WidgetSupport.swift`,
/// promoted here so we have one definition.

public enum PacerTimeFormat {

    /// `true` when the user's locale uses a 24-hour clock. Determined
    /// by asking `DateFormatter` for a short-time template and looking
    /// for an "a" period designator in the resulting format string.
    public static var uses24HourClock: Bool {
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return !template.contains("a")
    }

    /// Hour of day, locale-aware:
    ///   - `.compact`: `"3p"` / `"15"` (tight x-axis ticks)
    ///   - `.regular`: `"3 PM"` / `"15:00"` (wider axes / reset captions)
    public static func hour(_ date: Date, style: HourStyle = .compact) -> String {
        let cal = Calendar.current
        let h24 = cal.component(.hour, from: date)
        if uses24HourClock {
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

    public enum HourStyle {
        case compact, regular
    }

    /// `"3:47 PM"` / `"15:47"`. Used by the 5-hour reset caption.
    public static func clockTime(_ date: Date) -> String {
        Cached.clockTime.string(from: date)
    }

    /// `"Mon 3 PM"` / `"Mon 15:00"`. Used by the 7-day reset caption.
    public static func weekdayClock(_ date: Date) -> String {
        let f = uses24HourClock ? Cached.weekdayClock24 : Cached.weekdayClock12
        return f.string(from: date)
    }

    /// `"Mon"`-style three-letter weekday abbreviation, locale-aware.
    public static func weekdayShort(_ date: Date) -> String {
        Cached.weekday.string(from: date)
    }

    /// Relative duration via `RelativeDateTimeFormatter` with an
    /// `.short` style and a small near-zero clamp ("now" / "just now")
    /// — the formatter otherwise emits "in 0 seconds" right around
    /// reset boundaries.
    public static func relative(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if abs(interval) < 5 {
            return interval >= 0 ? "now" : "just now"
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// "resets in 2h · 9 PM" (5h cycle) / "resets in 4d · Mon 3 PM"
    /// (7d cycle). The dashboard's pace-card reset line, callable from
    /// any caller that has a `resetsAt` Date and a window duration.
    public static func resetCaption(resetsAt: Date, durationSeconds: TimeInterval) -> String {
        let rel = relative(resetsAt)
        let clock = durationSeconds <= 6 * 3600 ? clockTime(resetsAt) : weekdayClock(resetsAt)
        return "resets \(rel) · \(clock)"
    }

    private enum Cached {
        nonisolated(unsafe) static let weekday: DateFormatter = {
            let f = DateFormatter()
            f.locale = .current
            f.dateFormat = "EEE"
            return f
        }()
        nonisolated(unsafe) static let clockTime: DateFormatter = {
            let f = DateFormatter()
            f.locale = .current
            f.timeStyle = .short
            f.dateStyle = .none
            return f
        }()
        nonisolated(unsafe) static let weekdayClock12: DateFormatter = {
            let f = DateFormatter()
            f.locale = .current
            f.dateFormat = "EEE h a"
            return f
        }()
        nonisolated(unsafe) static let weekdayClock24: DateFormatter = {
            let f = DateFormatter()
            f.locale = .current
            f.dateFormat = "EEE H:mm"
            return f
        }()
    }
}
