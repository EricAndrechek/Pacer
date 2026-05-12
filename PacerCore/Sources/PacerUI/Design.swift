import SwiftUI

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
        ornament: AnyView? = nil
    ) {
        self.value = value
        self.label = label
        self.hint = hint
        self.size = size
        self.ornament = ornament
    }

    public var body: some View {
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

// MARK: - Freshness pulse

/// Tiny live-state indicator: a colored dot with a subtle pulsing
/// halo when "fresh." Used in the sidebar header and dashboard hero.
public struct FreshnessPulse: View {
    public enum Freshness {
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

    private var shouldPulse: Bool { state == .live && !reduceMotion }

    public var body: some View {
        // Wall-clock driven via TimelineView: the halo's phase is a
        // pure function of `Date`, so SwiftUI rebuilding the toolbar
        // item on tab switch (which torches the view's @State) can't
        // restart the animation mid-cycle or leave the halo and dot
        // out of phase. `paused: !shouldPulse` lets the timeline go
        // quiet when there's nothing to animate.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !shouldPulse)) { context in
            let raw = shouldPulse ? cycleRaw(at: context.date) : 0
            // ease-out scale: ring accelerates outward early in the
            // cycle, settles near max as it fades.
            let scalePhase = 1.0 - pow(1.0 - raw, 3)
            // sin opacity: 0 → 0.85 → 0 over the cycle. Critically,
            // opacity == 0 at *both* raw=0 and raw=1, so the
            // boundary between cycles is invisible — there's no "pop"
            // back to a bright ring at the start of each loop, which
            // the previous .repeatForever(easeOut) animation produced
            // because it reset opacity from 0 to 0.85 instantly.
            let ringOpacity = sin(.pi * raw) * 0.85
            // .overlay (not ZStack) so the halo is laid out *inside*
            // the dot's own bounds — concentric by construction,
            // independent of any HStack/ZStack alignment quirks that
            // were rendering the halo visibly offset to the left of
            // the dot in the previous implementation.
            Circle()
                .fill(color)
                .overlay {
                    Circle()
                        .stroke(color.opacity(0.6), lineWidth: 1.2)
                        .scaleEffect(1.0 + 0.55 * scalePhase)
                        .opacity(ringOpacity)
                        .allowsHitTesting(false)
                }
                .frame(width: 7, height: 7)
        }
        // Reserve consistent space in the toolbar pill no matter what
        // the halo is doing — peak scale puts the ring at ~10.85pt
        // (plus its 1.2pt stroke), comfortably inside this 14pt box.
        .frame(width: 14, height: 14)
    }

    /// 0..1 linear ramp, looping every 1.4s, from wall-clock time.
    private func cycleRaw(at date: Date) -> Double {
        let period: Double = 1.4
        return date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
    }
}

// MARK: - Page scaffold

/// Standard "page" wrapper used by every primary view: ScrollView, an
/// optional toolbar row (title + leading subtitle + trailing slot),
/// and the content stack with consistent padding.
public struct PageScaffold<Trailing: View, Content: View>: View {
    public let title: String
    public let subtitle: String?
    public let trailing: () -> Trailing
    public let content: () -> Content

    public init(
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

    public var body: some View {
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
