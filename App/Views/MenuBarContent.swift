import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// What renders in the menu bar status item. The display is governed by
/// `PacerSettings.MenuBarStyle` (icon-only / percent-only / both, plus
/// hidden which is handled at the scene level). The icon glyph itself
/// is governed by `PacerSettings.MenuBarIconStyle`:
///   - gaugeNeedle: SF Symbol `gauge.with.dots.needle.*percent` whose
///                  fill ramps with the current band.
///   - ringFill:    SF Symbol `circle.dotted` -> filled ring proxies.
///   - dot:         a colored dot, smallest visual weight.
///
/// Falls back to a neutral icon when no rate-limit samples exist yet.
struct MenuBarLabel: View {
    /// Cap the fetch — we only ever look at the most-recent sample per
    /// window. Without the cap, every SwiftData save materialized the
    /// full ~4k-row history just to fire the menu-bar label re-render.
    @Query(MenuBarLabel.recentDescriptor)
    private var samples: [RateLimitSample]

    private static let recentDescriptor: FetchDescriptor<RateLimitSample> = {
        var d = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 8
        return d
    }()

    @AppStorage(PacerSettings.Key.menuBarStyle, store: PacerSettings.store)
    private var styleRaw: String = PacerSettings.MenuBarStyle.iconAndPercent.rawValue

    @AppStorage(PacerSettings.Key.menuBarIconStyle, store: PacerSettings.store)
    private var iconRaw: String = PacerSettings.MenuBarIconStyle.gaugeNeedle.rawValue

    /// Last band we rendered. When this jumps to a warmer band (yellow
    /// → orange → red) we kick a one-shot scale pulse so the icon
    /// visibly reacts to the threshold crossing. Without it the only
    /// signal of "we just went over 75%" was the banner notification —
    /// which the user might have dismissed on a different screen.
    @State private var lastBand: UsageBand?
    @State private var pulse: Bool = false
    /// Reduce-motion suppression: the icon color escalation alone
    /// already communicates warming; the scale pulse is decorative.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fiveHour: RateLimitSample? {
        samples.first { $0.window == "five_hour" }
    }

    private var sevenDay: RateLimitSample? {
        samples.first { $0.window == "seven_day" }
    }

    private var style: PacerSettings.MenuBarStyle {
        PacerSettings.MenuBarStyle(rawValue: styleRaw) ?? .iconAndPercent
    }

    private var iconStyle: PacerSettings.MenuBarIconStyle {
        PacerSettings.MenuBarIconStyle(rawValue: iconRaw) ?? .gaugeNeedle
    }

    private var band: UsageBand? {
        fiveHour.map { UsageBand(percentage: $0.usedPercentage) }
    }

    private var symbolName: String {
        switch iconStyle {
        case .gaugeNeedle:
            switch band {
            case .green:        return "gauge.with.dots.needle.0percent"
            case .yellow:       return "gauge.with.dots.needle.33percent"
            case .orange:       return "gauge.with.dots.needle.67percent"
            case .red:          return "gauge.with.dots.needle.100percent"
            case nil:           return "gauge.with.dots.needle.0percent"
            }
        case .ringFill:
            switch band {
            case .green, nil:   return "circle.dotted"
            case .yellow:       return "circle.lefthalf.filled"
            case .orange:       return "circle.righthalf.filled"
            case .red:          return "circle.fill"
            }
        case .dot:
            return "circle.fill"
        }
    }

    /// Color the SF Symbol picks up via `.palette` rendering. Reuses
    /// PaceBandColor's mapping so the menu bar warms up in lockstep
    /// with the dashboard's pace chart.
    private var bandColor: Color {
        switch band {
        case .green, nil: return .secondary
        case .yellow:     return .yellow
        case .orange:     return .orange
        case .red:        return .red
        }
    }

    /// Tooltip shown on hover. Apple's Battery / Wi-Fi / Volume status
    /// items all surface a one-line summary on hover; ours had nothing.
    private var tooltip: String {
        var parts: [String] = []
        if let f = fiveHour {
            parts.append("5h: \(Int(f.usedPercentage.rounded()))%")
        }
        if let s = sevenDay {
            parts.append("7d: \(Int(s.usedPercentage.rounded()))%")
        }
        if let resets = fiveHour?.resetsAt {
            parts.append("resets \(pacerRelative(resets))")
        }
        if parts.isEmpty {
            return "Pacer — collecting…"
        }
        return parts.joined(separator: " • ")
    }

    /// Percentage label shown to the right of the icon. The `% only`
    /// mode now prefixes "5h " so a glance tells you which window —
    /// before, "23%" with no context was ambiguous when both windows
    /// are tracked.
    private var percentLabel: String? {
        guard let pct = fiveHour?.usedPercentage else { return nil }
        let rounded = "\(Int(pct.rounded()))%"
        return style == .percentOnly ? "5h \(rounded)" : rounded
    }

    var body: some View {
        HStack(spacing: 4) {
            if style == .iconOnly || style == .iconAndPercent {
                Image(systemName: symbolName)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(bandColor, Color.secondary.opacity(0.5))
                    .scaleEffect(pulse ? 1.15 : 1.0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.55), value: pulse)
            }
            if style == .percentOnly || style == .iconAndPercent,
               let label = percentLabel {
                Text(label)
                    .monospacedDigit()
                    .foregroundStyle(band == .red ? Color.red : Color.primary)
            }
        }
        .help(tooltip)
        .onChange(of: band) { oldValue, newValue in
            // Pulse only on warming (green→yellow, yellow→orange, etc.).
            // Cooling (band drops at cycle reset) shouldn't draw the eye.
            guard let newValue, isWarming(from: oldValue, to: newValue) else {
                lastBand = newValue
                return
            }
            lastBand = newValue
            // Skip the scale pulse under Reduce Motion — color escalation
            // is enough.
            guard !reduceMotion else { return }
            pulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                pulse = false
            }
        }
    }

    private func isWarming(from old: UsageBand?, to new: UsageBand) -> Bool {
        guard let old else { return new != .green }
        return new.severity > old.severity
    }
}

