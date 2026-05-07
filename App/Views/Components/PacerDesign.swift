import SwiftUI

/// Shared design tokens + lightweight view primitives. Centralizing them
/// here keeps every card / metric / chip in lock-step on radii, padding,
/// hairline strokes, and typography so the app reads as one consistent
/// surface instead of twelve slightly-different RoundedRectangles.
///
/// Usage:
///
///     PacerCard("Today") {
///         MetricTile(value: "$12.40", label: "cost")
///     }
///
enum PacerDesign {
    /// Standard outer corner radius for cards. Slightly larger than the
    /// macOS-default 10pt to feel a touch more deliberate; smaller than
    /// iOS-style 16pt so it still looks at home alongside system
    /// controls.
    static let cardCornerRadius: CGFloat = 14

    /// Inner padding inside cards. 20pt matches Apple's defaults for
    /// inspector-style content and gives charts room to breathe.
    static let cardPadding: CGFloat = 20

    /// Vertical spacing between stacked sections inside a column.
    static let sectionSpacing: CGFloat = 16

    /// Hairline stroke around cards. Visible in light mode, near-
    /// invisible in dark — exactly the macOS Big Sur+ feel.
    static var cardStroke: Color { Color.primary.opacity(0.06) }
}

// MARK: - Card

/// The unified card surface every grouped block uses. Replaces twelve
/// hand-rolled `.padding(20).background(controlBackgroundColor)
/// .clipShape(RoundedRectangle)` blocks with one shared primitive.
///
/// Provides:
///   - Optional `title` row with optional trailing slot (range pickers,
///     totals, freshness chips).
///   - The content body.
///   - Optional `footer` text rendered as a secondary caption — used by
///     Settings sections.
///
/// Stays generic enough to host charts, tables, dense metric rows, or
/// whatever the consumer needs.
struct PacerCard<Content: View, Trailing: View, Footer: View>: View {
    let title: String?
    let trailing: () -> Trailing
    let content: () -> Content
    let footer: () -> Footer

    init(
        _ title: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.title = title
        self.trailing = trailing
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 8)
                    trailing()
                }
            }
            content()
            footer()
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PacerDesign.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PacerDesign.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PacerDesign.cardCornerRadius, style: .continuous)
                .stroke(PacerDesign.cardStroke, lineWidth: 1)
        )
    }
}

// MARK: - Metric tiles

/// One "headline number with secondary label" tile. The standard
/// dashboard primitive — replaces the half-dozen hand-rolled
/// `Text(value).font(.system(size: 24...)) + Text(label).caption`
/// blocks scattered across cards.
///
/// `value` uses SF Rounded — a deliberate, friendlier feel than the
/// monospaced numbers that previously dominated the dashboard. We still
/// monospace digits inside SF Rounded so columns align cleanly.
struct MetricTile: View {
    let value: String
    let label: String
    /// Optional sub-line under the label (e.g. "vs 7-day avg"). Keeps the
    /// body terse: a hint rather than a second metric.
    var hint: String?
    /// Optional ornament drawn next to the value. Used for trend chips.
    var ornament: AnyView?
    /// Hero (32pt) for landing strips, regular (24pt) for in-card use.
    var size: Size = .regular

    enum Size {
        case hero, regular, compact
        var fontSize: CGFloat {
            switch self {
            case .hero: return 32
            case .regular: return 24
            case .compact: return 18
            }
        }
        var labelFont: Font {
            switch self {
            case .hero: return .system(size: 12, weight: .medium)
            case .regular, .compact: return .system(size: 11, weight: .regular)
            }
        }
    }

    init(
        value: String,
        label: String,
        hint: String? = nil,
        size: Size = .regular,
        ornament: AnyView? = nil
    ) {
        self.value = value
        self.label = label
        self.hint = hint
        self.size = size
        self.ornament = ornament
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: size.fontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                ornament
            }
            Text(label.uppercased())
                .font(size.labelFont)
                .tracking(size == .hero ? 0.4 : 0.2)
                .foregroundStyle(.secondary)
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Eyebrow

/// Tracked uppercase mini-label, used as a section divider hint or as
/// a low-emphasis tag inside dense rows. Compatible with `Spacer()` —
/// fixed-height for stable baselines.
struct Eyebrow: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(color)
    }
}

// MARK: - Chip

/// Pill-style status indicator. Used for trend chips, freshness
/// indicators, "behind pace / on pace / ahead / danger" tags.
struct Chip: View {
    let text: String
    /// SF Symbol name to draw before the text. Optional.
    var systemImage: String?
    /// Tint for the foreground (text + icon). Background is auto-derived
    /// at low opacity for a soft pill that doesn't compete with the
    /// content.
    var tint: Color = .accentColor
    /// `.regular` renders inline-sized; `.compact` is tighter for use
    /// inside dense rows.
    var size: Size = .regular

