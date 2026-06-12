import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// The dashboard's top strip — the money story in one row:
///
///   1. **Today** — spend so far, the day's outlook chip, tokens, budget.
///   2. **This month** (wide) — month-to-date spend, the engine's
///      month-end projection with its calibrated range bar, and the pace
///      context (avg per active day, days left).
///
/// The month tile absorbs the old bottom-of-page MonthlyForecastCard, so
/// the trajectory the user actually plans around sits at the top instead
/// of below six cards of detail — and nothing on the page repeats it.
/// The rate-limit story stays in the full-width pace-chart card directly
/// below (Eric prefers the wide side-by-side charts there).
struct SpendOverviewStrip: View {
    /// Open today's day-detail modal (Today tile click).
    let onTodayTap: (() -> Void)?

    @AppStorage(PacerSettings.Key.notifyOnDailyCost, store: PacerSettings.store)
    private var dailyBudgetEnabled: Bool = false
    @AppStorage(PacerSettings.Key.dailyCostThresholdUSD, store: PacerSettings.store)
    private var dailyBudgetUSD: Double = 50

    @Query private var todayAggregates: [DailyAggregate]
    /// Current month's per-model daily rollups, for the month tile's facts.
    @Query private var monthAggregates: [DailyAggregate]
    @Query(SpendOverviewStrip.recentExtraUsage) private var extraUsages: [ExtraUsageSample]
    @Query(SpendOverviewStrip.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    @Environment(\.usageEngine) private var engine

    init(onTodayTap: (() -> Void)? = nil) {
        self.onTodayTap = onTodayTap
        let todayString = TokenSample.formatDate(Date())
        _todayAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == todayString }
        )
        let cal = Calendar.current
        let now = Date()
        let firstOfMonth = cal.dateInterval(of: .month, for: now)?.start ?? now
        let lowerStr = TokenSample.formatDate(firstOfMonth)
        _monthAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date >= lowerStr }
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

    // MARK: - Caches (refreshed on scan tick / engine recompute)

    @State private var cached = Facts()

    private struct Facts {
        var todayCost: Double = 0
        var todayTokens: Int64 = 0
        var extraUsageUSD: Double?
        // Month facts (the old MonthlyForecastCard.MonthFacts).
        var monthSoFar: Double = 0
        var averageDailyCost: Double = 0
        var daysWithData: Int = 0
        var daysInMonth: Int = 30
        var dayOfMonth: Int = 1
        var hasMonthData: Bool = false
    }

    @State private var todayEOD: Estimate?
    @State private var monthProjection: Estimate?
    @State private var pacePercentile: Double?
    @State private var paceVsNow: Double?
    @State private var heldLadder: Int?

    private func refreshFacts() {
        var next = Facts()
        next.todayCost = todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
        next.todayTokens = todayAggregates.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens
        }
        if let latest = extraUsages.first {
            next.extraUsageUSD = latest.amountUSD
        }
        let cal = Calendar.current
        let now = Date()
        var byDate: [String: Double] = [:]
        for row in monthAggregates {
            byDate[row.date, default: 0] += row.totalCostUSD
        }
        next.monthSoFar = byDate.values.reduce(0, +)
        let active = byDate.values.filter { $0 > 0 }
        next.daysWithData = active.count
        next.averageDailyCost = active.isEmpty ? 0 : active.reduce(0, +) / Double(active.count)
        next.daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        next.dayOfMonth = cal.component(.day, from: now)
        next.hasMonthData = !active.isEmpty
        cached = next
    }

    private func refreshEngine() async {
        guard let engine else { return }
        todayEOD = await engine.ask(.projectedCost(.today))
        monthProjection = await engine.ask(.projectedCost(.thisMonth))
        let vsNow = await engine.ask(.paceVsNow)
        paceVsNow = vsNow.isInsufficient ? nil : vsNow.value
        let pace = await engine.ask(.pace)
        pacePercentile = pace.isInsufficient ? nil : pace.value
        if let p = pacePercentile {
            heldLadder = IntelligenceFormatting.heldIndex(p, held: heldLadder)
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            costTile
            monthTile
                .frame(maxWidth: .infinity)
        }
        .onAppear { refreshFacts() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshFacts() }
        .task { await refreshEngine() }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshEngine() }
        }
    }

    // MARK: - Today tile

    /// One-line outlook chip — evening → "≈$650 by tonight"; midday
    /// off-pace → "1.8× usual Friday spend"; on pace → "on your usual
    /// Friday pace"; else the percentile ladder phrase.
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
        .frame(width: 300)
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

    // MARK: - Month tile

    /// "June · 18 days left" — the month tile's header caption.
    private var monthCaption: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM"
        let daysLeft = max(0, cached.daysInMonth - cached.dayOfMonth)
        return "\(fmt.string(from: Date())) · \(daysLeft) day\(daysLeft == 1 ? "" : "s") left"
    }

    /// "↑ 18% above pace" — the engine's projection vs a pure linear
    /// forward-fill of the current run rate. Only meaningful past the
    /// first few days.
    private var monthPaceHint: String? {
        guard let p = monthProjection, !p.isInsufficient else { return nil }
        guard cached.dayOfMonth >= 3 else { return "if rate holds" }
        let purePace = cached.monthSoFar / Double(cached.dayOfMonth) * Double(cached.daysInMonth)
        guard purePace > 0.01 else { return "if rate holds" }
        let ratio = p.value / purePace
        if ratio > 1.05 {
            return String(format: "↑ %.0f%% above pace", (ratio - 1) * 100)
        }
        if ratio < 0.95 {
            return String(format: "↓ %.0f%% below pace", (1 - ratio) * 100)
        }
        return "on pace"
    }

    private var monthTile: some View {
        StripTile(
            label: "This month",
            header: {
                Text(monthCaption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        ) {
            if cached.hasMonthData {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(pacerCost(cached.monthSoFar)).help(pacerCostExact(cached.monthSoFar))
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let p = monthProjection, !p.isInsufficient {
                            Chip(
                                text: "≈\(IntelligenceFormatting.approxCost(p.value)) by month end",
                                systemImage: "chart.line.uptrend.xyaxis",
                                tint: .secondary,
                                size: .compact
                            )
                            .fixedSize()
                            .help(monthProjectionHelp(p))
                        }
                    }
                    Spacer(minLength: 0)
                    monthRangeBar
                    Text(monthDetailCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("Not enough data yet — a projection appears once Pacer has seen some usage this month.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func monthProjectionHelp(_ p: Estimate) -> String {
        var parts = [pacerCostExact(p.value)]
        if let band = p.interval80 {
            parts.append(IntelligenceFormatting.anchors(band))
        }
        if let hint = monthPaceHint { parts.append(hint) }
        return parts.joined(separator: " · ")
    }

    /// "avg $112 per active day (11) · ↑ 18% above pace"
    private var monthDetailCaption: String {
        var parts = [
            "avg \(pacerCost(cached.averageDailyCost)) per active day (\(cached.daysWithData))"
        ]
        if let hint = monthPaceHint { parts.append(hint) }
        return parts.joined(separator: " · ")
    }

    /// The month projection in context: track spans zero → just past the
    /// band; tick = spent so far; segment = the calibrated 80% range;
    /// marker = the projection. Suppressed while the engine's projection
    /// momentarily trails the live spend (would read broken).
    @ViewBuilder private var monthRangeBar: some View {
        if let p = monthProjection, !p.isInsufficient, let band = p.interval80,
           p.value >= cached.monthSoFar * 0.98 {
            let hi = max(band.upperBound * 1.05, p.value * 1.15)
            let shown = IntelligenceFormatting.outward(band)
            RangeBar(domain: 0...max(hi, 1),
                     range: shown,
                     point: p.value,
                     reference: cached.monthSoFar,
                     lowerLabel: pacerCost(shown.lowerBound),
                     upperLabel: pacerCost(shown.upperBound),
                     referenceLegend: "spent so far")
                .help("Month's likely range (80%), dot = projection · tick = spent so far (\(pacerCost(cached.monthSoFar)))")
        }
    }
}

// MARK: - Tile chrome

/// Shared tile surface for the strip — the PacerCard look with an eyebrow
/// header row (label + optional accessories) and optional whole-tile click
/// behavior with a hover ring.
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
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
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
