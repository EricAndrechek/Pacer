import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Pace charts for the 5-hour and 7-day rate-limit windows. The chart
/// itself lives in `PacerUI.PaceChartView` so the widget extension and
/// (eventually) the menu-bar popover render the exact same SwiftUI
/// view. This card just sources the data from SwiftData and arranges
/// the two columns.
struct PaceChartCard: View {
    /// 8-day window of rate-limit samples. Body never reads the array
    /// — pre-bucketed by window in `bucketed` so neither column does
    /// its own filter pass.
    @Query private var samples: [RateLimitSample]
    @Query(PaceChartCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    /// Forecast trajectory per window, recomputed on the scan tick (the
    /// backtest is cheap but not per-render cheap). Keyed by window string.
    @State private var projections: [String: WindowProjection] = [:]

    struct WindowProjection: Equatable {
        var points: [PaceChartView.Data.Point]
        var crossesFullAt: Date?
    }

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

    /// Backtest-select a curve fit per window and sample its forward
    /// trajectory. Cheap fits, but the backtest loops past cycles — so it runs
    /// on the scan tick, not every render.
    private func refreshProjections() {
        let now = Date()
        var next: [String: WindowProjection] = [:]
        for (window, duration) in [(RateLimitWindowName.fiveHour, 5.0 * 3600),
                                    (RateLimitWindowName.sevenDay, 7.0 * 86400)] {
            let tuples = samples.compactMap { s -> (at: Date, usedPercentage: Double, resetsAt: Date)? in
                guard s.window == window, let resets = s.resetsAt else { return nil }
                return (s.sampledAt, s.usedPercentage, resets)
            }
            let (current, history) = BurnTrajectory.segment(samples: tuples, duration: duration, now: now)
            guard let current,
                  let traj = BurnTrajectory.bestTrajectory(current: current, history: history)
            else { continue }
            next[window] = WindowProjection(
                points: traj.points.map { .init(time: $0.at, value: $0.usedPercentage) },
                crossesFullAt: traj.crossesFullAt)
        }
        projections = next
    }

    private struct Bucketed {
        var fiveHour: [RateLimitSample] = []
        var sevenDay: [RateLimitSample] = []
        var latest: RateLimitSample?
    }

    /// Derived synchronously from `samples` so the first render already
    /// has the real layout — the previous @State + .onAppear pattern
    /// rendered the empty state for one frame, then reflowed all cards
    /// below this one when the cache populated.
    private var bucketed: Bucketed {
        var b = Bucketed()
        for s in samples {
            if s.window == "five_hour" { b.fiveHour.append(s) }
            else if s.window == "seven_day" { b.sevenDay.append(s) }
            if s.sampledAt > (b.latest?.sampledAt ?? .distantPast) { b.latest = s }
        }
        return b
    }

    var body: some View {
        let b = bucketed
        PacerCard("Rate-limit pace", trailing: { trailingChip(latest: b.latest) }) {
            if b.latest == nil {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 24) {
                    PaceChartColumn(
                        title: "5-hour",
                        duration: 5 * 3600,
                        windowSamples: b.fiveHour,
                        projection: projections[RateLimitWindowName.fiveHour]
                    )
                    Divider()
                        .frame(height: 110)
                    PaceChartColumn(
                        title: "7-day",
                        duration: 7 * 86400,
                        windowSamples: b.sevenDay,
                        projection: projections[RateLimitWindowName.sevenDay]
                    )
                }
            }
        }
        .onAppear { refreshProjections() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshProjections() }
    }

