import SwiftUI
import SwiftData
import PacerCore

/// What renders in the menu bar status item itself. We use the latest
/// 5h percentage as the headline glyph (matches the reference-impl plugin's
/// "rate limits" button hero) — at a glance you know whether you're
/// near the cap. The icon is the SF Symbol `gauge.with.dots.needle.50percent`
/// when usage is near full, falling back to `gauge.with.dots.needle.0percent`
/// when low; the text label sits next to it.
///
/// Falls back to a plain icon when no rate-limit samples exist yet.
struct MenuBarLabel: View {
    @Query(sort: \RateLimitSample.sampledAt, order: .reverse)
    private var samples: [RateLimitSample]

    private var fiveHour: RateLimitSample? {
        samples.first { $0.window == "five_hour" }
    }

    private var symbolName: String {
        guard let pct = fiveHour?.usedPercentage else {
            return "gauge.with.dots.needle.0percent"
        }
        switch UsageBand(percentage: pct) {
        case .green:  return "gauge.with.dots.needle.0percent"
        case .yellow: return "gauge.with.dots.needle.33percent"
        case .orange: return "gauge.with.dots.needle.67percent"
        case .red:    return "gauge.with.dots.needle.100percent"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
            if let pct = fiveHour?.usedPercentage {
                Text("\(Int(pct.rounded()))%")
                    .monospacedDigit()
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
    @Query(sort: \RateLimitSample.sampledAt, order: .reverse)
    private var rateLimits: [RateLimitSample]
    @Query private var todayAggregates: [DailyAggregate]

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
