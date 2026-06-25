import SwiftUI
import Charts
import PacerCore

/// The pace chart, rendered identically across the dashboard, the menu
/// bar (eventually), and the widgets. Takes pre-resolved data — sample
/// points already filtered to the current cycle, sorted ascending —
/// so the consumer's data layer is irrelevant: the dashboard ships
/// it from a `@Query`, the widget extension from a `TimelineProvider`.
///
/// Visual recipe (matches the original `App/Views/PaceChartCard.swift`):
///   - Dashed `secondary` pace line: `(cycleStart, 0%) → (resetsAt, 100%)`.
///   - Multi-segment actual-usage line: each `i → i+1` is its own
///     `series` so SwiftUI Charts doesn't auto-blend colors between
///     adjacent segments. Each segment is colored by the `PaceBand`
///     classification at the segment's *earlier* endpoint, so a curve
///     that started under-pace and ramped over-pace renders multi-
///     colored along its length.
///   - Tail point at the most-recent sample, colored by the latest
///     segment's band.
///
/// `Style.detailed` adds locale-aware x-axis ticks and a left y-axis
/// (0/50/100%); `Style.compact` hides both for tight widget canvases.
public struct PaceChartView: View {

    public struct Data: Equatable {
        public let cycleStart: Date
        public let resetsAt: Date
        public let durationSeconds: TimeInterval
        public let points: [Point]
        public let usedPct: Double
        /// Optional forecast: the projected usage trajectory from "now" to the
        /// reset, drawn as a faint dashed line so you can see where the curve
        /// is heading vs. where it's been. `nil` (the default) draws nothing —
        /// so widgets and the share card are unaffected unless they opt in.
        public let projection: [Point]?
        /// First instant the projection reaches 100% within the window, if
        /// any — marked on the chart as the forecast limit-hit.
        public let projectionCrossesFullAt: Date?

        public struct Point: Equatable, Identifiable, Sendable {
            public let time: Date
            public let value: Double
            public var id: TimeInterval { time.timeIntervalSince1970 }

            public init(time: Date, value: Double) {
                self.time = time
                self.value = value
            }
        }

        public init(
            cycleStart: Date,
            resetsAt: Date,
            durationSeconds: TimeInterval,
            points: [Point],
            usedPct: Double,
            projection: [Point]? = nil,
            projectionCrossesFullAt: Date? = nil
        ) {
            self.cycleStart = cycleStart
            self.resetsAt = resetsAt
            self.durationSeconds = durationSeconds
            self.points = points
            self.usedPct = usedPct
            self.projection = projection
            self.projectionCrossesFullAt = projectionCrossesFullAt
        }
    }

    public enum Style {
        /// Dashboard / large-widget treatment: axis ticks, full label
        /// typography, line weight 2pt.
        case detailed
        /// Compact widget treatment: no axis labels, line weight 1.6pt,
        /// smaller tail dot. Saves vertical pixels for small/medium
        /// widget canvases where ticks would crowd the chart.
        case compact
    }

    public let data: Data
    public let style: Style

    public init(data: Data, style: Style = .detailed) {
        self.data = data
        self.style = style
    }

    /// Max points plotted after downsampling. The 7-day window collects a
    /// sample every 5 min (~2,000 per cycle); plotting all of them is both
    /// visually jagged when blown up and a lot of Charts marks on a view
    /// that re-renders every poll. Utilization is monotonic within a
    /// cycle, so time-bucketing to this many points and keeping the real
    /// sample values preserves the shape — it drops redundant samples, it
    /// doesn't synthesize any. The 5-hour window (~60 points) is already
    /// under this and passes through untouched.
    private static let pointTarget = 220