    @ViewBuilder
    private func trailingChip(latest: RateLimitSample?) -> some View {
        if let latest {
            // OAuth samples ought to arrive every 5 min. If the newest one
            // is much older than that — the poller is stalled (commonly an
            // expired Claude Code token) and the chart numbers are stale.
            // statusline samples are irregular by nature; skip the warning
            // for that source. See #3.
            let elapsed = Date().timeIntervalSince(latest.sampledAt)
            let isStaleOAuth = latest.source == RateLimitSource.oauth && elapsed > 15 * 60
            HStack(spacing: 4) {
                if isStaleOAuth {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                }
                Text("via \(latest.source) · \(pacerRelative(latest.sampledAt))")
                    .font(.system(size: 11))
            }
            .foregroundStyle(isStaleOAuth ? Color.yellow : .secondary)
            .help(isStaleOAuth
                ? "Pacer hasn't received fresh data in \(pacerRelative(latest.sampledAt)). The OAuth token may have expired — try launching or quitting/reopening Claude Code to refresh it. See ~/Library/Logs/Pacer/Pacer.err.log for the poller's last outcome."
                : "")
        }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Waiting for the first rate-limit reading")
                    .font(.body.weight(.medium))
                Text("Pacer checks Anthropic every 5 minutes. If you're signed into Claude Code, the 5-hour and 7-day pace will appear here shortly.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .frame(minHeight: 96, alignment: .topLeading)
    }
}

/// One window's column inside `PaceChartCard`. Renders the title,
/// hero used%/pace% line, and the shared `PaceChartView`. The view
/// itself is in PacerUI so the widget extension renders the same
/// chart pixel-for-pixel.
private struct PaceChartColumn: View {
    let title: String
    let duration: TimeInterval
    /// Already filtered to this column's window and pre-sorted reverse-
    /// chronological by the parent.
    let windowSamples: [RateLimitSample]
    /// Forecast trajectory for this window (nil when unavailable). Drawn only
    /// on the live dashboard chart — deliberately not on the shared image.
    var projection: PaceChartCard.WindowProjection?

    /// Share affordance state. `hovering` reveals the share button only
    /// while the cursor is over the column (Linear/Things idiom, keeps
    /// the card clean); `sharing` drives the preview popover.
    @State private var hovering = false
    @State private var sharing = false
    @State private var showingDetail = false

    private var latest: RateLimitSample? { windowSamples.first }

    /// Display-cycle for this column. nil only when there's no sample
    /// or the sample has no `resetsAt`. Otherwise resolves the
    /// active-or-awaiting bracket for everything in the column body.
    private var cycle: DisplayCycle? {
        guard let latest, let resets = latest.resetsAt else { return nil }
        return DisplayCycle.resolve(resetsAt: resets, duration: duration)
    }

    /// Build the `PaceChartView.Data` snapshot — same shape the widget
    /// will pass in. Synthesizes a "now" tail point so the line tracks
    /// to current time even if the most-recent sample is older.
    private var chartData: PaceChartView.Data? {
        guard let latest, let resets = latest.resetsAt else { return nil }
        let cycleStart = resets.addingTimeInterval(-duration)
        let now = Date()
        var points = windowSamples
            .filter { $0.sampledAt >= cycleStart && $0.sampledAt <= now }
            .sorted { $0.sampledAt < $1.sampledAt }
            .map { PaceChartView.Data.Point(time: $0.sampledAt, value: $0.usedPercentage) }
        // Clamp the synthesized tail to the cycle: once `now > resets`
        // (cycle ended, no fresh sample yet), a tail at `now` falls
        // outside `chartXScale`'s domain.
        let tailTime = min(now, resets)
        if points.last?.time != tailTime {
            points.append(.init(time: tailTime, value: latest.usedPercentage))
        }
        return PaceChartView.Data(
            cycleStart: cycleStart,
            resetsAt: resets,
            durationSeconds: duration,
            points: points,
            usedPct: latest.usedPercentage
        )
    }

