import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// The dashboard's answer strip — one row, three tiles:
///
///   1. **Today** — spend, the day's outlook chip, tokens, budget bar.
///   2. **5-hour window** — used% vs pace, burn chip, and the pace chart.
///   3. **7-day window** — same.
///
/// Replaces the former two-row arrangement (HeroStripCard + a separate
/// "Rate-limit pace" card) that printed the same used%/pace% numbers twice
/// within ~400pt of each other. Here the chart lives *inside* the tile it
/// explains: one number, one chart, one source of truth — and the freed
/// space pulls the live-activity and timeline cards above the fold.
///
/// Interactions follow the Today tile's precedent: the whole pace tile is
/// clickable and opens the compare-models modal (the old hover-only icon
/// also remains as the hint in the header); share stays hover-revealed.
///
/// Perf notes (per AGENTS.md invariants and the two cards this merges):
/// the 8-day sample window is bucketed synchronously per body pass (same
/// pattern PaceChartCard documented — first render gets real layout, no
/// empty-state flash), today-cost derivations cache behind the scan-meta
/// tick, and engine answers refresh only on `.pacerEngineDidRecompute`.
struct PaceOverviewStrip: View {
    /// Open today's day-detail modal (Today tile click).
    let onTodayTap: (() -> Void)?
    /// Open the compare-models modal for a window key (pace tile click).
    let onCompare: ((String) -> Void)?

    @AppStorage(PacerSettings.Key.notifyOnDailyCost, store: PacerSettings.store)
    private var dailyBudgetEnabled: Bool = false
    @AppStorage(PacerSettings.Key.dailyCostThresholdUSD, store: PacerSettings.store)
    private var dailyBudgetUSD: Double = 50

