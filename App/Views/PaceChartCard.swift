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
    /// Open the compare-models modal for a window key ("five_hour" /
    /// "seven_day"). Wired by the dashboard to its modal-navigation root,
    /// so the detail presents through the house dismissible modal like
    /// every other drill-down.
    let onCompare: ((String) -> Void)?

    /// 8-day window of rate-limit samples. Body never reads the array
    /// — pre-bucketed by window in `bucketed` so neither column does
    /// its own filter pass.
    @Query private var samples: [RateLimitSample]

    /// The shared intelligence engine — single source of the forecast
    /// trajectories (the dashed overlay; the compare-models modal asks the
    /// engine itself), with each model's accuracy coming from the engine's
    /// persisted per-user track record.
    @Environment(\.usageEngine) private var engine

    /// Forecast trajectory per window, refreshed when the engine refits.
    /// Keyed by window string.
    @State private var projections: [String: WindowProjection] = [:]
    /// Per-window outlook (projected end-of-window + band, crossing range,
    /// cycle frequency facts) for the caption line under each chart.
    @State private var outlooks: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
    @State private var endEstimates: [String: Estimate] = [:]

    struct WindowProjection: Equatable, Sendable {
        /// The selected model's raw forward trajectory (origin = the engine's
        /// last-refit snapshot). Re-anchored onto the live actual tail at
        /// render time in `liveChartData` so the dashed line continues the
        /// solid one seamlessly.
        var trajectory: BurnTrajectory.Trajectory
    }

    init(onCompare: ((String) -> Void)? = nil) {
        self.onCompare = onCompare
        let cutoff = Date().addingTimeInterval(-8 * 86400)
        var descriptor = FetchDescriptor<RateLimitSample>(
            predicate: #Predicate<RateLimitSample> { $0.sampledAt >= cutoff },
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        // Columnar projection. SwiftData @Query invalidation is
        // entity-agnostic, so this 8-day window (~2.8k rows) re-runs on
        // EVERY store save — including the token-only saves that fire
        // while the user types in Claude Code, even though no rate-limit
        // row changed. The card only ever reads these four scalar
        // attributes, so fetching just them avoids materializing ~2.8k
        // full RateLimitSample objects per refresh (the dominant remaining
        // open-window MainActor cost after the PR #102 toolbar fix; the
        // rows are warm in the page cache, so the cost is CPU object
        // instantiation, not disk). See docs/perf-tuning.md.
        descriptor.propertiesToFetch = [\.window, \.sampledAt, \.resetsAt, \.usedPercentage]
        _samples = Query(descriptor)
    }

    /// Re-ask the engine for both windows' answers. One pass powers the
    /// overlay (selected model) and the outlook caption (projected end +
    /// band, crossing, frequency facts).
    private func refreshProjections() async {
        guard let engine else { return }
        // Compute OFF the main actor. Awaiting the `@ModelActor` engine from
        // `@MainActor` here resumes its heavy forecast-model fit INLINE on
        // the main thread — the Swift "uncontended actor runs on the
        // caller's executor" optimization. A `sample(1)` taken while
        // scrolling caught `DiurnalBurnModel.fit` running on Main (~3k
        // samples), the dominant scroll-stutter source. A detached task
        // forces the fit onto the engine's own executor so it can never
        // block the UI; only the cheap `@State` assignment lands on main.
        let computed = await Task.detached(priority: .userInitiated) { [engine] in
            var nextSelected: [String: WindowProjection] = [:]
            var nextOutlooks: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
            var nextEnds: [String: Estimate] = [:]
            for window in RateLimitWindowKind.allCases {
                if let o = await engine.burnOutlook(window: window) { nextOutlooks[window.rawValue] = o }
                nextEnds[window.rawValue] = await engine.ask(.rateLimitOutlook(window))
                let list = await engine.rateLimitTrajectories(window: window)
                guard !list.isEmpty else { continue }
                if let chosen = list.first(where: { $0.isSelected }) ?? list.first {
                    nextSelected[window.rawValue] = WindowProjection(trajectory: chosen.trajectory)
                }
            }
            return (nextSelected, nextOutlooks, nextEnds)
        }.value
        projections = computed.0
        outlooks = computed.1
        endEstimates = computed.2
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
        // The "via oauth · just now" freshness chip moved to the page
        // header (`RateLimitSourceChip` in DashboardView) — it describes
        // the whole dashboard's data feed, not this card alone.
        PacerCard("Rate-limit pace") {
            if b.latest == nil {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 24) {
                    PaceChartColumn(
                        title: "5-hour",
                        windowKey: RateLimitWindowName.fiveHour,
                        duration: 5 * 3600,
                        windowSamples: b.fiveHour,
                        projection: projections[RateLimitWindowName.fiveHour],
                        outlook: outlooks[RateLimitWindowName.fiveHour],
                        endEstimate: endEstimates[RateLimitWindowName.fiveHour],
                        onCompare: onCompare
                    )
                    Divider()
                        .frame(height: 110)
                    PaceChartColumn(
                        title: "7-day",
                        windowKey: RateLimitWindowName.sevenDay,
                        duration: 7 * 86400,
                        windowSamples: b.sevenDay,
                        projection: projections[RateLimitWindowName.sevenDay],
                        outlook: outlooks[RateLimitWindowName.sevenDay],
                        endEstimate: endEstimates[RateLimitWindowName.sevenDay],
                        onCompare: onCompare
                    )
                }
            }
        }
        .task { await refreshProjections() }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshProjections() }
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
                Text("Pacer checks Anthropic every 5 minutes. If you're signed into Claude Code, the 5-hour and 7-day pace will appear within about 5 minutes.")
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
    /// "five_hour" / "seven_day" — the key the compare-models modal route
    /// is opened with.
    let windowKey: String
    let duration: TimeInterval
    /// Already filtered to this column's window and pre-sorted reverse-
    /// chronological by the parent.
    let windowSamples: [RateLimitSample]
    /// Forecast trajectory for this window (nil when unavailable). Drawn only
    /// on the live dashboard chart — deliberately not on the shared image.
    var projection: PaceChartCard.WindowProjection?
    /// Engine burn outlook (crossing range + cycle frequency facts) and the
    /// projected end-of-window estimate, for the outlook caption.
    var outlook: UsageIntelligenceEngine.BurnOutlook?
    var endEstimate: Estimate?
    /// Opens the compare-models modal (threaded from the dashboard's
    /// modal-navigation root).
    var onCompare: ((String) -> Void)?

    /// Share affordance state. `hovering` reveals the share button only
    /// while the cursor is over the column (Linear/Things idiom, keeps
    /// the card clean); `sharing` drives the preview popover.
    @State private var hovering = false
    @State private var sharing = false

    private var latest: RateLimitSample? { windowSamples.first }

    /// Display-cycle for this column. nil only when there's no sample
    /// or the sample has no `resetsAt`. Otherwise resolves the
    /// active-or-awaiting bracket for everything in the column body.
    private var cycle: DisplayCycle? {
        guard let latest, let resets = latest.resetsAt else { return nil }
        return DisplayCycle.resolve(resetsAt: resets, duration: duration)
    }

    /// Used % when we have a fresh reading but the server anchored no
    /// reset to it — the window is idle (0% used; Anthropic's usage
    /// endpoint returns `resets_at: null` until your first message of a
    /// window starts the clock). This is `nil` only when there's no
    /// sample at all, which is the genuine "still collecting the first
    /// reading" state. We branch on it so the column shows the real
    /// number + a calm idle note instead of the "--" / "resets unknown"
    /// / "collecting…" trio, which reads as broken (see #100).
    private var idleUsedPct: Double? {
        guard let latest, latest.resetsAt == nil else { return nil }
        return latest.usedPercentage
    }

    /// Build the `PaceChartView.Data` snapshot — same shape the widget
    /// will pass in. Synthesizes a "now" tail point so the line tracks
    /// to current time even if the most-recent sample is older.
    private var chartData: PaceChartView.Data? {
        guard let latest, let resets = latest.resetsAt else { return nil }
        let cycleStart = resets.addingTimeInterval(-duration)
        let now = Date()
        var points = windowSamples
            .inCycle(resetting: resets, duration: duration)
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
    /// (which renders from it) is unchanged. Takes the already-resolved
    /// `base` so `body` computes the window filter+sort a single time.
    private func liveChartData(base: PaceChartView.Data?) -> PaceChartView.Data? {
        guard let base else { return nil }
        guard let projection else { return base }
        // Re-anchor the forecast onto the live actual tail (`base.points.last`
        // — the same synthesized "now" point the solid line ends at) so the
        // dashed line continues it without a step. The engine's trajectory
        // starts at its last-refit snapshot, which by render time sits below
        // and behind the current dot; un-anchored it drew a gap and, near the
        // cap, a stray floating crossing dot.
        guard let tail = base.points.last else { return base }
        let rebased = projection.trajectory.reanchored(toTime: tail.time, value: tail.value)
        let pts = rebased.points.map { PaceChartView.Data.Point(time: $0.at, value: $0.usedPercentage) }
        // At/over the cap the trajectory collapses to its origin — nothing
        // meaningful to project, and drawing it would re-introduce the stray
        // dot. Fall back to the projection-free chart.
        guard pts.count >= 2 else { return base }
        return PaceChartView.Data(
            cycleStart: base.cycleStart,
            resetsAt: base.resetsAt,
            durationSeconds: base.durationSeconds,
            points: base.points,
            usedPct: base.usedPct,
            projection: pts,
            projectionCrossesFullAt: rebased.crossesFullAt
        )
    }

    var body: some View {
        // Resolve the chart data ONCE per body pass. Building it filters +
        // sorts the window's samples (~1–2k on the 7-day window), and it was
        // previously recomputed independently by the header's compare/share
        // controls and the chart slot — each `.onHover` toggle re-fires body,
        // so that was several redundant sorts per hover. `base` stays
        // projection-free (share-image parity); `live` layers the forecast.
        let base = chartData
        let live = liveChartData(base: base)
        return VStack(alignment: .leading, spacing: 8) {
            header(chartData: base)
            heroLine
            chipRow
            chartSlot(live: live)
            outlookLines
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }

    /// Status + burn chips under the hero numbers — the at-a-glance verdict
    /// row: behind/on pace/ahead/danger, and the burn outcome ("≈52% at
    /// reset" / "limit in 7 hr"). Crossing details, the calibrated range,
    /// and the raw %/hr live in the burn chip's tooltip.
    @ViewBuilder
    private var chipRow: some View {
        if let latest, let cycle, !cycle.isAwaiting {
            let band = PaceBand(
                usedPct: latest.usedPercentage,
                paceEndPct: cycle.paceFraction * 100)
            HStack(spacing: 6) {
                paceChip(band: band)
                burnChipView
            }
        }
    }

    @ViewBuilder
    private func paceChip(band: PaceBand) -> some View {
        Group {
            switch band {
            case .green:
                Chip(text: "behind", systemImage: "checkmark", tint: .green, size: .compact)
            case .white:
                Chip(text: "on pace", tint: .secondary, size: .compact)
            case .yellow:
                Chip(text: "ahead", systemImage: "exclamationmark", tint: .yellow, size: .compact)
            case .red:
                Chip(text: "danger", systemImage: "exclamationmark.triangle.fill", tint: .red, size: .compact)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var burnChipView: some View {
        if let outlook,
           let chip = Self.burnChip(outlook: outlook, endEstimate: endEstimate, duration: duration) {
            Chip(text: chip.text, systemImage: "flame.fill", tint: chip.tint, size: .compact)
                .fixedSize()
                .help(chip.help)
        }
    }

    /// Chip text + tint + tooltip for the burn outlook. nil when effectively
    /// idle (chip hidden). Outcome language, not rate ratios: "limit in
    /// 7 hr" (red) when a pre-reset hit is projected, "≈52% at reset"
    /// (colored by burn health) otherwise, raw "+2.1%/hr" as the
    /// young-history fallback.
    private static func burnChip(
        outlook: UsageIntelligenceEngine.BurnOutlook,
        endEstimate: Estimate?,
        duration: TimeInterval
    ) -> (text: String, tint: Color, help: String)? {
        let ratio = IntelligenceFormatting.capPaceRatio(
            slopePercentPerHour: outlook.slopePercentPerHour, windowSeconds: duration)
        guard ratio >= 0.05 else { return nil }          // effectively idle — say nothing
        var help = IntelligenceFormatting.capPaceHelp(
            slopePercentPerHour: outlook.slopePercentPerHour, windowSeconds: duration)
        if outlook.willHitLimitBeforeReset,
           let eta = IntelligenceFormatting.relativeCrossingPhrase(outlook) {
            // The absolute crossing time complements the chip's relative
            // form, demoted to hover so the same fact isn't printed twice.
            if let phrase = IntelligenceFormatting.crossingPhrase(outlook) {
                let when = phrase
                    .replacingOccurrences(of: "→ may hit limit ", with: "")
                    .replacingOccurrences(of: "→ limit ", with: "")
                help += " Crossing projected \(when), at your typical rhythm."
            }
            return ("limit \(eta)", .red, help)
        }
        let tint: Color = ratio < 0.9 ? .green : ratio < 1.15 ? .secondary : .orange
        if let e = endEstimate, !e.isInsufficient {
            if let band = e.interval80 {
                help += String(format: " Calibrated range at reset: %.0f–%.0f%%.",
                               band.lowerBound, band.upperBound)
            }
            return ("≈\(Int(e.value.rounded()))% at reset", tint, help)
        }
        return (String(format: "%+.1f%%/hr", outlook.slopePercentPerHour), tint, help)
    }

    /// One muted line of the user's own history with this window
    /// ("topped 90% in 3 of 73 cycles · hit the limit 1×"). The forecast
    /// itself lives in the chip row above the chart now.
    @ViewBuilder
    private var outlookLines: some View {
        if cycle?.isAwaiting == false, let o = outlook,
           let freq = IntelligenceFormatting.frequencyLine(o) {
            Text(freq)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// "Compare models" — opens the all-models projection modal. Lives in
    /// the column header next to the share button, hover-revealed (the
    /// Linear/Things idiom): the affordance is there when you reach for it,
    /// invisible when you're just reading the chart.
    @ViewBuilder
    private func compareButton(chartData: PaceChartView.Data?) -> some View {
        if let onCompare, cycle?.isAwaiting == false, chartData != nil, projection != nil {
            Button { onCompare(windowKey) } label: {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Compare every forecast model's projection and its accuracy on your cycles")
            .opacity(hovering || sharing ? 1 : 0)
        }
    }

    /// Everything the share sheet needs to render and name this window's
    /// chart as an image — built from the same resolved values the live
    /// chart draws, so the shared image *is* the live chart, blown up.
    /// `nil` (button hidden) when there's no active cycle with data.
    private func sharePayload(chartData: PaceChartView.Data?) -> PaceSharePayload? {
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
    private func shareButton(chartData: PaceChartView.Data?) -> some View {
        if let payload = sharePayload(chartData: chartData) {
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
    private func chartSlot(live: PaceChartView.Data?) -> some View {
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
        } else if let live {
            PaceChartView(data: live, style: .detailed)
                .frame(height: 96)
        } else if idleUsedPct != nil {
            // A reading exists but no window is anchored yet — nothing to
            // plot. Say so plainly instead of "collecting…", which implies
            // Pacer is still fetching.
            VStack(alignment: .leading, spacing: 4) {
                Text("No usage in this window yet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("The window starts when you next use Claude.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 96, alignment: .topLeading)
        } else {
            Text("collecting…")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(height: 96)
        }
    }

    private func header(chartData: PaceChartView.Data?) -> some View {
        HStack(spacing: 8) {
            Eyebrow(text: title)
            Spacer(minLength: 8)
            compareButton(chartData: chartData)
            shareButton(chartData: chartData)
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
        } else if idleUsedPct != nil {
            Text("idle · no active window")
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
        } else if let idle = idleUsedPct {
            // Idle window: show the real reading on its own. There's no
            // pace target to divide against (no cycle), so no "/ NN%".
            Text("\(Int(idle.rounded()))%")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text("--")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }
}
