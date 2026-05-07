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
    /// 8-day window of rate-limit samples. We never read this from
    /// `body` — the columns get pre-split sample arrays out of the
    /// cache. Body would otherwise filter+sort the full window twice
    /// (once per column) on every SwiftData save.
    @Query private var samples: [RateLimitSample]
    @Query(PaceChartCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cached = Cached()

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

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    /// Pre-bucketed by window. The header reads `latest`; each column
    /// reads `fiveHour`/`sevenDay`. No body-time filter/sort.
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
        // Samples come in reverse-chronological from the @Query; the
        // PaceChartColumn body assumes `windowSamples.first` is the
        // newest. Append-in-iteration preserves that order.
        cached = Cached(fiveHour: fh, sevenDay: sd, latest: newest)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rate-limit pace")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let latest = cached.latest {
                    Text("via \(latest.source) · \(ageText(for: latest.sampledAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if cached.latest == nil {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 20) {
                    PaceChartColumn(
                        title: "5-hour",
                        duration: 5 * 3600,
                        windowSamples: cached.fiveHour
                    )
                    PaceChartColumn(
                        title: "7-day",
                        duration: 7 * 86400,
                        windowSamples: cached.sevenDay
                    )
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Polling /api/oauth/usage on a 5-minute cadence.")
                .font(.system(.body))
            Text("If you're signed into Claude Code, values will appear within 5 minutes of Pacer starting.")
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
    let duration: TimeInterval
    /// Already filtered to this column's window and pre-sorted
    /// reverse-chronological by the parent. Avoids per-body filter/sort
    /// passes over the full 8-day sample set.
    let windowSamples: [RateLimitSample]

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