    @Query private var todayAggregates: [DailyAggregate]
    /// 8-day window of rate-limit samples — enough to draw the full 7-day
    /// cycle. Body never reads the array directly; `bucketed` splits it
    /// once per pass.
    @Query private var samples: [RateLimitSample]
    @Query(PaceOverviewStrip.recentExtraUsage) private var extraUsages: [ExtraUsageSample]
    @Query(PaceOverviewStrip.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    @Environment(\.usageEngine) private var engine

    init(onTodayTap: (() -> Void)? = nil, onCompare: ((String) -> Void)? = nil) {
        self.onTodayTap = onTodayTap
        self.onCompare = onCompare
        let todayString = TokenSample.formatDate(Date())
        _todayAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == todayString }
        )
        let cutoff = Date().addingTimeInterval(-8 * 86400)
        _samples = Query(
            filter: #Predicate<RateLimitSample> { $0.sampledAt >= cutoff },
            sort: \.sampledAt,
            order: .reverse
        )
    }

    private static let recentExtraUsage: FetchDescriptor<ExtraUsageSample> = {
        var d = FetchDescriptor<ExtraUsageSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 1
        return d
    }()

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    // MARK: - Caches

    /// Scan-tick cache for the Today tile's derived values.
    @State private var cached = TodayFacts()

    private struct TodayFacts {
        var todayCost: Double = 0
        var todayTokens: Int64 = 0
        var extraUsageUSD: Double?
    }

    /// Engine answers, refreshed on `.pacerEngineDidRecompute` only.
    @State private var outlooks: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
    @State private var endEstimates: [String: Estimate] = [:]
    @State private var projections: [String: WindowProjection] = [:]
    @State private var todayEOD: Estimate?
    @State private var pacePercentile: Double?
    @State private var paceVsNow: Double?
    @State private var heldLadder: Int?

    struct WindowProjection: Equatable {
        var points: [PaceChartView.Data.Point]
        var crossesFullAt: Date?
    }

    private func refreshTodayFacts() {
        var next = TodayFacts()
        next.todayCost = todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
        next.todayTokens = todayAggregates.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens
        }
        if let latest = extraUsages.first {
            next.extraUsageUSD = latest.amountUSD
        }
        cached = next
    }

    private func refreshEngine() async {
        guard let engine else { return }
        var nextOutlooks: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
        var nextEnds: [String: Estimate] = [:]
        var nextProjections: [String: WindowProjection] = [:]
        for window in RateLimitWindowKind.allCases {
            if let o = await engine.burnOutlook(window: window) {
                nextOutlooks[window.rawValue] = o
            }
            nextEnds[window.rawValue] = await engine.ask(.rateLimitOutlook(window))
            let list = await engine.rateLimitTrajectories(window: window)
            if let chosen = list.first(where: { $0.isSelected }) ?? list.first {
                nextProjections[window.rawValue] = WindowProjection(
                    points: chosen.trajectory.points.map { .init(time: $0.at, value: $0.usedPercentage) },
                    crossesFullAt: chosen.trajectory.crossesFullAt)
            }
        }
        outlooks = nextOutlooks
        endEstimates = nextEnds
        projections = nextProjections
        todayEOD = await engine.ask(.projectedCost(.today))
        let vsNow = await engine.ask(.paceVsNow)
        paceVsNow = vsNow.isInsufficient ? nil : vsNow.value
        let pace = await engine.ask(.pace)
        pacePercentile = pace.isInsufficient ? nil : pace.value
        if let p = pacePercentile {
            heldLadder = IntelligenceFormatting.heldIndex(p, held: heldLadder)
        }
    }

    // MARK: - Bucketing (synchronous, per body pass)

    private struct Bucketed {
        var fiveHour: [RateLimitSample] = []
        var sevenDay: [RateLimitSample] = []
        var latest: RateLimitSample?
    }

    private var bucketed: Bucketed {
        var b = Bucketed()
        for s in samples {
            if s.window == RateLimitWindowName.fiveHour { b.fiveHour.append(s) }
            else if s.window == RateLimitWindowName.sevenDay { b.sevenDay.append(s) }
            if s.sampledAt > (b.latest?.sampledAt ?? .distantPast) { b.latest = s }
        }
        return b
    }

    // MARK: - Body

    var body: some View {
        let b = bucketed
        HStack(alignment: .top, spacing: 12) {
            costTile
            if b.latest == nil {
                emptyRateLimitTile
            } else {
                PaceWindowTile(
                    title: "5-hour pace",
                    windowKey: RateLimitWindowName.fiveHour,
                    duration: 5 * 3600,
                    windowSamples: b.fiveHour,
                    projection: projections[RateLimitWindowName.fiveHour],
                    outlook: outlooks[RateLimitWindowName.fiveHour],
                    endEstimate: endEstimates[RateLimitWindowName.fiveHour],
                    onCompare: onCompare
                )
                PaceWindowTile(
                    title: "7-day pace",
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
        .onAppear { refreshTodayFacts() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshTodayFacts() }
        .task { await refreshEngine() }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshEngine() }
        }
    }

    // MARK: - Today tile

    /// One-line outlook chip — same selection ladder the old hero used:
    /// evening → "≈$650 by tonight"; midday off-pace → "1.8× usual Friday
    /// spend"; on pace → "on your usual Friday pace"; else the percentile
    /// ladder phrase.
    private var todayOutlook: (text: String, icon: String, tint: Color, help: String)? {
        let dayName = Date().formatted(.dateTime.weekday(.wide))
        if let e = todayEOD, IntelligenceFormatting.rangeIsActionable(e, spendSoFar: cached.todayCost) {
            let help = e.interval80.map { IntelligenceFormatting.anchors($0) } ?? pacerCostExact(e.value)
            return ("≈\(IntelligenceFormatting.approxCost(e.value)) by tonight",
                    "chart.line.uptrend.xyaxis", .secondary, help)
        }
        if let r = paceVsNow {
            if r >= 1.3 || (r <= 0.7 && cached.todayCost > 1) {
                let help = "Dollars spent so far today vs the median spent by this hour on your \(dayName)s"
                let icon: String
                let tint: Color
                if r >= 1.3 {
                    icon = "arrow.up.right"
                    tint = r >= 3 ? .red : .orange
                } else {
                    icon = "arrow.down.right"
                    tint = .green
                }
                return ("\(IntelligenceFormatting.multiple(r)) usual \(dayName) spend",
                        icon, tint, help)
            }
            if r > 0 {
                let help = "Spend so far vs the median spend by this hour on your \(dayName)s"
                return ("on your usual \(dayName) pace", "equal", .secondary, help)
            }
        }
        if let p = pacePercentile {
            let label = IntelligenceFormatting.paceLabel(
                index: IntelligenceFormatting.heldIndex(p, held: heldLadder),
                dayName: dayName)
            return (label, "waveform.path.ecg", .secondary,
                    "Today's projected total sits at the \(Int((p * 100).rounded()))th percentile of your days")
        }
        return nil
    }

    private var costTile: some View {
        StripTile(label: "Today", onTap: onTodayTap, tapHelp: "Open today's breakdown") {
            VStack(alignment: .leading, spacing: 8) {
                Text(pacerCost(cached.todayCost)).help(pacerCostExact(cached.todayCost))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let o = todayOutlook {
                    Chip(text: o.text, systemImage: o.icon, tint: o.tint, size: .compact)
                        .fixedSize()
                        .help(o.help)
                }
                HStack(spacing: 6) {
                    if let extra = cached.extraUsageUSD, extra > 0 {
                        Chip(
                            text: "+\(pacerCost(extra)) over",
                            systemImage: "plus.forwardslash.minus",
                            tint: .orange,
                            size: .compact
                        )
                        .fixedSize()
                        .help("Over the included quota by \(pacerCostExact(extra))")
                    }
                    Text("\(pacerTokens(cached.todayTokens)) tokens")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("\(pacerTokensExact(cached.todayTokens)) tokens")
                }
                Spacer(minLength: 0)
                if dailyBudgetEnabled, dailyBudgetUSD > 0 {
                    budgetBar
                }
            }
        }
    }

    /// Today's cost as a fraction of the configured daily budget.
    /// Green (<80%), orange (≥80%), red (≥100%).
    @ViewBuilder
    private var budgetBar: some View {
        let ratio = dailyBudgetUSD > 0 ? cached.todayCost / dailyBudgetUSD : 0
        let displayRatio = min(1.0, max(0, ratio))
        let pctText = "\(Int((ratio * 100).rounded()))%"
        let tint: Color =
            ratio >= 1.0 ? .red :
            ratio >= 0.8 ? .orange : .green
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("\(pacerCost(cached.todayCost)) / \(pacerCost(dailyBudgetUSD))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("\(pacerCostExact(cached.todayCost)) of \(pacerCostExact(dailyBudgetUSD)) daily budget")
                Spacer(minLength: 0)
                Text(pctText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint)
                        .frame(width: geo.size.width * displayRatio, height: 4)
                }
            }
            .frame(height: 4)
        }
    }

    /// Shown in place of both pace tiles before the first rate-limit
    /// sample ever lands (fresh install / signed out).
    private var emptyRateLimitTile: some View {
        StripTile(label: "Rate limits") {
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
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Pace window tile

/// One rate-limit window: hero used%/pace%, status + burn chips, the pace
/// chart, and the engine's outlook caption — the merged body of the old
/// hero tile and pace-chart column. The whole tile opens the compare-models
/// modal; share is hover-revealed in the header.
private struct PaceWindowTile: View {
    let title: String
    let windowKey: String
    let duration: TimeInterval
    /// Pre-sorted reverse-chronological by the parent.
    let windowSamples: [RateLimitSample]
    var projection: PaceOverviewStrip.WindowProjection?
    var outlook: UsageIntelligenceEngine.BurnOutlook?
    var endEstimate: Estimate?
    var onCompare: ((String) -> Void)?

    @State private var hovering = false
    @State private var sharing = false

    private var latest: RateLimitSample? { windowSamples.first }

    private var cycle: DisplayCycle? {
        guard let latest, let resets = latest.resetsAt else { return nil }
        return DisplayCycle.resolve(resetsAt: resets, duration: duration)
    }

    private var chartData: PaceChartView.Data? {
        guard let latest, let resets = latest.resetsAt else { return nil }
        let cycleStart = resets.addingTimeInterval(-duration)
        let now = Date()
        var points = windowSamples
            .filter { $0.sampledAt >= cycleStart && $0.sampledAt <= now }
            .sorted { $0.sampledAt < $1.sampledAt }
            .map { PaceChartView.Data.Point(time: $0.sampledAt, value: $0.usedPercentage) }
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

    /// Chart data plus the forecast overlay (live dashboard only; the
    /// share image renders from the overlay-free `chartData`).
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
        StripTile(
            label: title,
            onTap: canCompare ? { onCompare?(windowKey) } : nil,
            tapHelp: "Compare every forecast model's projection and its accuracy on your cycles",
            header: { headerAccessories }
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if let latest, let cycle, !cycle.isAwaiting {
                    heroLine(latest: latest, cycle: cycle)
                    chipRow(latest: latest, cycle: cycle)
                } else if cycle?.isAwaiting == true {
                    awaitingHero
                } else {
                    collectingHero
                }
                chartSlot
                outlookLines
            }
        }
        .onHover { hovering = $0 }
    }

    private var canCompare: Bool {
        onCompare != nil && cycle?.isAwaiting == false && projection != nil
    }

    // MARK: Header accessories (share + reset caption)

    @ViewBuilder
    private var headerAccessories: some View {
        shareButton
        caption
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
        }
    }

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

    // MARK: Hero + chips

    @ViewBuilder
    private func heroLine(latest: RateLimitSample, cycle: DisplayCycle) -> some View {
        let pacePct = cycle.paceFraction * 100
        let band = PaceBand(usedPct: latest.usedPercentage, paceEndPct: pacePct)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(Int(latest.usedPercentage.rounded()))%")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(bandColor(band))
                .lineLimit(1)
            Text("/")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
            Text("\(Int(pacePct.rounded()))%")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Where the steady 0→100% burn line sits right now — the percentage you'd be at if you used the window perfectly evenly")
        }
    }

    @ViewBuilder
    private func chipRow(latest: RateLimitSample, cycle: DisplayCycle) -> some View {
        let pacePct = cycle.paceFraction * 100
        let band = PaceBand(usedPct: latest.usedPercentage, paceEndPct: pacePct)
        HStack(spacing: 6) {
            paceChip(band: band)
            burnChipView
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

    /// Burn chip — same outcome language the hero strip introduced:
    /// "limit in 7 hr" when a pre-reset hit is projected, "≈52% at reset"
    /// otherwise. Hidden when effectively idle.
    @ViewBuilder
    private var burnChipView: some View {
        if let outlook,
           let chip = Self.burnChip(outlook: outlook, endEstimate: endEstimate, duration: duration) {
            Chip(text: chip.text, systemImage: "flame.fill", tint: chip.tint, size: .compact)
                .fixedSize()
                .help(chip.help)
        }
    }

    private static func burnChip(
        outlook: UsageIntelligenceEngine.BurnOutlook,
        endEstimate: Estimate?,
        duration: TimeInterval
    ) -> (text: String, tint: Color, help: String)? {
        let ratio = IntelligenceFormatting.capPaceRatio(
            slopePercentPerHour: outlook.slopePercentPerHour, windowSeconds: duration)
        guard ratio >= 0.05 else { return nil }
        var help = IntelligenceFormatting.capPaceHelp(
            slopePercentPerHour: outlook.slopePercentPerHour, windowSeconds: duration)
        if outlook.willHitLimitBeforeReset,
           let eta = IntelligenceFormatting.relativeCrossingPhrase(outlook) {
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

    private func bandColor(_ band: PaceBand) -> Color {
        switch band {
        case .green:  return .green
        case .white:  return .primary
        case .yellow: return .yellow
        case .red:    return .red
        }
    }

    // MARK: Placeholder heroes (awaiting / collecting)

    /// Same vertical footprint as heroLine + chipRow so the strip's
    /// equal-height layout doesn't reflow across states.
    private var awaitingHero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("—")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
            Text("awaiting first sample of new cycle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(height: 20)
        }
    }

    private var collectingHero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("—")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
            Text("collecting…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(height: 20)
        }
    }

    // MARK: Chart + outlook

    @ViewBuilder
    private var chartSlot: some View {
        if cycle?.isAwaiting == true {
            Text("Pacer will plot the new cycle once a fresh sample arrives.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 80, alignment: .topLeading)
        } else if let liveChartData {
            PaceChartView(data: liveChartData, style: .detailed)
                .frame(height: 80)
        } else {
            Color.clear.frame(height: 80)
        }
    }

    @ViewBuilder
    private var outlookLines: some View {
        if cycle?.isAwaiting == false {
            VStack(alignment: .leading, spacing: 2) {
                if let o = outlook, o.willHitLimitBeforeReset,
                   let crossing = IntelligenceFormatting.crossingPhrase(o) {
                    Text(crossing)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help("Projected to reach 100% before this window resets, at your typical rhythm. A time range spans the engine's calibrated uncertainty about when; \"may\" means the reset could plausibly come first.")
                } else if let e = endEstimate, !e.isInsufficient {
                    let band = e.interval80.map {
                        " · \(Int($0.lowerBound.rounded()))–\(Int($0.upperBound.rounded()))% range"
                    } ?? ""
                    Text("on pace to end ~\(Int(e.value.rounded()))%\(band)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Projected utilization when this window resets, with its calibrated 80% range")
                }
                if let o = outlook, let freq = IntelligenceFormatting.frequencyLine(o) {
                    Text(freq)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Tile chrome

/// Shared tile surface for the strip — the PacerCard look with an eyebrow
/// header row (label + optional accessories) and optional whole-tile click
/// behavior with the hover ring the Today tile established.
private struct StripTile<Header: View, Content: View>: View {
    let label: String
    var onTap: (() -> Void)? = nil
    var tapHelp: String = ""
    @ViewBuilder var header: () -> Header
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    init(
        label: String,
        onTap: (() -> Void)? = nil,
        tapHelp: String = "",
        @ViewBuilder header: @escaping () -> Header = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.onTap = onTap
        self.tapHelp = tapHelp
        self.header = header
        self.content = content
    }

    var body: some View {
        let surface = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Eyebrow(text: label)
                Spacer(minLength: 8)
                header()
                if onTap != nil {
                    Image(systemName: "arrow.up.right.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1.0 : 0.0)
                }
            }
            content()
        }
        .padding(PacerDesign.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: PacerDesign.cardCornerRadius, style: .continuous)
                .fill(PacerDesign.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PacerDesign.cardCornerRadius, style: .continuous)
                .stroke(
                    onTap != nil && hovering
                        ? Color.accentColor.opacity(0.45)
                        : PacerDesign.cardStroke,
                    lineWidth: 1
                )
        )

        if let onTap {
            Button(action: onTap) {
                surface.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .modifier(OptionalTileHelp(text: tapHelp))
        } else {
            surface
        }
    }
}

/// `.help()` only when non-empty — an empty tooltip bubble reads as broken.
private struct OptionalTileHelp: ViewModifier {
    let text: String
    func body(content: Content) -> some View {
        if text.isEmpty {
            content
        } else {
            content.help(text)
        }
    }
}

// MARK: - Header freshness chip

/// "via oauth · just now" — the rate-limit data-source freshness signal,
/// now in the Dashboard page header (it described the whole strip, not one
/// card). Goes yellow with a warning triangle when an OAuth feed stalls
/// past 15 minutes — commonly an expired Claude Code token.
struct RateLimitSourceChip: View {
    @Query(RateLimitSourceChip.newestSample) private var newest: [RateLimitSample]

    private static let newestSample: FetchDescriptor<RateLimitSample> = {
        var d = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 1
        return d
    }()

    var body: some View {
        if let latest = newest.first {
            // OAuth samples ought to arrive every 5 min; statusline samples
            // are irregular by nature, so the staleness warning is
            // oauth-only. See #3.
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
}
