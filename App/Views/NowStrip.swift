import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// The dashboard's top strip — two categorically different facts, not two
/// sizes of the same bucket:
///
///   1. **Now** — what's *happening*: the burn rate ($/hr over the last
///      hour) and the running session (project · duration · session cost).
///      Rates and running sessions are genuinely "now" facts; a shorter
///      dollar bucket labelled "live" was arbitrary (Eric: "isn't today
///      live too?"). Clicking opens the running session's detail.
///   2. **Today** — what it has *added up to*: spend so far, outlook chip,
///      budget bar, and the spent→projected end-of-day bar once the
///      projection is decision-useful.
///
/// The time-bucket ladder continues down the page (today's breakdowns →
/// week → 30 days → month outlook with the trend cards).
struct NowStrip: View {
    /// Open today's day-detail modal (Today tile click).
    let onTodayTap: (() -> Void)?
    /// Open a session's detail modal (Now tile click while a session is
    /// running). Arguments: sessionId, project display name.
    let onSessionTap: ((String, String) -> Void)?

    @AppStorage(PacerSettings.Key.notifyOnDailyCost, store: PacerSettings.store)
    private var dailyBudgetEnabled: Bool = false
    @AppStorage(PacerSettings.Key.dailyCostThresholdUSD, store: PacerSettings.store)
    private var dailyBudgetUSD: Double = 50
    /// Read purely to drive the `SampleCostCache.reload()` side effect —
    /// other views still call the per-sample cost helper and rely on the
    /// global reload happening somewhere on the dashboard.
    @AppStorage(PacerSettings.Key.costMode, store: PacerSettings.store)
    private var costModeRaw: String = CostMode.auto.rawValue