    enum Size {
        case regular, compact
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size == .regular ? 10 : 9, weight: .semibold))
            }
            Text(text)
                .font(.system(
                    size: size == .regular ? 11 : 10,
                    weight: .medium
                ))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, size == .regular ? 8 : 6)
        .padding(.vertical, size == .regular ? 3 : 2)
        .background(
            Capsule().fill(tint.opacity(0.12))
        )
    }
}

// MARK: - Freshness pulse

/// Tiny live-state indicator: a colored dot with a subtle pulsing halo
/// when "fresh." Used in the sidebar header and dashboard hero so the
/// user can confirm at a glance that data is flowing.
struct FreshnessPulse: View {
    /// Renamed from `State` to avoid clobbering SwiftUI's `@State`
    /// property wrapper inside this struct's scope.
    enum Freshness {
        case live      // <2 min
        case recent    // <10 min
        case stale     // older or unknown
        case none      // no data ever
    }

    let state: Freshness
    @State private var pulse: Bool = false

    private var color: Color {
        switch state {
        case .live:   return .green
        case .recent: return .yellow
        case .stale:  return .secondary
        case .none:   return .secondary.opacity(0.5)
        }
    }

    private var shouldPulse: Bool { state == .live }

    var body: some View {
        ZStack {
            if shouldPulse {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1.3 : 0.9)
                    .opacity(pulse ? 0.0 : 0.6)
                    .animation(
                        .easeInOut(duration: 1.4).repeatForever(autoreverses: false),
                        value: pulse
                    )
            }
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear { if shouldPulse { pulse = true } }
    }
}

// MARK: - Page scaffold

/// Standard "page" wrapper used by every primary view: ScrollView, an
/// optional toolbar row (title + leading subtitle + trailing slot), and
/// the content stack with consistent padding.
///
/// Keeps the per-view boilerplate down to:
///
///     PageScaffold("Projects", trailing: { rangePicker }) {
///         card1; card2; ...
///     }
///
struct PageScaffold<Trailing: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let trailing: () -> Trailing
    let content: () -> Content

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                header
                content()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Hover row

/// A button-styled row that lights up on hover the way Linear / Things
/// rows do. Wrap any HStack of cells with this and you get a consistent
/// list-row interaction model without fighting NSTableView.
struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Cursor flips to the pointing-hand on hover so the row reads
        // as actionable. Pulled into the shared primitive so every
        // table/list row picks it up automatically.
        .pointerStyle(.link)
    }
}

// MARK: - Formatters (shared)

/// Cost formatting used across every view that shows USD. Centralized
/// so the dashboard, menu bar, widgets, and detail sheets can't drift.
/// Adaptive: small values keep cents, big values drop them.
func pacerCost(_ usd: Double) -> String {
    if usd >= 10_000 { return String(format: "$%.0f", usd) }
    if usd >= 1_000  { return String(format: "$%.1fk", usd / 1000) }
    if usd >= 100    { return String(format: "$%.0f", usd) }
    if usd >= 10     { return String(format: "$%.1f", usd) }
    return String(format: "$%.2f", usd)
}

/// Token counts shown the same way ccusage's CLI shows them: K / M / B
/// suffixes. Keeps the dashboard readable when a big day's input alone
/// is several million tokens.
func pacerTokens(_ count: Int64) -> String {
    let n = Double(count)
    switch n {
    case 1_000_000_000_000...: return String(format: "%.2fT", n / 1_000_000_000_000)
    case 1_000_000_000...:     return String(format: "%.2fB", n / 1_000_000_000)
    case 1_000_000...:         return String(format: "%.2fM", n / 1_000_000)
    case 10_000...:            return String(format: "%.1fK", n / 1_000)
    case 1_000...:             return String(format: "%.2fK", n / 1_000)
    default:                   return "\(count)"
    }
}

/// Strip provider prefixes like `anthropic/` so model labels stay tight.
func pacerShortModel(_ name: String) -> String {
    if let lastSlash = name.lastIndex(of: "/") {
        return String(name[name.index(after: lastSlash)...])
    }
    return name
}

/// Last path component for project paths; "(unknown)" passes through.
func pacerShortPath(_ path: String) -> String {
    if path == "(unknown)" { return path }
    let last = (path as NSString).lastPathComponent
    return last.isEmpty ? path : last
}

/// Relative time string that avoids `RelativeDateTimeFormatter`'s
/// default "in 0 seconds" / "0 seconds ago" output near zero. We clamp
/// anything within 5 seconds to a single, reader-friendly word: future
/// → "now", past → "just now". Used by every freshness/reset chip in
/// the dashboard, so getting this right means the user never sees the
/// jarring "in 0 sec" string when a window is mid-reset.
func pacerRelative(_ date: Date, style: RelativeDateTimeFormatter.UnitsStyle = .abbreviated) -> String {
    let interval = date.timeIntervalSinceNow
    if abs(interval) < 5 {
        return interval >= 0 ? "now" : "just now"
    }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = style
    return f.localizedString(for: date, relativeTo: Date())
}
