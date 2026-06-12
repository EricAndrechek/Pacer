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
        "diurnal-rate": .teal,
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
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            chart.frame(height: 240)
            accuracyTable
            Text("Solid — actual · dashed — each model's projection · the highlighted model drives the dashboard.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 620)
    }

    /// "62% used · resets Mon 6 AM" — the cycle context the chart is read in.
    private var subtitle: String {
        let used = actual.last.map { "\(Int($0.value.rounded()))% used" } ?? ""
        let resets = "resets \(resetsAt.formatted(.dateTime.weekday(.abbreviated).hour()))"
        return [used, resets].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Zoomed y-domain: a 6%-used cycle shouldn't be a flat line squashed at
    /// the bottom of a fixed 0–105 frame. Spans the data (actuals + every
    /// trajectory) with headroom; the cap line + pace reference only render
    /// when they're in view.
    private var yMax: Double {
        let dataMax = max(
            actual.map(\.value).max() ?? 0,
            trajectories.flatMap { $0.trajectory.points.map(\.usedPercentage) }.max() ?? 0
        )
        return min(105, max(25, dataMax * 1.3))
    }

    private var chart: some View {
        Chart {
            paceMarks
            actualMarks
            trajectoryMarks
        }
        .chartXScale(domain: cycleStart...resetsAt)
        .chartYScale(domain: 0...yMax)
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisGridLine(); AxisValueLabel() } }
    }

    /// The 0→100 ideal-burn reference. Both marks carry the style — a
    /// modifier after the second LineMark styles only that mark, and the
    /// first then renders in the chart's default (blue, solid) series color.
    @ChartContentBuilder private var paceMarks: some ChartContent {
        ForEach([(cycleStart, 0.0), (resetsAt, min(100, yMax))], id: \.0) { t, v in
            LineMark(x: .value("t", t), y: .value("pct", v), series: .value("s", "pace"))
                .foregroundStyle(.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        if yMax >= 100 {
            RuleMark(y: .value("full", 100))
                .foregroundStyle(.secondary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }
    }

    /// Actuals colored by pace band per run — the same green/yellow/red
    /// grammar the dashboard chart uses, instead of one undifferentiated line.
    @ChartContentBuilder private var actualMarks: some ChartContent {
        ForEach(actualRuns) { run in
            ForEach(run.points) { p in
                LineMark(x: .value("t", p.time), y: .value("pct", p.value),
                         series: .value("s", "actual-\(run.id)"))
                    .foregroundStyle(run.color)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        if let tail = actual.last {
            PointMark(x: .value("t", tail.time), y: .value("pct", tail.value))
                .foregroundStyle(bandColor(at: tail))
                .symbolSize(60)
        }
    }

    /// Contiguous same-band runs of the actual line (mirrors PaceChartView).
    private struct BandRun: Identifiable {
        let id: Int
        let points: [PaceChartView.Data.Point]
        let color: Color
    }
    private var actualRuns: [BandRun] {
        var runs: [BandRun] = []
        var i = 0
        while i < actual.count {
            let color = bandColor(at: actual[i])
            var j = i + 1
            while j < actual.count, bandColor(at: actual[j]) == color { j += 1 }
            // Overlap one point so adjacent runs connect without gaps.
            let upper = min(j + 1, actual.count)
            runs.append(BandRun(id: runs.count, points: Array(actual[i..<upper]), color: color))
            i = j
        }
        return runs
    }

    private func bandColor(at p: PaceChartView.Data.Point) -> Color {
        let pace = PaceMath.paceFraction(
            now: p.time, resetsAt: resetsAt, windowDuration: durationSeconds) * 100
        return PaceBand(usedPct: p.value, paceEndPct: pace).color
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
                color: color(st.modelId).opacity(st.isSelected ? 1.0 : 0.75),
                width: st.isSelected ? 2.6 : 1.8,
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
        VStack(alignment: .leading, spacing: 0) {
            // Column headers make the right-hand number self-explanatory —
            // it's how far each model's final-value calls have missed on
            // this user's completed cycles.
            HStack {
                Text("MODEL")
                Spacer()
                Text("TYPICAL MISS, PAST CYCLES")
                    .help("Median |projected final − actual final| across your completed cycles, in percentage points — lower is better")
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            ForEach(Array(ranked.enumerated()), id: \.element.id) { idx, st in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(st.modelId))
                        .frame(width: 14, height: 4)
                    Text(BurnTrajectory.displayName(st.modelId))
                        .font(.system(size: 13, weight: st.isSelected ? .semibold : .regular))
                    if st.isSelected {
                        Text("on the dashboard").font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(color(st.modelId).opacity(0.18)))
                            .foregroundStyle(color(st.modelId))
                    }
                    Spacer()
                    if let crossAt = st.trajectory.crossesFullAt {
                        Text("caps \(pacerRelative(crossAt, style: .short))")
                            .font(.system(size: 11)).foregroundStyle(.red.opacity(0.85))
                    }
                    Text(st.medianAbsError.isFinite
                         ? String(format: "±%.0f pts", st.medianAbsError)
                         : "—")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(
                    st.isSelected
                        ? RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(color(st.modelId).opacity(0.07))
                        : nil
                )
                if idx != ranked.indices.last {
                    Divider().opacity(0.25).padding(.leading, 34)
                }
            }
        }
    }
}
