import SwiftUI
import AppKit
import PacerCore

/// Shared formatting helpers + design constants used by every widget.
/// App-target views aren't importable from the extension, so we keep
/// our own thin layer here. Internal access — every widget in the
/// bundle compiles together so symbols are shared.
///
/// Style decisions kept here so a one-line edit retunes every widget:
///   - Padding tiers: small=12, medium=14, large=16
///   - Hero font sizes: 30 (small), 26 (medium two-column), 24 (large rows)
///   - All numeric values monospaced + rounded for steady ticking under
///     live data updates.
enum WidgetStyle {
    static let smallPad: CGFloat = 12
    static let mediumPad: CGFloat = 14
    static let largePad: CGFloat = 16
    /// Cap for project / model name truncation in fixed-width row labels.
    static let labelColumnWidth: CGFloat = 92
    /// Min cost-column width so $-aligned columns don't dance as values
    /// shrink/grow.
    static let costColumnWidth: CGFloat = 50
}

/// Compact USD string. Strips cents above $100, single-decimal at $10,
/// two-decimal under $10. Tuned for 4-character widget budgets.
func formatCostUSD(_ usd: Double) -> String {
    if usd >= 100  { return String(format: "$%.0f", usd) }
    if usd >= 10   { return String(format: "$%.1f", usd) }
    return String(format: "$%.2f", usd)
}

/// `1234567 → 1.2M`, `12345 → 12.3K`. Matches the app's PacerDesign style.
func formatTokensCompact(_ count: Int64) -> String {
    let n = Double(count)
    switch n {
    case 1_000_000_000...: return String(format: "%.2fB", n / 1_000_000_000)
    case 1_000_000...:     return String(format: "%.1fM", n / 1_000_000)
    case 1_000...:         return String(format: "%.1fK", n / 1_000)
    default:               return "\(count)"
    }
}

/// `0.6h` → `36m`, `6500s` → `1h 48m`, etc. Used by elapsed/remaining
/// captions in widgets where space rules out a long format.
func formatDurationShort(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600
    let m = (total % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "\(total)s"
}

/// `RelativeDateTimeFormatter` with abbreviated style. Stateless;
/// allocate per call to avoid the non-Sendable formatter problem in
/// the (cheap) widget render path.
func formatRelative(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
}

/// Last path component for a Claude Code project path. Mirrors
/// `App/Views/Components/PacerDesign.swift:pacerShortPath`.
func widgetShortPath(_ path: String) -> String {
    if path == ProjectDailyAggregate.unknownProjectPath { return "(unknown)" }
    let last = (path as NSString).lastPathComponent
    return last.isEmpty ? path : last
}

/// Trim a model id like `anthropic/claude-sonnet-4-6` down to its tail.
func widgetShortModel(_ name: String) -> String {
    if let lastSlash = name.lastIndex(of: "/") {
        return String(name[name.index(after: lastSlash)...])
    }
    return name
}

/// Three-letter weekday abbreviation, locale-aware. The cached
/// formatter avoids the per-render allocation on busy timelines.
func formatWeekdayShort(_ date: Date) -> String {
    WidgetFormatters.weekday.string(from: date)
}

/// Wall-clock time, locale-aware: "3:47 PM" in 12h locales, "15:47"
/// in 24h. Mirrors `App/Views/Components/PacerDesign.swift:pacerClockTime`
/// so widget reset captions match the dashboard's pace-chart card.
func widgetClockTime(_ date: Date) -> String {
    WidgetFormatters.clockTime.string(from: date)
}

/// Short weekday + time, used by the 7-day pace caption. Returns
/// e.g. "Mon 3 PM" / "Mon 15:00" depending on locale.
/// Mirrors `pacerWeekdayClock` in the app.
func widgetWeekdayClock(_ date: Date) -> String {
    let formatter = WidgetFormatters.uses24HourClock
        ? WidgetFormatters.weekdayClock24
        : WidgetFormatters.weekdayClock12
    return formatter.string(from: date)
}

/// Type namespace for cached `DateFormatter`s. Static lets on a type
/// are lazy-on-first-access (not file-scope), which is the form that
/// survived the widget-bundle crash investigation when file-scoped
/// private lets did not.
enum WidgetFormatters {
    nonisolated(unsafe) static let weekday: DateFormatter = {
        let f = DateFormatter()
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
    /// Whether the user's locale uses a 24-hour clock. Determined by
    /// asking `DateFormatter` for a short-time template and checking
    /// for an "a" period designator in the resulting format string —
    /// same heuristic the app's `pacerUses24HourClock` uses.
    static var uses24HourClock: Bool {
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return !template.contains("a")
    }
}

/// Card-style background that mirrors the app's `PacerCard`. Apple's
/// widget templates default to a frosted `.fill.tertiary`; the app
/// uses `Color(nsColor: .controlBackgroundColor)` for its solid
/// rounded cards. Wrapping it here means a one-line background change
/// in every widget keeps them visually unified with the dashboard.
var widgetCardBackground: Color {
    Color(nsColor: .controlBackgroundColor)
}

/// Standardized widget header: a small uppercase title, an optional
/// tinted leading dot, and an optional trailing value. Every widget
/// uses this so the typographic top edge is identical across the
/// gallery.
struct WidgetTitleBar<Trailing: View>: View {
    let title: String
    let dotColor: Color?
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, dotColor: Color? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.dotColor = dotColor
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
    }
}

/// 0..1 horizontal progress bar with the same look every widget uses
/// for inline utilization indicators. Uses `.tint` so a callsite can
/// theme it via `.tint(.green)`.
struct WidgetProgressBar: View {
    let fraction: Double  // 0...1, clamped on draw
    var height: CGFloat = 6
    var cornerRadius: CGFloat = 3

    var body: some View {
        let f = max(0.04, min(1, fraction))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.tint)
                    .frame(width: geo.size.width * CGFloat(f))
            }
        }
        .frame(height: height)
    }
}

/// A small consistent empty-state body. Used wherever a widget has
/// no data yet — keeps the typography uniform across widgets so they
/// don't feel like they came from five different apps.
struct WidgetEmptyState: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
