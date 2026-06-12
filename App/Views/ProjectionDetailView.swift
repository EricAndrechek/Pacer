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

    // MARK: - Zoom domain

    /// The instant all trajectories branch from (their shared first point).
    private var trajectoryNow: Date? {
        trajectories.first?.trajectory.points.first?.at
    }

    /// Chart x-axis right edge: the latest `at` across all trajectories' last
    /// points, padded by 8 % of (that latest − trajectoryNow), clamped to ≤
    /// resetsAt. Falls back to resetsAt when trajectories are empty.
    private var xEnd: Date {
        guard let now = trajectoryNow,
              let rawEnd = trajectories.compactMap({ $0.trajectory.points.last?.at }).max()
        else { return resetsAt }
        let span = rawEnd.timeIntervalSince(now)
        let padded = rawEnd.addingTimeInterval(span * 0.08)
        return min(padded, resetsAt)
    }

    /// Chart x-axis left edge: "now" minus 25% of the visible window width
    /// (now → xEnd), clamped so we never show before cycleStart.
    private var zoomStart: Date {
        guard let now = trajectoryNow else { return cycleStart }
        let windowSpan = xEnd.timeIntervalSince(now)
        let lookback = windowSpan * 0.25
        return max(cycleStart, now.addingTimeInterval(-lookback))
    }

    // MARK: - Filtered actuals (for the zoomed x-domain)

    /// Actual points at or after zoomStart, with one leading bridging point
    /// (the last point before zoomStart) so the line enters from the left edge.
    private var filteredActuals: [PaceChartView.Data.Point] {
        let splitIdx = actual.firstIndex(where: { $0.time >= zoomStart }) ?? actual.endIndex
        var result: [PaceChartView.Data.Point] = []
        if splitIdx > 0 {
            result.append(actual[splitIdx - 1])   // bridging point
        }
        result.append(contentsOf: actual[splitIdx...])
        return result
    }

    // MARK: - Y domain

    /// Zoomed y-domain based on filtered actuals + all trajectories.
    private var yMax: Double {
        let actMax = filteredActuals.map(\.value).max() ?? 0
        let trajMax = trajectories.flatMap { $0.trajectory.points.map(\.usedPercentage) }.max() ?? 0
        let dataMax = max(actMax, trajMax)
        return min(105, max(25, dataMax * 1.3))
    }

    private var yMin: Double {
        let actMin = filteredActuals.map(\.value).min() ?? 0
        let trajMin = trajectories.flatMap { $0.trajectory.points.map(\.usedPercentage) }.min() ?? 0
        let minVisible = min(actMin, trajMin)
        guard minVisible > 30 else { return 0 }
        return (floor((minVisible - 10) / 10) * 10)
    }

    // MARK: - Envelope

    /// One shared time step for the min/max fan envelope.
    struct EnvelopeStep {
        let t: Date
        let lo: Double
        let hi: Double
    }

    /// ~24 linearly-spaced steps from trajectoryNow → xEnd. For each step,
    /// interpolate every trajectory's value (clamping at 100 once capped).
    /// Values past a trajectory's last point extend at that last value, so
    /// stepping to xEnd (which may be before resetsAt) is correct.
    private var envelopeSteps: [EnvelopeStep] {
        guard let now = trajectoryNow, !trajectories.isEmpty else { return [] }
        let span = xEnd.timeIntervalSince(now)
        guard span > 0 else { return [] }
        let steps = 24
        return (0...steps).compactMap { i in
            let frac = Double(i) / Double(steps)
            let t = now.addingTimeInterval(span * frac)
            var vals: [Double] = []
            for st in trajectories {
                vals.append(interpolatedValue(st.trajectory.points, at: t))
            }
            guard !vals.isEmpty else { return nil }
            return EnvelopeStep(t: t, lo: vals.min()!, hi: vals.max()!)
        }
    }

    /// Linear interpolation of a trajectory's usedPercentage at time t.
    /// Past the last point: treat as its last value (typically 100 at cap).
    private func interpolatedValue(_ points: [BurnTrajectory.Sample], at t: Date) -> Double {
        guard !points.isEmpty else { return 100 }
        if t <= points.first!.at { return points.first!.usedPercentage }
        if t >= points.last!.at  { return points.last!.usedPercentage }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            if t >= a.at && t <= b.at {
                let span = b.at.timeIntervalSince(a.at)
                guard span > 0 else { return a.usedPercentage }
                let frac = t.timeIntervalSince(a.at) / span
                return a.usedPercentage + frac * (b.usedPercentage - a.usedPercentage)
            }
        }
        return points.last!.usedPercentage
    }

    // MARK: - Ranked list (visual order = descending value at right edge)

    /// Models ordered by their value at the chart's right edge, descending
    /// (highest line on chart = first row). Capped trajectories whose last
    /// point is 100 are sorted earliest-cap-first among ties. The selected
    /// model keeps its highlight but does not jump the order.
    private var ranked: [BurnTrajectory.ScoredTrajectory] {
        trajectories.sorted { a, b in
            let aVal = a.trajectory.points.last?.usedPercentage ?? 0
            let bVal = b.trajectory.points.last?.usedPercentage ?? 0
            if aVal != bVal { return aVal > bVal }
            // tie-break: earlier cap crossing first
            switch (a.trajectory.crossesFullAt, b.trajectory.crossesFullAt) {
            case (let ac?, let bc?): return ac < bc
            case (.some, .none):     return true
            case (.none, .some):     return false
            default:                 return false
            }
        }
    }

    // MARK: - Body

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
            Text(legendText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 620)
    }

    /// One-line legend; when the dashboard's pick isn't the single most
    /// accurate model (the selector treats models within ±1.5 points as tied
    /// and prefers the simpler one), say so — otherwise the list invites
    /// "why isn't the best one picked?".
    private var legendText: String {
        var s = "Solid — actual · dashed — projections from now · shaded — the models' spread · the highlighted model drives the dashboard."
        let best = trajectories.filter { $0.medianAbsError.isFinite }.min { $0.medianAbsError < $1.medianAbsError }
        if let best, let selected = trajectories.first(where: { $0.isSelected }),
           selected.modelId != best.modelId {
            s += " Models within ±1.5 points are treated as tied — the simplest of the tied models is used."
        }
        return s
    }

    /// "62% used · resets Mon 6 AM" — the cycle context the chart is read in.
    private var subtitle: String {
        let used = actual.last.map { "\(Int($0.value.rounded()))% used" } ?? ""
        let resets = "resets \(resetsAt.formatted(.dateTime.weekday(.abbreviated).hour()))"
        return [used, resets].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var chart: some View {
        Chart {
            envelopeMarks
            paceMarks
            actualMarks
            trajectoryMarks
            nowRuleMark
        }
        .chartXScale(domain: zoomStart...xEnd)
        .chartYScale(domain: yMin...yMax)
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisGridLine(); AxisValueLabel() } }
        .chartPlotStyle { $0.clipped() }
    }

    // MARK: - Chart marks

    /// Filled envelope band spanning the per-step min/max across all trajectories.
    /// Drawn first so it sits behind all lines.
    @ChartContentBuilder private var envelopeMarks: some ChartContent {
        ForEach(Array(envelopeSteps.enumerated()), id: \.offset) { _, step in
            AreaMark(
                x: .value("t", step.t),
                yStart: .value("lo", step.lo),
                yEnd: .value("hi", step.hi),
                series: .value("s", "envelope")
            )
            .foregroundStyle(Color.secondary.opacity(0.08))
            .interpolationMethod(.monotone)
        }
    }

    /// The 0→100 ideal-burn reference, drawn across the visible window.
    ///
    /// Both marks carry the style — a modifier after the second LineMark
    /// styles only that mark, and the first then renders in the chart's
    /// default (blue, solid) series color. The endpoints are the global
    /// 0→100 line evaluated at the visible window edges (zoomStart and
    /// xEnd), which may be well before reset when trajectories cap early.
    /// `.chartPlotStyle { $0.clipped() }` is the backstop: even if the
    /// left endpoint's y falls below yMin, the line cannot escape the plot
    /// frame.
    @ChartContentBuilder private var paceMarks: some ChartContent {
        let leftVal = PaceMath.paceFraction(
            now: zoomStart, resetsAt: resetsAt, windowDuration: durationSeconds) * 100
        let rightVal = PaceMath.paceFraction(
            now: xEnd, resetsAt: resetsAt, windowDuration: durationSeconds) * 100
        // Evaluate the SAME global burn line at both visible window edges so
        // the slope is correct and the line never extends past xEnd.
        ForEach([(zoomStart, leftVal), (xEnd, rightVal)], id: \.0) { t, v in
            LineMark(x: .value("t", t), y: .value("pct", v), series: .value("s", "pace"))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        if yMax >= 100 {
            RuleMark(y: .value("full", 100))
                .foregroundStyle(.secondary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }
    }

    /// Actuals colored by pace band per run — the same green/yellow/red
    /// grammar the dashboard chart uses, instead of one undifferentiated line.
    /// Operates on filteredActuals to match the zoomed x-domain.
    @ChartContentBuilder private var actualMarks: some ChartContent {
        ForEach(filteredRuns) { run in
            ForEach(run.points) { p in
                LineMark(x: .value("t", p.time), y: .value("pct", p.value),
                         series: .value("s", "actual-\(run.id)"))
                    .foregroundStyle(run.color)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        if let tail = filteredActuals.last {
            PointMark(x: .value("t", tail.time), y: .value("pct", tail.value))
                .foregroundStyle(bandColor(at: tail))
                .symbolSize(60)
        }
    }

    /// Vertical rule at "now" (where trajectories branch off).
    @ChartContentBuilder private var nowRuleMark: some ChartContent {
        if let now = trajectoryNow {
            RuleMark(x: .value("now", now))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }

    // MARK: - Actual runs (zoomed)

    /// Contiguous same-band runs of the actual line (mirrors PaceChartView),
    /// operating on the zoomed filtered actuals.
    private struct BandRun: Identifiable {
        let id: Int
        let points: [PaceChartView.Data.Point]
        let color: Color
    }

    private var filteredRuns: [BandRun] {
        buildRuns(from: filteredActuals)
    }

    private func buildRuns(from pts: [PaceChartView.Data.Point]) -> [BandRun] {
        var runs: [BandRun] = []
        var i = 0
        while i < pts.count {
            let c = bandColor(at: pts[i])
            var j = i + 1
            while j < pts.count, bandColor(at: pts[j]) == c { j += 1 }
            // Overlap one point so adjacent runs connect without gaps.
            let upper = min(j + 1, pts.count)
            runs.append(BandRun(id: runs.count, points: Array(pts[i..<upper]), color: c))
            i = j
        }
        return runs
    }

    private func bandColor(at p: PaceChartView.Data.Point) -> Color {
        let pace = PaceMath.paceFraction(
            now: p.time, resetsAt: resetsAt, windowDuration: durationSeconds) * 100
        return PaceBand(usedPct: p.value, paceEndPct: pace).color
    }

    // MARK: - Trajectory marks

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

    // MARK: - Accuracy table

    private var accuracyTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column headers make the right-hand number self-explanatory —
            // it's how far each model's final-value calls have missed on
            // this user's completed cycles.
            HStack {
                Text("MODEL")
                Spacer()
                Text("TYPICAL ACCURACY, PAST CYCLES")
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
                         ? String(format: "within ±%.0f%%", st.medianAbsError)
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
