import Charts
import SwiftUI
import PacerCore

/// Anthropic's readings against the live meter's estimate, for one window
/// (#318): the readings as a solid stepped line (they are whole points, and
/// hold until the next one), the estimate just before each reading dotted,
/// the way the pace chart draws its estimated stretch.
///
/// Plain values in: the comparison sheet builds them off the main actor
/// (`LiveMeterDrift.review`) and nothing about them is stored. The y axis
/// fits the data rather than 0–100: the two lines are usually within a
/// point of each other, and on a full-height axis they would be one line.
public struct LiveMeterComparisonChart: View {
    public let readings: [PaceChartView.Data.Point]
    public let estimates: [PaceChartView.Data.Point]
    public let start: Date
    public let end: Date

    public init(readings: [PaceChartView.Data.Point], estimates: [PaceChartView.Data.Point],
                start: Date, end: Date) {
        self.readings = readings
        self.estimates = estimates
        self.start = start
        self.end = end
    }

    private var yDomain: ClosedRange<Double> {
        let values = readings.map(\.value) + estimates.map(\.value)
        let lo = (values.min() ?? 0).rounded(.down) - 1
        let hi = (values.max() ?? 100).rounded(.up) + 1
        return max(0, lo)...min(100, max(hi, lo + 3))
    }

    public var body: some View {
        Chart {
            ForEach(readings) { p in
                LineMark(x: .value("time", p.time), y: .value("pct", p.value),
                         series: .value("series", "readings"))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .interpolationMethod(.stepEnd)
            }
            ForEach(estimates) { p in
                LineMark(x: .value("time", p.time), y: .value("pct", p.value),
                         series: .value("series", "estimate"))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [0.5, 3]))
            }
        }
        .chartXScale(domain: start...max(end, start.addingTimeInterval(60)))
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.system(size: 9))
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v.rounded()))%").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
            }
        }
    }
}