    /// `data.points` reduced to at most `pointTarget`, endpoints preserved.
    /// Time-bucketed; the last sample in each bucket wins, which for
    /// monotonic data is also the bucket's max — so the climb is never
    /// understated.
    private var plotPoints: [Data.Point] {
        let target = Self.pointTarget
        let pts = data.points
        guard pts.count > target,
              let first = pts.first, let last = pts.last else { return pts }
        let start = first.time.timeIntervalSince1970
        let span = last.time.timeIntervalSince1970 - start
        guard span > 0 else { return pts }
        var repByBucket: [Int: Data.Point] = [:]
        for p in pts {
            let frac = (p.time.timeIntervalSince1970 - start) / span
            let bucket = min(target - 1, max(0, Int(frac * Double(target))))
            repByBucket[bucket] = p
        }
        var out = repByBucket.keys.sorted().map { repByBucket[$0]! }
        if out.first?.id != first.id { out.insert(first, at: 0) }
        if out.last?.id != last.id { out.append(last) }
        return out
    }

    /// `pts` grouped into maximal runs of constant `PaceBand`, each run
    /// sharing its boundary point with the next so the line stays
    /// continuous across a color change. Each run renders as ONE
    /// multi-point series (a handful total, vs. one 2-point series per
    /// sample before): collapses the mark count, and lets the line carry a
    /// smooth `.monotone` interpolation within the run. Band is keyed off
    /// each segment's earlier endpoint, matching the prior per-segment
    /// coloring exactly.
    private func bandRuns(from pts: [Data.Point]) -> [BandRun] {
        guard pts.count >= 2 else { return [] }
        var runs: [BandRun] = []
        var i = 0
        while i < pts.count - 1 {
            let here = band(at: pts[i])
            var j = i
            while j < pts.count - 1 && band(at: pts[j]) == here { j += 1 }
            runs.append(BandRun(id: runs.count, band: here, points: Array(pts[i...j])))
            i = j
        }
        return runs
    }

    /// Pace band for a single point — its used% vs. the linear pace target
    /// at that point's time. Shared by the run grouping and the tail dot.
    private func band(at p: Data.Point) -> PaceBand {
        let pace = PaceMath.paceFraction(
            now: p.time, resetsAt: data.resetsAt, windowDuration: data.durationSeconds
        ) * 100
        return PaceBand(usedPct: p.value, paceEndPct: pace)
    }

    public var body: some View {
        let pts = plotPoints
        let runs = bandRuns(from: pts)
        let tail = pts.last
        // Colour the tail dot by the CURRENT point's band so it matches
        // the dashboard hero %, rather than the band the last run began in.
        let tailBand = tail.map { band(at: $0) } ?? .white

        Chart {
            // Dashed pace target.
            LineMark(
                x: .value("time", data.cycleStart),
                y: .value("pct", 0.0),
                series: .value("series", "pace")
            )
            LineMark(
                x: .value("time", data.resetsAt),
                y: .value("pct", 100.0),
                series: .value("series", "pace")
            )
            .foregroundStyle(.secondary.opacity(0.4))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Actual-usage line: one multi-point series per band run, so
            // adjacent colors don't blend and each run carries a smooth
            // monotone interpolation (which can't overshoot, so it never
            // implies a dip or peak the samples don't have).
            ForEach(runs) { run in
                ForEach(run.points) { pt in
                    LineMark(
                        x: .value("time", pt.time),
                        y: .value("pct", pt.value),
                        series: .value("series", "run-\(run.id)")
                    )
                    .foregroundStyle(run.band.color)
                    .lineStyle(StrokeStyle(lineWidth: style.lineWidth, lineCap: .round))
                    .interpolationMethod(.monotone)
                }
            }

            // Forecast trajectory: a faint dashed continuation from "now" to
            // the reset. Drawn under the tail dot, distinct from the gray
            // pace line, so it reads as "where this is heading" without
            // pretending to be observed data. Red-tinted when it's projected
            // to hit the cap before the window resets.
            if let projection = data.projection, projection.count >= 2 {
                let crosses = data.projectionCrossesFullAt != nil
                ForEach(projection) { pt in
                    LineMark(
                        x: .value("time", pt.time),
                        y: .value("pct", pt.value),
                        series: .value("series", "projection")
                    )
                    .foregroundStyle((crosses ? Color.red : Color.primary).opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: style.lineWidth * 0.85, dash: [5, 4]))
                    .interpolationMethod(.monotone)
                }
                if let crossAt = data.projectionCrossesFullAt {
                    PointMark(x: .value("time", crossAt), y: .value("pct", 100.0))
                        .foregroundStyle(Color.red.opacity(0.6))
                        .symbolSize(style.tailSymbolSize * 0.7)
                        .symbol(.circle)
                }
            }

            if let tail {
                PointMark(
                    x: .value("time", tail.time),
                    y: .value("pct", tail.value)
                )
                .foregroundStyle(tailBand.color)
                .symbolSize(style.tailSymbolSize)
            }
        }
        .chartXScale(domain: data.cycleStart...data.resetsAt)
        .chartYScale(domain: 0...100)
        .modifier(AxisModifier(
            style: style,
            durationSeconds: data.durationSeconds,
            cycleStart: data.cycleStart,
            resetsAt: data.resetsAt
        ))
    }

    private struct BandRun: Identifiable {
        let id: Int
        let band: PaceBand
        let points: [Data.Point]
    }
}

