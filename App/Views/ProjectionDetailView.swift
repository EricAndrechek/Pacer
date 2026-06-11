import SwiftUI
import Charts
import PacerCore
import PacerUI

/// "Compare models" detail sheet for one rate-limit window: the actual usage
/// curve with **every** candidate forecaster's projection overlaid and
/// labelled, plus each model's backtest accuracy. Opened from the little
/// button under each 5h/7d pace chart, for when you want to see the whole
/// tournament rather than just the winner the dashboard draws.
struct ProjectionDetailView: View {
    let title: String
    let cycleStart: Date
    let resetsAt: Date
    let durationSeconds: TimeInterval
    let actual: [PaceChartView.Data.Point]
    let trajectories: [BurnTrajectory.ScoredTrajectory]

    @Environment(\.dismiss) private var dismiss

    /// Stable per-model colors for the lines and the legend swatches.
    private static let palette: [String: Color] = [
        "linear-recent": .blue,
        "recency-weighted": .green,
        "damped-acceleration": .purple,
        "saturating": .orange,
    ]
    private func color(_ id: String) -> Color { Self.palette[id] ?? .gray }

    /// Models sorted best-accuracy first (selected, then lowest error).
    private var ranked: [BurnTrajectory.ScoredTrajectory] {
        trajectories.sorted {
            if $0.isSelected != $1.isSelected { return $0.isSelected }
            return $0.medianAbsError < $1.medianAbsError
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            chart.frame(height: 240)
            accuracyTable
            Text("Projections are fit on this cycle so far. “Fit error” is each model’s median absolute error (percentage points) over the remainder of your past cycles — lower is better; the selected model is what the dashboard draws.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 620)
    }

    private var chart: some View {
        Chart {
            paceMarks
            actualMarks
            trajectoryMarks
        }
        .chartXScale(domain: cycleStart...resetsAt)
        .chartYScale(domain: 0...105)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { AxisGridLine(); AxisValueLabel() } }
    }

    @ChartContentBuilder private var paceMarks: some ChartContent {
        LineMark(x: .value("t", cycleStart), y: .value("pct", 0.0), series: .value("s", "pace"))
        LineMark(x: .value("t", resetsAt), y: .value("pct", 100.0), series: .value("s", "pace"))
            .foregroundStyle(.secondary.opacity(0.35))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        RuleMark(y: .value("full", 100))
            .foregroundStyle(.secondary.opacity(0.25))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
    }

    @ChartContentBuilder private var actualMarks: some ChartContent {
        ForEach(actual) { p in
            LineMark(x: .value("t", p.time), y: .value("pct", p.value), series: .value("s", "actual"))
                .foregroundStyle(.primary)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .interpolationMethod(.monotone)
        }
    }

    /// Pre-resolved styling so the chart builder stays trivial (the inline
    /// ternaries overwhelmed the type-checker).
    private struct StyledLine: Identifiable {
        let id: String
        let points: [BurnTrajectory.Sample]
        let color: Color
        let width: CGFloat
        let dash: [CGFloat]
    }
    private var styledLines: [StyledLine] {
        trajectories.map { st in
            StyledLine(
                id: st.modelId,
                points: st.trajectory.points,
                color: color(st.modelId).opacity(st.isSelected ? 0.95 : 0.5),
                width: st.isSelected ? 2.4 : 1.4,
                dash: st.isSelected ? [6, 3] : [4, 4])
        }
    }

    @ChartContentBuilder private var trajectoryMarks: some ChartContent {
        ForEach(styledLines) { line in
            ForEach(line.points, id: \.at) { p in
                LineMark(x: .value("t", p.at), y: .value("pct", p.usedPercentage),
                         series: .value("s", "m-\(line.id)"))
                    .foregroundStyle(line.color)
                    .lineStyle(StrokeStyle(lineWidth: line.width, dash: line.dash))
                    .interpolationMethod(.monotone)
            }
        }
    }

    private var accuracyTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ranked) { st in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(st.modelId))
                        .frame(width: 14, height: 4)
                    Text(BurnTrajectory.displayName(st.modelId))
                        .font(.system(size: 13, weight: st.isSelected ? .semibold : .regular))
                    if st.isSelected {
                        Text("selected").font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(color(st.modelId).opacity(0.18)))
                            .foregroundStyle(color(st.modelId))
                    }
                    Spacer()
                    if let crossAt = st.trajectory.crossesFullAt {
                        Text("hits 100% \(pacerRelative(crossAt, style: .short))")
                            .font(.system(size: 11)).foregroundStyle(.red.opacity(0.8))
                    }
                    Text(st.medianAbsError.isFinite ? String(format: "fit ±%.1f pp", st.medianAbsError) : "no history yet")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
