import SwiftUI
import SwiftData
import Charts
import PacerCore

/// Pace charts for the 5-hour and 7-day rate-limit windows. Cycle-
/// anchored visualization: dashed pace line from cycleStart→resetsAt
/// (linear 0→100%) and the actual usage curve drawn solid up to "now."
///
/// Hero text inside each column repeats `usedPct/pacePct` for the user
/// who came in cold and didn't see the hero strip — and gives the chart
/// a label even when the bars are tiny.
struct PaceChartCard: View {
    /// 8-day window of rate-limit samples. Body never reads the array
    /// — pre-bucketed by window in `cached` so neither column does its
    /// own filter pass.
    @Query private var samples: [RateLimitSample]
    @Query(PaceChartCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cached = Cached()

    init() {
        let cutoff = Date().addingTimeInterval(-8 * 86400)
        _samples = Query(
            filter: #Predicate<RateLimitSample> { $0.sampledAt >= cutoff },
            sort: \.sampledAt,
            order: .reverse
        )
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private struct Cached {
        var fiveHour: [RateLimitSample] = []
        var sevenDay: [RateLimitSample] = []
        var latest: RateLimitSample?
    }

    private func refreshCache() {
        var fh: [RateLimitSample] = []
        var sd: [RateLimitSample] = []
        var newest: RateLimitSample?
        for s in samples {
            if s.window == "five_hour" { fh.append(s) }
            else if s.window == "seven_day" { sd.append(s) }
            if newest == nil || s.sampledAt > newest!.sampledAt { newest = s }
        }
        cached = Cached(fiveHour: fh, sevenDay: sd, latest: newest)
    }

    var body: some View {
        PacerCard("Rate-limit pace", trailing: { trailingChip }) {
            if cached.latest == nil {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 24) {
                    PaceChartColumn(
                        title: "5-hour",
                        duration: 5 * 3600,
                        windowSamples: cached.fiveHour
                    )
                    Divider()
                        .frame(height: 110)
                    PaceChartColumn(
                        title: "7-day",
                        duration: 7 * 86400,
                        windowSamples: cached.sevenDay
                    )
                }
            }
        }
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    @ViewBuilder
    private var trailingChip: some View {
        if let latest = cached.latest {
            Text("via \(latest.source) · \(pacerRelative(latest.sampledAt))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Polling /api/oauth/usage on a 5-minute cadence.")
                .font(.system(size: 12))
            Text("If you're signed into Claude Code, values will appear within 5 minutes of Pacer starting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One window's column inside `PaceChartCard`. Pulled out so the body
/// reads cleanly and the same primitive can be reused later in widgets
/// or a stand-alone window.
private struct PaceChartColumn: View {
    let title: String
    let duration: TimeInterval
    /// Already filtered to this column's window and pre-sorted reverse-
    /// chronological by the parent. Avoids per-body filter/sort passes
    /// over the full 8-day sample set.
    let windowSamples: [RateLimitSample]

    private var latest: RateLimitSample? { windowSamples.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            heroLine
            chartArea
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Eyebrow(text: title)
            Spacer()
            if let resets = latest?.resetsAt {
                Text("resets \(pacerRelative(resets, style: .short))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("resets unknown")
                    .font(.system(size: 10))
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
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
                Text("\(Int(paceEndPct.rounded()))%")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
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
            let curvePoints: [PacePoint] =
                inCycle.map { PacePoint(time: $0.sampledAt, value: $0.usedPercentage) }
                + [PacePoint(time: now, value: latest.usedPercentage)]

            Chart {
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

                ForEach(curvePoints) { p in
                    LineMark(
                        x: .value("time", p.time),
                        y: .value("pct", p.value),
                        series: .value("series", "used")
                    )
                    .foregroundStyle(curveColor)
                    .interpolationMethod(.monotone)
                }
                AreaMark(
                    x: .value("time", curvePoints.last?.time ?? now),
                    yStart: .value("pct", 0.0),
                    yEnd: .value("pct", curvePoints.last?.value ?? 0)
                )
                .opacity(0)

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
                            Text("\(v)%")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                }
            }
            .frame(height: 90)
        } else {
            Text("collecting…")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(height: 90)
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
}

private struct PacePoint: Identifiable {
    let time: Date
    let value: Double
    var id: TimeInterval { time.timeIntervalSince1970 }
}
