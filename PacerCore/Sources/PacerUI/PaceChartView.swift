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

        public struct Point: Equatable, Identifiable {
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
            usedPct: Double
        ) {
            self.cycleStart = cycleStart
            self.resetsAt = resetsAt
            self.durationSeconds = durationSeconds
            self.points = points
            self.usedPct = usedPct
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

    private var segments: [Segment] {
        guard data.points.count >= 2 else { return [] }
        var out: [Segment] = []
        out.reserveCapacity(data.points.count - 1)
        for i in 0..<(data.points.count - 1) {
            let a = data.points[i]
            let b = data.points[i + 1]
            let pace = PaceMath.paceFraction(
                now: a.time,
                resetsAt: data.resetsAt,
                windowDuration: data.durationSeconds
            ) * 100
            let band = PaceBand(usedPct: a.value, paceEndPct: pace)
            out.append(Segment(id: i, start: a, end: b, band: band))
        }
        return out
    }

    public var body: some View {
        let segs = segments
        let tail = data.points.last
        let tailBand = segs.last?.band ?? .white

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

            // Per-segment actual-usage line. Each segment is its own
            // series so adjacent colors don't blend.
            ForEach(segs) { seg in
                LineMark(
                    x: .value("time", seg.start.time),
                    y: .value("pct", seg.start.value),
                    series: .value("series", "seg-\(seg.id)")
                )
                .foregroundStyle(seg.band.color)
                .lineStyle(StrokeStyle(lineWidth: style.lineWidth, lineCap: .round))
                LineMark(
                    x: .value("time", seg.end.time),
                    y: .value("pct", seg.end.value),
                    series: .value("series", "seg-\(seg.id)")
                )
                .foregroundStyle(seg.band.color)
                .lineStyle(StrokeStyle(lineWidth: style.lineWidth, lineCap: .round))
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

    private struct Segment: Identifiable {
        let id: Int
        let start: Data.Point
        let end: Data.Point
        let band: PaceBand
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
