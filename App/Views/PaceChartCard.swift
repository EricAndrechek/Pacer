import SwiftUI
import SwiftData
import Charts
import PacerCore

/// Pace charts for the 5-hour and 7-day rate-limit windows. Replaces the
/// simpler RateLimitGaugesCard with the reference-impl-plugin-style
/// "cycle-anchored curve + pace line" visualization.
///
/// For each window, the chart spans the full current cycle:
///   X axis: cycleStart (= resetsAt − duration) ... resetsAt
///   Y axis: 0 ... 100 (% of window cap consumed)
///
/// Two series are drawn:
///   - Pace line: dashed, secondary color, linear from (cycleStart, 0)
///     to (resetsAt, 100). "If you keep using at exactly the rate the
///     window allows, you land on 100% at reset."
///   - Actual usage curve: solid, colored by PaceBand, from cycleStart
///     through "now". The right portion of the chart (now..resetsAt) is
///     intentionally empty — that's the time you have left.
///
/// Hero text is `usedPct/pacePct` (e.g. "47% / 35%"), colored by the
/// 4-band PaceBand policy. Behind pace = green, on track = primary,
/// ahead = yellow, danger = red.
struct PaceChartCard: View {
    /// Limit the @Query to a generous window so it doesn't materialize
    /// every rate-limit row Pacer has ever written. Constant computed
    /// once per view init; works because RateLimitSamples roll forward
    /// and a view rebuilt later just gets a fresher cutoff.
    @Query private var samples: [RateLimitSample]

    init() {
        // 8 days covers the longest active window (7d) plus a small
        // grace period. Anything older isn't part of the current cycle
        // for either window.
        let cutoff = Date().addingTimeInterval(-8 * 86400)
        _samples = Query(
            filter: #Predicate<RateLimitSample> { $0.sampledAt >= cutoff },
            sort: \.sampledAt,
            order: .reverse
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rate-limit pace")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let latest = samples.first {
                    Text("via \(latest.source) · \(ageText(for: latest.sampledAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if samples.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 20) {
                    PaceChartColumn(
                        title: "5-hour",
                        window: "five_hour",
                        duration: 5 * 3600,
                        samples: samples
                    )
                    PaceChartColumn(
                        title: "7-day",
                        window: "seven_day",
                        duration: 7 * 86400,
                        samples: samples
                    )
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

    private func ageText(for date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// One window's column inside `PaceChartCard`. Pulled out as its own
/// struct mostly so the heavy `body` reads cleanly — and so the same
/// primitive can be reused later in MenuBarExtra detail or a
/// stand-alone widget.
private struct PaceChartColumn: View {
    let title: String
    let window: String
    let duration: TimeInterval
    let samples: [RateLimitSample]

    private var windowSamples: [RateLimitSample] {
        samples.filter { $0.window == window }
    }

    private var latest: RateLimitSample? { windowSamples.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            heroLine
            chartArea
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer()
            if let resets = latest?.resetsAt {
                Text("resets \(relative(resets))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("resets unknown")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var heroLine: some View {
        if let latest, let resets = latest.resetsAt {
            let paceFraction = PaceMath.paceFraction(
                now: Date(),
                resetsAt: resets,
                windowDuration: duration
            )
            let paceEndPct = paceFraction * 100
            let band = PaceBand(usedPct: latest.usedPercentage, paceEndPct: paceEndPct)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(latest.usedPercentage.rounded()))%")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color(for: band))
                Text("/")
                    .font(.system(size: 18, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text("\(Int(paceEndPct.rounded()))%")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("--")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var chartArea: some View {
        if let latest, let resets = latest.resetsAt {
            let cycleStart = resets.addingTimeInterval(-duration)
            let now = Date()
            let inCycle = windowSamples
                .filter { $0.sampledAt >= cycleStart && $0.sampledAt <= now }
                .sorted { $0.sampledAt < $1.sampledAt }
            let paceFraction = PaceMath.paceFraction(
                now: now, resetsAt: resets, windowDuration: duration
            )
            let band = PaceBand(usedPct: latest.usedPercentage, paceEndPct: paceFraction * 100)
            let curveColor = color(for: band)
            // Append a synthesized "now" point so the curve always ends
            // at the current %, even when the most recent sample is a
            // few minutes stale.
            let curvePoints: [PacePoint] =
                inCycle.map { PacePoint(time: $0.sampledAt, value: $0.usedPercentage) }
                + [PacePoint(time: now, value: latest.usedPercentage)]

            Chart {
                // Dashed pace line: cycleStart..resetsAt linear 0..100.
                LineMark(
                    x: .value("time", cycleStart),
                    y: .value("pct", 0.0),
                    series: .value("series", "pace")
                )
                LineMark(
                    x: .value("time", resets),
                    y: .value("pct", 100.0),
                    series: .value("series", "pace")
                )
                .foregroundStyle(.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // Solid usage curve up to now.
                ForEach(curvePoints) { p in
                    LineMark(
                        x: .value("time", p.time),
                        y: .value("pct", p.value),
                        series: .value("series", "used")
                    )
                    .foregroundStyle(curveColor)
                    .interpolationMethod(.monotone)
                }

                // "now" point so the curve doesn't dangle.
                PointMark(
                    x: .value("time", now),
                    y: .value("pct", latest.usedPercentage)
                )
                .foregroundStyle(curveColor)
                .symbolSize(40)
            }
            .chartXScale(domain: cycleStart...resets)
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text("\(v)%").font(.system(size: 8, design: .monospaced))
                        }
                    }
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                }
            }
            .frame(height: 80)
        } else {
            Text("collecting…")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(height: 80)
        }
    }

    private func color(for band: PaceBand) -> Color {
        switch band {
        case .green:  return .green
        case .white:  return .primary
        case .yellow: return .yellow
        case .red:    return .red
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Identifiable wrapper for ForEach over Charts marks. The PersistentModelID
/// of a `RateLimitSample` would work but the synthesized "now" point has
/// none — easier to use our own type for both.
private struct PacePoint: Identifiable {
    let time: Date
    let value: Double
    var id: TimeInterval { time.timeIntervalSince1970 }
}