    /// `chartData` plus the forecast overlay — used only by the live dashboard
    /// chart. `chartData` itself stays projection-free so the shared image
    /// (which renders from it) is unchanged.
    private var liveChartData: PaceChartView.Data? {
        guard let base = chartData else { return nil }
        guard let projection else { return base }
        return PaceChartView.Data(
            cycleStart: base.cycleStart,
            resetsAt: base.resetsAt,
            durationSeconds: base.durationSeconds,
            points: base.points,
            usedPct: base.usedPct,
            projection: projection.points,
            projectionCrossesFullAt: projection.crossesFullAt
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            heroLine
            chartSlot
            compareButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
        .sheet(isPresented: $showingDetail) { detailSheet }
    }

    /// "Compare models" — opens the all-models projection detail. Shown only
    /// when there's an active cycle with a chart to compare against.
    @ViewBuilder
    private var compareButton: some View {
        if cycle?.isAwaiting == false, chartData != nil {
            Button { showingDetail = true } label: {
                Label("Compare models", systemImage: "chart.xyaxis.line")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("See every forecast model's projection and its fit accuracy")
        }
    }

    /// Builds the detail sheet on demand: fit all candidate models to the
    /// current cycle and score them against past cycles.
    @ViewBuilder
    private var detailSheet: some View {
        let now = Date()
        let tuples = windowSamples.compactMap { s -> (at: Date, usedPercentage: Double, resetsAt: Date)? in
            guard let resets = s.resetsAt else { return nil }
            return (s.sampledAt, s.usedPercentage, resets)
        }
        let segmented = BurnTrajectory.segment(samples: tuples, duration: duration, now: now)
        if let current = segmented.current, let data = chartData {
            ProjectionDetailView(
                title: "\(title) projection",
                cycleStart: data.cycleStart,
                resetsAt: data.resetsAt,
                durationSeconds: duration,
                actual: data.points,
                trajectories: BurnTrajectory.allTrajectories(current: current, history: segmented.history))
        } else {
            Text("Not enough data to compare models yet.").padding(40)
        }
    }

    /// Everything the share sheet needs to render and name this window's
    /// chart as an image — built from the same resolved values the live
    /// chart draws, so the shared image *is* the live chart, blown up.
    /// `nil` (button hidden) when there's no active cycle with data.
    private var sharePayload: PaceSharePayload? {
        guard let chartData,
              let cycle, !cycle.isAwaiting,
              let latest, let resets = latest.resetsAt
        else { return nil }
        let windowName = duration <= 6 * 3600 ? "5-Hour" : "7-Day"
        let slug = duration <= 6 * 3600 ? "5-hour" : "7-day"
        return PaceSharePayload(
            title: "\(windowName) Usage Pace",
            data: chartData,
            duration: duration,
            resetsAt: resets,
            usedPct: latest.usedPercentage,
            paceEndPct: cycle.paceFraction * 100,
            fileName: "pacer-\(slug)-pace.png"
        )
    }

    /// Hover-revealed share button + its preview popover. Lives only when
    /// there's a shareable cycle; the popover anchors here.
    @ViewBuilder
    private var shareButton: some View {
        if let payload = sharePayload {
            Button { sharing = true } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Share this chart as an image")
            .opacity(hovering || sharing ? 1 : 0)
            .popover(isPresented: $sharing, arrowEdge: .bottom) {
                ChartShareSheet(
                    fileName: payload.fileName,
                    makeCard: { scheme in AnyView(PaceShareCard(payload: payload, scheme: scheme)) }
                )
            }
        }
    }

    /// Renders the chart for an active cycle or a textual placeholder
    /// when awaiting. Same vertical footprint either way so the parent
    /// HStack's equal-height layout stays stable.
    @ViewBuilder
    private var chartSlot: some View {
        if cycle?.isAwaiting == true {
            VStack(alignment: .leading, spacing: 4) {
                Text("Awaiting first sample of new cycle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Pacer will plot the new cycle once a fresh sample arrives.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 96, alignment: .topLeading)
        } else if let liveChartData {
            PaceChartView(data: liveChartData, style: .detailed)
                .frame(height: 96)
        } else {
            Text("collecting…")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(height: 96)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Eyebrow(text: title)
            Spacer(minLength: 8)
            shareButton
            caption
        }
    }

    @ViewBuilder
    private var caption: some View {
        if let cycle, cycle.isAwaiting {
            Text("cycle reset · awaiting")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else if let resets = latest?.resetsAt {
            Text(pacerResetCaption(resetsAt: resets, durationSeconds: duration))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else {
            Text("resets unknown")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var heroLine: some View {
        if let latest, let cycle, !cycle.isAwaiting {
            let paceEndPct = cycle.paceFraction * 100
            let band = PaceBand(usedPct: latest.usedPercentage, paceEndPct: paceEndPct)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(latest.usedPercentage.rounded()))%")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(band.color)
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
}
