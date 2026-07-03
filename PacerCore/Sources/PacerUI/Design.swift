import SwiftUI
import PacerCore

/// Shared design tokens + lightweight view primitives. Centralizing
/// them here keeps every card / metric / chip in lock-step on radii,
/// padding, hairline strokes, and typography so the app reads as one
/// consistent surface — and the same primitives are now used by the
/// widget extension and (eventually) the menu-bar popover.
///
/// Usage:
///
///     PacerCard("Today") {
///         MetricTile(value: "$12.40", label: "cost")
///     }
public enum PacerDesign {
    /// Standard outer corner radius for cards. Slightly larger than
    /// the macOS-default 10pt to feel a touch more deliberate; smaller
    /// than iOS-style 16pt so it still looks at home alongside system
    /// controls.
    public static let cardCornerRadius: CGFloat = 14

    /// Inner padding inside cards. 20pt matches Apple's defaults for
    /// inspector-style content and gives charts room to breathe.
    public static let cardPadding: CGFloat = 20

    /// Vertical spacing between stacked sections inside a column.
    public static let sectionSpacing: CGFloat = 16

    /// Hairline stroke around cards. Visible in light mode, near-
    /// invisible in dark.
    public static var cardStroke: Color { Color.primary.opacity(0.06) }

    /// The card's solid fill. Mirrored to the widget container
    /// background so the panel and the dashboard cards blend.
    public static var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
}

// MARK: - Card

/// The unified card surface every grouped block uses. Replaces twelve
/// hand-rolled `.padding(20).background(controlBackgroundColor)
/// .clipShape(RoundedRectangle)` blocks with one shared primitive.
public struct PacerCard<Content: View, Trailing: View, Footer: View>: View {
    let title: String?
    let trailing: () -> Trailing
    let content: () -> Content
    let footer: () -> Footer

    public init(
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

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    // `.title3` is the macOS Dynamic Type bracket that
                    // sits where 15pt landed empirically; pairing with
                    // `.semibold` reproduces the prior visual weight
                    // while letting card titles respect the user's
                    // Display & Text Size accessibility setting.
                    Text(title)
                        .font(.title3)
                        .fontWeight(.semibold)
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
                .fill(PacerDesign.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PacerDesign.cardCornerRadius, style: .continuous)
                .stroke(PacerDesign.cardStroke, lineWidth: 1)
        )
        // Native Mac UIs (Mail, Notes, Reminders, Things) rely on the
        // tonal contrast between window background and card fill,
        // plus a 1pt hairline stroke, to separate cards. Drop shadows
        // on flat content read as iOS-port; removing the shadow makes
        // the surface feel native without losing the card boundary.
    }
}

// MARK: - Metric tiles

/// One "headline number with secondary label" tile. The standard
/// dashboard primitive — replaces the half-dozen hand-rolled
/// `Text(value).font(.system(size: 24...)) + Text(label).caption`
/// blocks scattered across cards.
public struct MetricTile: View {
    public let value: String
    public let label: String
    /// Optional sub-line under the label (e.g. "vs 7-day avg").
    public var hint: String?
    /// Optional ornament drawn next to the value. Used for trend chips.
    public var ornament: AnyView?
    /// Hero (32pt) for landing strips, regular (24pt) for in-card use.
    public var size: Size = .regular
    /// Optional hover tooltip — `.help(tooltip)` on the whole tile.
    /// Use this to surface the exact value when `value` is shown in
    /// its compact form ("$10.8k") so a hover reveals "$10,770.42".
    /// `pacerCost` + `pacerCostExact` are the canonical pair.
    public var tooltip: String?

    public enum Size {
        case hero, regular, compact
        /// Hero numbers stay explicit — they need a specific visual
        /// weight in the tile layouts and the layouts use
        /// `minimumScaleFactor` to recover under Dynamic Type's larger
        /// brackets. The labels under the value, in contrast, use
        /// Dynamic Type styles so they scale cleanly.
        var fontSize: CGFloat {
            switch self {
            case .hero: return 32
            case .regular: return 24
            case .compact: return 18
            }
        }
        var labelFont: Font {
            switch self {
            case .hero:               return .callout.weight(.medium)
            case .regular, .compact:  return .subheadline
            }
        }
    }

    public init(
        value: String,
        label: String,
        hint: String? = nil,
        size: Size = .regular,
        ornament: AnyView? = nil,
        tooltip: String? = nil
    ) {
        self.value = value
        self.label = label
        self.hint = hint
        self.size = size
        self.ornament = ornament
        self.tooltip = tooltip
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: size.fontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    // Hero values in narrow LazyVGrid columns hit the
                    // column edge with 5-digit costs ("$10767") and
                    // wrapped to a second line, which dragged the
                    // label down and broke the row alignment. Clamp
                    // to a single line and shrink in place instead;
                    // the labels are short enough that they never
                    // need scaling.
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                ornament
            }
            Text(label.uppercased())
                .font(size.labelFont)
                .tracking(size == .hero ? 0.4 : 0.2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        // `.help()` no-ops when its argument is nil-equivalent, but we
        // skip it entirely on `tooltip == nil` so a tile without an
        // exact form doesn't surface an empty tooltip on hover.
        .modifier(OptionalHelp(text: tooltip))
    }
}