private extension UsageBand {
    /// Higher = warmer / more urgent. Used to detect upward crossings
    /// for the pulse animation.
    var severity: Int {
        switch self {
        case .green:  return 0
        case .yellow: return 1
        case .orange: return 2
        case .red:    return 3
        }
    }
}

/// What renders inside the popover when the menu bar item is clicked.
/// Compact view of both rate-limit windows, today's totals, and quick
/// actions. Deliberately spare — the dashboard is the detail view; this
/// is the at-a-glance read.
struct MenuBarContent: View {
    /// Optional dismiss hook so footer actions can close the popover
    /// before flipping windows. The custom NSStatusItem host (in
    /// `PacerAppDelegate`) injects this; if it's nil, the buttons
    /// still work — they just don't auto-close.
    var onDismiss: (() -> Void)? = nil

    @Environment(\.openWindow) private var openWindow
    @Query(MenuBarContent.recentDescriptor)
    private var rateLimits: [RateLimitSample]
    @Query private var todayAggregates: [DailyAggregate]

    private static let recentDescriptor: FetchDescriptor<RateLimitSample> = {
        var d = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 8
        return d
    }()

    init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
        let today = TokenSample.formatDate(Date())
        _todayAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == today }
        )
    }

    private var fiveHour: RateLimitSample? { rateLimits.first { $0.window == "five_hour" } }
    private var sevenDay: RateLimitSample? { rateLimits.first { $0.window == "seven_day" } }

    private var todayCost: Double {
        todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
    }

    private var todayTokens: Int64 {
        todayAggregates.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            paceRow
                .padding(.vertical, 12)
            Divider().opacity(0.4)
            todayRow
                .padding(.vertical, 12)
            Divider().opacity(0.4)
            footer
                .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        // `idealWidth` rather than a hard `width` so locale variants
        // can flex a bit when the numbers/labels need more room.
        // `maxHeight` caps growth on tall displays — without it the
        // popover would expand indefinitely if a future iteration of
        // this view added more content.
        .frame(idealWidth: 320, maxHeight: 480)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image("PacerLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            // Headline ≈ prior 14pt + semibold; Dynamic-Type-aware.
            Text("Pacer")
                .font(.headline)
            Spacer()
            if let latest = rateLimits.first {
                Text(pacerRelative(latest.sampledAt, style: .short))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Latest rate-limit sample")
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: - Pace row

    /// Two pace columns side-by-side. Each column hosts a small
    /// `CircularGauge` (same primitive widgets and the dashboard
    /// pace card use) and a stack of supporting numbers — visual
    /// consistency with the rest of the app.
    private var paceRow: some View {
        HStack(alignment: .top, spacing: 14) {
            paceColumn(label: "5-hour", sample: fiveHour, duration: 5 * 3600)
            Divider().frame(height: 78)
            paceColumn(label: "7-day", sample: sevenDay, duration: 7 * 86400)
        }
    }

    @ViewBuilder
    private func paceColumn(label: String, sample: RateLimitSample?, duration: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: label)
            if let s = sample, let resets = s.resetsAt {
                let pacePct = PaceMath.paceFraction(
                    now: Date(), resetsAt: resets, windowDuration: duration
                ) * 100
                let band = PaceBand(usedPct: s.usedPercentage, paceEndPct: pacePct)
                HStack(alignment: .center, spacing: 10) {
                    CircularGauge(
                        percentage: s.usedPercentage,
                        lineWidth: 4,
                        labelFont: .system(size: 11, weight: .semibold, design: .rounded)
                    )
                    .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 3) {
                            Text("/")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Text("\(Int(pacePct.rounded()))% pace")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(band.color)
                        }
                        Text("resets \(pacerRelative(resets, style: .short))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 10) {
                    Circle()
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 4)
                        .frame(width: 42, height: 42)
                    Text("collecting…")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Today row

    private var todayRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(text: "Today's spend")
                Text(pacerCost(todayCost))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Eyebrow(text: "Tokens")
                Text(pacerTokens(todayTokens))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Footer

    /// Footer rows now use `MenuBarFooterButton` so they pick up a
    /// hover background — `.borderless` left them visually flat next to
    /// the rest of the popover, which had hover affordance everywhere
    /// else (cards, sidebar items, etc.).
    private var footer: some View {
        HStack(spacing: 4) {
            MenuBarFooterButton(
                title: "Open Pacer",
                systemImage: "macwindow"
            ) {
                onDismiss?()
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            MenuBarFooterButton(
                title: "Settings",
                systemImage: "gearshape"
            ) {
                onDismiss?()
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
                NotificationCenter.default.post(
                    name: .pacerOpenSettings, object: nil
                )
            }
            Spacer(minLength: 0)
            MenuBarFooterButton(
                title: "Quit",
                systemImage: "power",
                tint: .secondary
            ) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

/// Footer-row button with a subtle hover background. Mirrors the
/// `HoverRow` pattern used in the dashboard tables; lives here as its
/// own primitive because the popover footer is a horizontal layout
/// rather than the full-width row HoverRow expects.
private struct MenuBarFooterButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .primary
    let action: () -> Void
    @State private var hovering: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
