import SwiftUI
import SwiftData
import PacerCore

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

    private var fiveHour: RateLimitSample? {
        samples.first { $0.window == "five_hour" }
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

    var body: some View {
        HStack(spacing: 4) {
            if style == .iconOnly || style == .iconAndPercent {
                Image(systemName: symbolName)
            }
            if style == .percentOnly || style == .iconAndPercent {
                if let pct = fiveHour?.usedPercentage {
                    Text("\(Int(pct.rounded()))%")
                        .monospacedDigit()
                }
            }
        }
    }
}

/// What renders inside the popover when the menu bar item is clicked.
/// Compact view of both rate-limit windows, today's totals, and quick
/// actions. Deliberately spare — the dashboard is the detail view; this
/// is the at-a-glance read.
struct MenuBarContent: View {
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

    init() {
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
                .padding(.vertical, 14)
            Divider().opacity(0.4)
            todayRow
                .padding(.vertical, 12)
            Divider().opacity(0.4)
            footer
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 300)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "speedometer")
                .font(.system(size: 16))
                .foregroundStyle(.tint)
            Text("Pacer")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if let latest = rateLimits.first {
                Text(pacerRelative(latest.sampledAt, style: .short))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: - Pace row

    private var paceRow: some View {
        HStack(spacing: 12) {
            paceColumn(label: "5-hour", sample: fiveHour, duration: 5 * 3600)
            Divider().frame(height: 70)
            paceColumn(label: "7-day", sample: sevenDay, duration: 7 * 86400)
        }
    }

    @ViewBuilder
    private func paceColumn(label: String, sample: RateLimitSample?, duration: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: label)
            if let s = sample, let resets = s.resetsAt {
                let pacePct = PaceMath.paceFraction(
                    now: Date(), resetsAt: resets, windowDuration: duration
                ) * 100
                let band = PaceBand(usedPct: s.usedPercentage, paceEndPct: pacePct)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(s.usedPercentage.rounded()))%")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(color(for: band))
                    Text("/")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                    Text("\(Int(pacePct.rounded()))%")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text("resets \(pacerRelative(resets, style: .short))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text("collecting…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for band: PaceBand) -> Color {
        switch band {
        case .green:  return .green
        case .white:  return .primary
        case .yellow: return .yellow
        case .red:    return .red
        }
    }

    // MARK: - Today row

    private var todayRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: "Today's spend")
                Text(pacerCost(todayCost))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Eyebrow(text: "Tokens")
                Text(pacerTokens(todayTokens))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            } label: {
                Label("Open Pacer", systemImage: "macwindow")
                    .font(.system(size: 12))
            }
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
                NotificationCenter.default.post(
                    name: .pacerOpenSettings, object: nil
                )
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 12))
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 12))
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
    }
}
