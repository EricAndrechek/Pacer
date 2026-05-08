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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Waiting for the first rate-limit reading")
                    .font(.system(size: 13, weight: .medium))
                Text("Pacer checks Anthropic every 5 minutes. If you're signed into Claude Code, the 5-hour and 7-day pace will appear here shortly.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .frame(minHeight: 96, alignment: .topLeading)
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
                Text(resetLabel(resets: resets))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("resets unknown")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Reset-line copy: relative duration plus the actual wall-clock
    /// time so the user can plan ("resets in 2h • 9 PM"). 7-day uses
    /// weekday-with-time so "Mon 3 PM" reads cleanly.
    private func resetLabel(resets: Date) -> String {
        let rel = pacerRelative(resets, style: .short)
        if duration <= 6 * 3600 {
            return "resets \(rel) · \(pacerClockTime(resets))"
        }
        return "resets \(rel) · \(pacerWeekdayClock(resets))"
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
            // Build curve points + per-segment band color. Each segment
            // (i → i+1) is colored by the band at its EARLIER endpoint
            // — so a curve that started under-pace and ramped over-pace
            // is multicolored along its length, mirroring the
            // reference-impl reference's intent (see PaceBand init policy).
            // Synthesize a "now" tail point so the line tracks to the
            // current time even when the latest sample is older.
            let rawPoints: [PacePoint] =
                inCycle.map { PacePoint(time: $0.sampledAt, value: $0.usedPercentage) }
                + [PacePoint(time: now, value: latest.usedPercentage)]
            let segments: [PaceSegment] = Self.segments(
                from: rawPoints,
                resetsAt: resets,
                windowDuration: duration
            )

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

                // Per-segment LineMarks. Each segment is its own series
                // so adjacent segments with different colors don't bleed
                // their colors together via Chart's auto-blending.
                ForEach(segments) { seg in
                    LineMark(
                        x: .value("time", seg.start.time),
                        y: .value("pct", seg.start.value),
                        series: .value("series", "seg-\(seg.id)")
                    )
                    .foregroundStyle(color(for: seg.band))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    LineMark(
                        x: .value("time", seg.end.time),
                        y: .value("pct", seg.end.value),
                        series: .value("series", "seg-\(seg.id)")
                    )
                    .foregroundStyle(color(for: seg.band))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }

                if let tail = rawPoints.last {
                    PointMark(
                        x: .value("time", tail.time),
                        y: .value("pct", tail.value)
                    )
                    .foregroundStyle(color(for: segments.last?.band ?? .white))
                    .symbolSize(44)
                }
            }
            .chartXScale(domain: cycleStart...resets)
            .chartYScale(domain: 0...100)
            .chartXAxis {
                xAxisMarks(cycleStart: cycleStart, resets: resets)
            }
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
            .frame(height: 96)
        } else {
            Text("collecting…")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(height: 96)
        }
    }

    /// X-axis marks tuned per window.
    ///
    /// **5h cycle** → tick at every wall-clock hour boundary that
    /// falls inside the cycle. A 5h window starting 4:30 PM gets ticks
    /// at 5p, 6p, 7p, 8p, 9p — evenly spaced and aligned to the hour
    /// the user actually thinks in.
    ///
    /// **7d cycle** → tick at every local-midnight inside the cycle
    /// plus one explicit tick at the reset itself so the right edge
    /// gets a label. Without that explicit reset tick the last day
    /// landed in a region SwiftUI Charts truncates to "...".
    ///
    /// Labels go through the shared `pacerHour` helper so 12h vs 24h
    /// follows the user's macOS clock setting.
    private func xAxisMarks(cycleStart: Date, resets: Date) -> AxisMarks<some AxisMark> {
        let cal = Calendar.current
        if duration <= 6 * 3600 {
            // Hour boundaries inside the cycle.
            var ticks: [Date] = []
            if let firstHour = cal.nextDate(
                after: cycleStart,
                matching: DateComponents(minute: 0, second: 0),
                matchingPolicy: .nextTime
            ) {
                var t = firstHour
                while t < resets {
                    ticks.append(t)
                    guard let next = cal.date(byAdding: .hour, value: 1, to: t) else { break }
                    t = next
                }
            }
            return AxisMarks(values: ticks) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(pacerHour(d, style: .compact))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                AxisGridLine().foregroundStyle(.secondary.opacity(0.10))
            }
        }
        // 7d → midnight ticks plus the reset itself.
        var ticks: [Date] = []
        if let firstMidnight = cal.nextDate(
            after: cycleStart,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) {
            var t = firstMidnight
            while t < resets {
                ticks.append(t)
                guard let next = cal.date(byAdding: .day, value: 1, to: t) else { break }
                t = next
            }
        }
        return AxisMarks(values: ticks) { value in
            // `centered: true` puts each weekday label in the middle
            // of its day's column rather than on the boundary line —
            // fixes the last day rendering as "..." when the rightmost
            // midnight sat too close to the chart edge.
            AxisValueLabel(centered: true) {
                if let d = value.as(Date.self) {
                    Text(Self.weekday(d))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            AxisGridLine().foregroundStyle(.secondary.opacity(0.10))
        }
    }

    private static func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    /// Build per-segment band classification for the pace curve. For
    /// each adjacent pair of points we compute the pace fraction at the
    /// segment's earlier endpoint and the PaceBand at that moment so
    /// segments authored when the user was behind pace render green
    /// even if "now" is in the red.
    private static func segments(
        from points: [PacePoint],
        resetsAt: Date,
        windowDuration: TimeInterval
    ) -> [PaceSegment] {
        guard points.count >= 2 else { return [] }
        var out: [PaceSegment] = []
        out.reserveCapacity(points.count - 1)
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let pace = PaceMath.paceFraction(
                now: a.time, resetsAt: resetsAt, windowDuration: windowDuration
            ) * 100
            let band = PaceBand(usedPct: a.value, paceEndPct: pace)
            out.append(PaceSegment(id: i, start: a, end: b, band: band))
        }
        return out
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

private struct PaceSegment: Identifiable {
    let id: Int
    let start: PacePoint
    let end: PacePoint
    let band: PaceBand
}