    @Query private var todayAggregates: [DailyAggregate]
    /// Hour buckets for "recent" activity — the two most-recent hour
    /// buckets approximate a rolling last-hour rate (between exactly 1h
    /// and ~2h of span). Cost is baked into HourlyAggregate at recompute
    /// time, so no per-render pricing lookups.
    @Query private var recentHourlyRows: [HourlyAggregate]
    /// Most-recent sample (any age) so the quiet state can say "last
    /// activity 3h ago" instead of a flat "no samples".
    @Query(NowStrip.latestSampleProbe) private var latestSamples: [TokenSample]
    /// Most-recently-touched session, for the Now tile's session line.
    @Query(NowStrip.latestSessionProbe) private var latestSessions: [SessionInfo]
    @Query(NowStrip.recentExtraUsage) private var extraUsages: [ExtraUsageSample]
    @Query(NowStrip.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    @Environment(\.usageEngine) private var engine

    init(onTodayTap: (() -> Void)? = nil, onSessionTap: ((String, String) -> Void)? = nil) {
        self.onTodayTap = onTodayTap
        self.onSessionTap = onSessionTap
        let now = Date()
        let cal = Calendar.current
        let todayString = TokenSample.formatDate(now)
        _todayAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == todayString }
        )
        // Current hour bucket + the previous one; expressed via the
        // (date, hour) key range, with the midnight-crossing OR leg.
        let currentHourStart = cal.date(
            bySettingHour: cal.component(.hour, from: now),
            minute: 0,
            second: 0,
            of: now
        ) ?? now
        let twoHoursAgoStart = cal.date(byAdding: .hour, value: -1, to: currentHourStart) ?? now
        let yesterdayString = TokenSample.formatDate(twoHoursAgoStart)
        let lowestHour = cal.component(.hour, from: twoHoursAgoStart)
        if todayString == yesterdayString {
            _recentHourlyRows = Query(
                filter: #Predicate<HourlyAggregate> {
                    $0.date == todayString && $0.hour >= lowestHour
                }
            )
        } else {
            _recentHourlyRows = Query(
                filter: #Predicate<HourlyAggregate> {
                    $0.date == todayString
                    || ($0.date == yesterdayString && $0.hour >= lowestHour)
                }
            )
        }
    }

    private static let latestSampleProbe: FetchDescriptor<TokenSample> = {
        var d = FetchDescriptor<TokenSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 1
        return d
    }()

    private static let latestSessionProbe: FetchDescriptor<SessionInfo> = {
        var d = FetchDescriptor<SessionInfo>(
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        d.fetchLimit = 1
        return d
    }()

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

    @State private var cached = TodayFacts()

    private struct TodayFacts {
        var todayCost: Double = 0
        var todayTokens: Int64 = 0
        var extraUsageUSD: Double?
    }

    @State private var todayEOD: Estimate?
    @State private var record: UsageIntelligenceEngine.TrackRecord?
    @State private var pacePercentile: Double?
    @State private var paceVsNow: Double?
    @State private var heldLadder: Int?

    private func refreshFacts() {
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
        todayEOD = await engine.ask(.projectedCost(.today))
        record = await engine.eveningTrackRecord()
        let vsNow = await engine.ask(.paceVsNow)
        paceVsNow = vsNow.isInsufficient ? nil : vsNow.value
        let pace = await engine.ask(.pace)
        pacePercentile = pace.isInsufficient ? nil : pace.value
        if let p = pacePercentile {
            heldLadder = IntelligenceFormatting.heldIndex(p, held: heldLadder)
        }
    }

    // MARK: - Live stats (synchronous, per body pass)

    private struct LiveStats {
        var tokensLastHour: Int64 = 0
        var costLastHour: Double = 0
        var sampleCount: Int = 0
        var lastSampleAt: Date?
        var hasFreshActivity: Bool {
            lastSampleAt.map { Date().timeIntervalSince($0) < 600 } ?? false
        }
    }

    private var stats: LiveStats {
        var s = LiveStats()
        for row in recentHourlyRows {
            s.tokensLastHour += row.inputTokens + row.outputTokens
            s.costLastHour += row.totalCostUSD
            s.sampleCount += row.sampleCount
        }
        s.lastSampleAt = latestSamples.first?.sampledAt
        return s
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            nowTile
            costTile
        }
        .onAppear { refreshFacts() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshFacts() }
        .onChange(of: costModeRaw) { _, _ in
            Task { await SampleCostCache.reload() }
        }
        .task { await refreshEngine() }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshEngine() }
        }
    }

    // MARK: - Now tile

    /// The session counts as "running" when its last write is recent —
    /// same 10-minute freshness window the live indicator uses.
    private var runningSession: SessionInfo? {
        guard let s = latestSessions.first,
              Date().timeIntervalSince(s.lastSeenAt) < 600 else { return nil }
        return s
    }

    private var nowTile: some View {
        let s = stats
        let session = runningSession
        return StripTile(
            label: "Now",
            onTap: (session != nil && onSessionTap != nil) ? {
                if let session {
                    onSessionTap?(session.sessionId, pacerShortPath(session.projectPath))
                }
            } : nil,
            tapHelp: "Open this session's details",
            header: { freshnessChip(stats: s) }
        ) {
            if s.sampleCount == 0 {
                nowQuietState
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // The hero is a RATE, not another dollar bucket —
                    // that's what makes this tile "now" rather than a
                    // smaller "today".
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(pacerCost(s.costLastHour))
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("/hr")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .help("\(pacerCostExact(s.costLastHour)) over the last hour — \(pacerTokensExact(s.tokensLastHour)) tokens, \(s.sampleCount) samples")
                    if let session {
                        Text("\(pacerShortPath(session.projectPath)) · \(sessionDuration(session)) session · \(pacerCost(session.cumulativeCostUSD))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help("Session total \(pacerCostExact(session.cumulativeCostUSD)) since \(session.firstSeenAt.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("\(pacerTokens(s.tokensLastHour)) tokens · \(s.sampleCount) sample\(s.sampleCount == 1 ? "" : "s") this hour")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func sessionDuration(_ s: SessionInfo) -> String {
        let hours = s.lastSeenAt.timeIntervalSince(s.firstSeenAt) / 3600
        if hours < 1 {
            return "\(max(1, Int((hours * 60).rounded()))) min"
        }
        return String(format: "%.1f hr", hours)
    }

    @ViewBuilder
    private func freshnessChip(stats: LiveStats) -> some View {
        if stats.hasFreshActivity {
            Chip(text: "live", systemImage: "bolt.fill", tint: .yellow, size: .compact)
        } else if let last = stats.lastSampleAt {
            Text("last sample \(pacerRelative(last))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var nowQuietState: some View {
        if let latest = latestSamples.first {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Last activity \(pacerRelative(latest.sampledAt)) — \(pacerModelDisplayName(latest.model)).")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text("No samples yet. This tile lights up as Claude Code activity hits the store.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Today tile

    /// True when the end-of-day projection is worth a bar (the same
    /// display gate the old projection row used). The outlook chip skips
    /// its EOD branch in that case so the projection isn't said twice.
    private var showEODBar: Bool {
        guard let e = todayEOD else { return false }
        return IntelligenceFormatting.rangeIsActionable(e, spendSoFar: cached.todayCost)
    }

    /// One-line outlook chip — midday off-pace → "1.8× usual Friday
    /// spend"; on pace → "on your usual Friday pace"; else the percentile
    /// ladder phrase. (The evening "≈$650 by tonight" headline moved into
    /// the spent→projected bar.)
    private var todayOutlook: (text: String, icon: String, tint: Color, help: String)? {
        let dayName = Date().formatted(.dateTime.weekday(.wide))
        if !showEODBar, let e = todayEOD,
           IntelligenceFormatting.rangeIsActionable(e, spendSoFar: cached.todayCost) {
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
                HStack(spacing: 6) {
                    if let o = todayOutlook {
                        Chip(text: o.text, systemImage: o.icon, tint: o.tint, size: .compact)
                            .fixedSize()
                            .help(o.help)
                    }
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
                if showEODBar, let e = todayEOD {
                    SpendProgressBar(
                        spent: cached.todayCost,
                        projected: max(e.value, cached.todayCost),
                        projectedLabel: "≈\(IntelligenceFormatting.approxCost(max(e.value, cached.todayCost))) by tonight",
                        help: eodBarHelp(e)
                    )
                }
                if dailyBudgetEnabled, dailyBudgetUSD > 0 {
                    budgetBar
                }
            }
        }
    }

    /// Range + earned accuracy, demoted to hover — the bar itself shows
    /// only the one relationship (spent → projected).
    private func eodBarHelp(_ e: Estimate) -> String {
        var parts: [String] = [pacerCostExact(e.value)]
        if let band = e.interval80 {
            parts.append(IntelligenceFormatting.anchors(band))
        }
        if let r = record {
            parts.append("evening projections have landed within ~\(Int(r.medianAbsPctError.rounded()))% for you (\(r.days) days scored)")
        }
        return parts.joined(separator: " · ")
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
}

// MARK: - Spent → projected bar

/// "spent so far → projected total", in the same fill-on-a-track grammar
/// as the budget bar. Replaces the RangeBar, which layered four encodings
/// (track, range segment, point marker, reference tick) on an unlabeled
/// dollar axis and never read clearly even with a legend — the calibrated
/// range and accuracy live in the tooltip instead.
struct SpendProgressBar: View {
    let spent: Double
    /// Always ≥ spent (callers clamp).
    let projected: Double
    var projectedLabel: String
    var help: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("\(pacerCost(spent)) spent")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(projectedLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                let fraction = projected > 0 ? min(1, max(0, spent / projected)) : 0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.18))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
        .modifier(OptionalBarHelp(text: help))
    }
}

private struct OptionalBarHelp: ViewModifier {
    let text: String
    func body(content: Content) -> some View {
        if text.isEmpty {
            content
        } else {
            content.help(text)
        }
    }
}

// MARK: - Tile chrome

/// Shared tile surface for the strip — the PacerCard look with an eyebrow
/// header row (label + optional accessories) and optional whole-tile click
/// behavior with a hover ring.
struct StripTile<Header: View, Content: View>: View {
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
            // Greedy tail so every tile in the strip's HStack fills to the
            // tallest sibling — without it a short tile (Live) renders
            // visibly shorter than its neighbor and the row looks lopsided.
            // Same trick the old HeroTile used.
            Spacer(minLength: 0)
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