private extension PaceChartView.Style {
    var lineWidth: CGFloat {
        switch self {
        case .detailed: return 2
        case .compact:  return 1.6
        }
    }
    var tailSymbolSize: CGFloat {
        switch self {
        case .detailed: return 44
        case .compact:  return 22
        }
    }
}

/// Conditional axis-styling. Lives in a ViewModifier so we can use
/// `if/else` in the modifier's `body(content:)` (a SwiftUI
/// ViewBuilder); `@AxisContentBuilder` doesn't allow control flow,
/// so we couldn't just inline `if style == .compact { ... } else { ... }`
/// inside `.chartXAxis { ... }`.
private struct AxisModifier: ViewModifier {
    let style: PaceChartView.Style
    let durationSeconds: TimeInterval
    let cycleStart: Date
    let resetsAt: Date

    func body(content: Content) -> some View {
        if style == .compact {
            content
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
        } else {
            content
                .chartXAxis { xAxisMarks }
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
        }
    }

    /// X-axis ticks tuned per window. 5h cycles get hourly ticks
    /// inside the cycle; 7d cycles get a tick at every local midnight
    /// inside the cycle, centered under each weekday's column. Same
    /// logic the dashboard had before the refactor.
    @AxisContentBuilder
    private var xAxisMarks: some AxisContent {
        let isShortCycle = durationSeconds <= 6 * 3600
        AxisMarks(values: ticks) { value in
            AxisValueLabel(centered: !isShortCycle) {
                if let d = value.as(Date.self) {
                    Text(isShortCycle
                        ? pacerHour(d, style: .compact)
                        : pacerWeekdayShort(d))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            AxisGridLine().foregroundStyle(.secondary.opacity(0.10))
        }
    }

    /// Computed outside the AxisContentBuilder so we're free to use
    /// for-loops + early returns + var locals.
    private var ticks: [Date] {
        let cal = Calendar.current
        var out: [Date] = []
        if durationSeconds <= 6 * 3600 {
            // Hourly ticks inside the cycle.
            guard let first = cal.nextDate(
                after: cycleStart,
                matching: DateComponents(minute: 0, second: 0),
                matchingPolicy: .nextTime
            ) else { return [] }
            var t = first
            while t < resetsAt {
                out.append(t)
                guard let next = cal.date(byAdding: .hour, value: 1, to: t) else { break }
                t = next
            }
        } else {
            // Midnight ticks inside the cycle.
            guard let first = cal.nextDate(
                after: cycleStart,
                matching: DateComponents(hour: 0, minute: 0, second: 0),
                matchingPolicy: .nextTime
            ) else { return [] }
            var t = first
            while t < resetsAt {
                out.append(t)
                guard let next = cal.date(byAdding: .day, value: 1, to: t) else { break }
                t = next
            }
        }
        return out
    }
}
