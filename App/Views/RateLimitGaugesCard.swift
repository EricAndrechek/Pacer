import SwiftUI
import SwiftData
import PacerCore

/// Two circular gauges showing the most recent 5h and 7d window
/// utilization, plus reset times and source/age. Backed by the latest
/// `RateLimitSample` row per window — the OAuth poller writes new
/// rows every 5 minutes, so this card refreshes silently as those
/// rows arrive.
struct RateLimitGaugesCard: View {
    @Query(sort: \RateLimitSample.sampledAt, order: .reverse)
    private var samples: [RateLimitSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Rate limits")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let latest = samples.first {
                    Text("via \(latest.source) · updated \(ageText(for: latest.sampledAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if samples.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 32) {
                    gaugeColumn(
                        label: "5-hour",
                        sample: samples.first { $0.window == "five_hour" }
                    )
                    gaugeColumn(
                        label: "7-day",
                        sample: samples.first { $0.window == "seven_day" }
                    )
                    Spacer()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func gaugeColumn(label: String, sample: RateLimitSample?) -> some View {
        VStack(alignment: .center, spacing: 6) {
            if let s = sample {
                CircularGauge(percentage: s.usedPercentage)
                Text(label)
                    .font(.caption.weight(.semibold))
                Text(resetsText(for: s.resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                CircularGauge(percentage: 0)
                    .opacity(0.4)
                Text(label)
                    .font(.caption.weight(.semibold))
                Text("no data")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 130)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Polling /api/oauth/usage on a 5-minute cadence.")
                .font(.system(.body))
            Text("If you're signed into Claude Code, values will appear within 5 minutes of the daemon starting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Formatting helpers

    private func resetsText(for date: Date?) -> String {
        guard let date else { return "resets: unknown" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "resets \(f.localizedString(for: date, relativeTo: Date()))"
    }

    private func ageText(for date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Donut-style gauge with the usage percentage in the middle. Color
/// from `UsageBand` so dashboard / MenuBarExtra / Widgets share the
/// same visual grammar.
private struct CircularGauge: View {
    let percentage: Double

    private var fraction: CGFloat {
        // Clamp to 0..1 so a server-side >100 doesn't draw past full.
        max(0, min(1, CGFloat(percentage) / 100))
    }

    private var color: Color {
        switch UsageBand(percentage: percentage) {
        case .green:  return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red:    return .red
        }
    }

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 10)
            // Filled arc
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: fraction)
            // Center label
            VStack(spacing: 0) {
                Text("\(Int(percentage.rounded()))%")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .frame(width: 90, height: 90)
    }
}
