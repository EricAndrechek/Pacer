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
    /// Cap the fetch — the OAuth poller writes 2 rows per 5-minute
    /// cycle, so a 7-day history can be ~4k rows. We only ever look at
    /// `samples.first { $0.window == "five_hour" }`, which the most
    /// recent two samples will always satisfy. Without the cap, every
    /// SwiftData save materialized the full history just to fire the
    /// menu-bar label re-render.
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
/// Compact view of both rate-limit windows + today's totals + an
/// "Open Pacer" affordance. Deliberately spare — the dashboard is the
/// detail view; this is the at-a-glance read.
struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    /// Same fetchLimit rationale as MenuBarLabel — we only need the
    /// latest sample per window, and 8 rows is a safe upper bound.
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "speedometer")
                Text("Pacer").font(.headline)
                Spacer()
                if let latest = rateLimits.first {
                    Text(ageText(latest.sampledAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 16) {
                gaugeColumn(label: "5-hour", sample: fiveHour, duration: 5 * 3600)
                gaugeColumn(label: "7-day", sample: sevenDay, duration: 7 * 86400)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today").font(.caption.weight(.medium))
                    Text(formatCost(todayCost))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Tokens").font(.caption.weight(.medium))
                    Text(formatTokens(todayTokens))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
            }

            Divider()

            HStack {
                Button("Open Pacer") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                    // Settings is a tab inside the main window now,
                    // not a separate Settings scene. Posting the
                    // notification flips the TabView selection.
                    NotificationCenter.default.post(
                        name: .pacerOpenSettings, object: nil)
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 280)
    }

    @ViewBuilder
    private func gaugeColumn(label: String, sample: RateLimitSample?, duration: TimeInterval) -> some View {
        VStack(spacing: 4) {
            CircularGauge(
                percentage: sample?.usedPercentage ?? 0,
                lineWidth: 6,
                labelFont: .system(size: 14, weight: .semibold, design: .rounded)
            )
            .frame(width: 56, height: 56)
            .opacity(sample == nil ? 0.4 : 1.0)
            Text(label)
                .font(.caption.weight(.semibold))
            Text(resetText(sample?.resetsAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "resets \(f.localizedString(for: date, relativeTo: Date()))"
    }

    private func ageText(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 100 { return String(format: "$%.0f", usd) }
        if usd >= 10  { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }

    private func formatTokens(_ count: Int64) -> String {
        let n = Double(count)
        switch n {
        case 1_000_000_000...:  return String(format: "%.2fB", n / 1_000_000_000)
        case 1_000_000...:      return String(format: "%.2fM", n / 1_000_000)
        case 10_000...:         return String(format: "%.1fK", n / 1_000)
        case 1_000...:          return String(format: "%.2fK", n / 1_000)
        default:                return "\(count)"
        }
    }
}