/// Apply `.help(text)` only when `text` is non-nil. SwiftUI's
/// `.help(_:)` always installs a tooltip; passing the empty string
/// shows an empty bubble on hover, which reads as broken.
private struct OptionalHelp: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}

// MARK: - Eyebrow

/// Tracked uppercase mini-label, used as a section divider hint or as
/// a low-emphasis tag inside dense rows.
public struct Eyebrow: View {
    public let text: String
    public var color: Color = .secondary

    public init(text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(color)
    }
}

// MARK: - Chip

/// Pill-style status indicator. Used for trend chips, freshness
/// indicators, "behind pace / on pace / ahead / danger" tags.
public struct Chip: View {
    public let text: String
    public var systemImage: String?
    public var tint: Color = .accentColor
    public var size: Size = .regular

    public enum Size {
        case regular, compact
    }

    public init(
        text: String,
        systemImage: String? = nil,
        tint: Color = .accentColor,
        size: Size = .regular
    ) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.size = size
    }

    public var body: some View {
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

// MARK: - Flow layout

/// A single-row-preferring wrapping layout: lays subviews left-to-right and
/// only breaks to a new row when the next one wouldn't fit the proposed width.
/// Used for the dashboard header's advisor-badge strip so the pills stay
/// atomic (each sized to its own content, never wrapping its text) and flow
/// onto a second row instead of clipping when several fire at once.
///
/// Rows are `alignment`-anchored (default `.trailing`, to hug the right edge
/// of a right-anchored header), and the layout reports a `firstTextBaseline`
/// so it still lines up with a sibling title in a baseline-aligned HStack.
public struct FlowLayout: Layout {
    public enum HAlign: Sendable { case leading, center, trailing }

    public var spacing: CGFloat
    public var rowSpacing: CGFloat
    public var alignment: HAlign

    public init(spacing: CGFloat = 8, rowSpacing: CGFloat = 6, alignment: HAlign = .trailing) {
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        self.alignment = alignment
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var out: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let gap = row.indices.isEmpty ? 0 : spacing
            if !row.indices.isEmpty, row.width + gap + s.width > maxWidth {
                out.append(row); row = Row()
            }
            let g = row.indices.isEmpty ? 0 : spacing
            row.width += g + s.width
            row.height = max(row.height, s.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { out.append(row) }
        return out
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rs = rows(maxWidth: maxWidth, subviews)
        let width = rs.map(\.width).max() ?? 0
        let height = rs.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(0, rs.count - 1))
        return CGSize(width: maxWidth.isFinite ? min(width, maxWidth) : width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rs = rows(maxWidth: bounds.width, subviews)
        var y = bounds.minY
        for row in rs {
            let slack = max(0, bounds.width - row.width)
            var x = bounds.minX + (alignment == .trailing ? slack : alignment == .center ? slack / 2 : 0)
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(
                    at: CGPoint(x: x, y: y + (row.height - s.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    /// Keep the strip baseline-aligned with a sibling title: report the first
    /// row's first pill's text baseline.
    public func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect,
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = subviews.first else { return nil }
        let firstRow = rows(maxWidth: bounds.width, subviews).first
        let rowHeight = firstRow?.height ?? first.sizeThatFits(.unspecified).height
        let s = first.sizeThatFits(.unspecified)
        let top = (rowHeight - s.height) / 2
        if let base = first.dimensions(in: ProposedViewSize(s))[explicit: .firstTextBaseline] {
            return top + base
        }
        return nil
    }
}

// MARK: - Freshness pulse

/// Tiny live-state indicator: a colored dot with a subtle pulsing
/// halo when "fresh." Used in the sidebar header and dashboard hero.
public struct FreshnessPulse: View {
    public enum Freshness: Equatable, Sendable {
        case live      // <2 min
        case recent    // <10 min
        case stale     // older or unknown
        case none      // no data ever
    }

    public let state: Freshness
    /// Honor the user's "Reduce motion" accessibility preference — the
    /// repeating halo animation is decorative, the colored dot alone
    /// communicates freshness just as well without motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Window-visibility tracker. When the main window isn't on
    /// screen, the TimelineView still kept ticking and re-rendering
    /// at 12fps — meaningful CPU for a decorative halo with no
    /// audience. Pausing here drops it to zero work while the user is
    /// using another app.
    @State private var visibility = PacerWindowVisibility.shared

    public init(state: Freshness) {
        self.state = state
    }

    private var color: Color {
        switch state {
        case .live:   return .green
        case .recent: return .yellow
        case .stale:  return .secondary
        case .none:   return .secondary.opacity(0.5)
        }
    }

    private var shouldPulse: Bool {
        state == .live && !reduceMotion && visibility.isMainWindowVisible
    }

    public var body: some View {
        // Static colored dot, NO TimelineView, NO animation.
        //
        // **Why no halo:** the previous `TimelineView(.animation(12fps))`
        // halo measured ~25 % MainActor CPU in `sample(1)` when the
        // main window was open and `state == .live`. The dominant cost
        // was `[NSWindow updateConstraintsIfNeeded]` →
        // `[NSToolbarItem _scalableMinSize]` running on every
        // TimelineView tick — NSToolbarItem's AutoLayout chain
        // re-validates whenever its hosted SwiftUI subtree rebuilds,
        // even though FreshnessPulse's external 14×14 frame is fixed
        // and the scaleEffect was purely a render transform. Going
        // static eliminates the per-tick AppKit constraint pass while
        // preserving the colored-dot freshness signal (the toolbar's
        // accompanying "live" / "3m ago" text label is the primary
        // signal anyway; the halo was decoration). `_ = visibility`
        // keeps the `@State` reference alive so the type stays valid
        // for a future re-introduction via a CALayer-driven animation
        // that bypasses SwiftUI's per-frame body re-eval.
        _ = visibility
        _ = reduceMotion
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            // Reserve the same 14×14 footprint the prior halo
            // implementation used so the toolbar pill's layout
            // doesn't shift across the build.
            .frame(width: 14, height: 14)
    }
}

// MARK: - Page scaffold

/// Standard "page" wrapper used by every primary view: ScrollView, an
/// optional toolbar row (title + leading subtitle + trailing slot),
/// and the content stack with consistent padding.
public struct PageScaffold<Trailing: View, Content: View>: View {
    public let title: String
    public let subtitle: String?
    /// Lazy (`LazyVStack`) defers each card's body + `@Query` until it
    /// scrolls into view — lighter during active use, but the per-card
    /// realize-on-appear cost lands *during* the scroll (visible jank when
    /// scrolling past heavy chart cards). Eager (`VStack`) renders every
    /// card once up front, so scrolling only translates already-rendered
    /// content — buttery, at the cost of every card's `@Query` being live.
    /// Pages with a small, fixed card set (the dashboard) prefer eager now
    /// that the `@Query` fanout is mitigated; long/unbounded lists keep
    /// lazy. See docs/perf-tuning.md.
    public let lazy: Bool
    public let trailing: () -> Trailing
    public let content: () -> Content

    public init(
        _ title: String,
        subtitle: String? = nil,
        lazy: Bool = true,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.lazy = lazy
        self.trailing = trailing
        self.content = content
    }

    public var body: some View {
        ScrollView {
            // `LazyVStack` defers each card's view body — and crucially
            // its `@Query` subscription — until that card is in the
            // viewport. Previously the dashboard's 7+ cards all
            // subscribed eagerly: every SwiftData save invalidated
            // every `@Query` on every card, even ones below the fold.
            // With the lazy stack, off-screen cards aren't realized,
            // their queries aren't subscribed, and the user's hot path
            // (the top half of the page) gets all the SwiftData
            // notification budget.
            //
            // Trade-off: scrolling a previously-off-screen card back
            // into view re-runs its `onAppear` cache refresh. The
            // cache populates in the same frame as the cards we
            // already had (in cycle ms terms), so the visible churn
            // is minor and only happens on demand. The header stays
            // outside the lazy stack so the page title doesn't
            // disappear on scroll.
            Group {
                if lazy {
                    LazyVStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                        header
                        content()
                    }
                } else {
                    // Eager: every card realized once on appear, so scrolling
                    // never re-runs a card's body/render mid-flight (the
                    // scroll-jank cause when heavy chart cards crossed the
                    // viewport in the lazy stack).
                    VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                        header
                        content()
                    }
                }
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
                // `.largeTitle` matches the prior 26pt at default
                // Dynamic Type and scales for users with Display & Text
                // Size bumped. `.semibold` + rounded design preserves
                // the look of the previous hand-rolled size.
                Text(title)
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                    .fontDesign(.rounded)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
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
public struct HoverRow<Content: View>: View {
    public let action: () -> Void
    @ViewBuilder public let content: () -> Content
    @State private var hovering = false

    public init(action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.action = action
        self.content = content
    }

    public var body: some View {
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
        // Arrow cursor (default) — macOS HIG reserves the pointing-hand
        // for hyperlinks. Native Mac list rows (Finder, Mail, Things)
        // keep the arrow; the hover background is the affordance.
    }
}
