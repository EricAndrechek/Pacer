import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// "Show me everything important without scrolling" — the topmost card
/// on the Dashboard. Three side-by-side tiles that answer the three
/// questions the user opens Pacer to ask:
///
///   1. How much have I spent today?
///   2. Am I going to hit the 5-hour limit?
///   3. Am I going to hit the 7-day limit?
///
/// Replaces the prior dashboard pattern of stacking TodaySummaryCard +
/// the gauges card on top of each other. Surfaces the same numbers with
/// stronger visual hierarchy: the hero number per tile, the "/ pace"
/// secondary number, a small chip that says behind/on/ahead/danger.
struct HeroStripCard: View {
    /// Optional click handler for the cost (Today) tile. When set, the
    /// tile reads as actionable (cursor + hover) and forwards to the
    /// caller — the dashboard wires this to opening today's day-detail
    /// modal so the hero strip doubles as the primary "drill into
    /// today" entry point.
    let onTodayTap: (() -> Void)?

    /// User's daily-cost notification toggle. Surfaced inside the
    /// cost tile as a budget progress bar when enabled — the user
    /// has opted into "I care about this number," so showing them
    /// visual feedback (not just an after-the-fact banner) is
    /// honest. When disabled, no bar — keeps the tile clean for
    /// users who haven't configured a budget.
    @AppStorage(PacerSettings.Key.notifyOnDailyCost, store: PacerSettings.store)
    private var dailyBudgetEnabled: Bool = false
    @AppStorage(PacerSettings.Key.dailyCostThresholdUSD, store: PacerSettings.store)
    private var dailyBudgetUSD: Double = 50

    init(onTodayTap: (() -> Void)? = nil) {
        self.onTodayTap = onTodayTap
        let todayString = TokenSample.formatDate(Date())
        let weekAgoString = TokenSample.formatDate(
            Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
        )
        _todayAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == todayString }
        )
        _weekAggregates = Query(
            filter: #Predicate<DailyAggregate> {
                $0.date >= weekAgoString && $0.date <= todayString
            }
        )
    }

    /// All today's per-model rollups. ≤ a handful of rows; iterating in
    /// body is sub-millisecond.
    @Query private var todayAggregates: [DailyAggregate]
    /// Last 7 calendar days for the "vs avg" trend chip on the cost
    /// tile. ≤ 50 rows.
    @Query private var weekAggregates: [DailyAggregate]
    /// Recent rate-limit samples — sized to cover both windows' worth
    /// of history for `BurnRate.project()` (the lookback default is
    /// 90 min, at 5-min OAuth cadence that's ~18 rows per window). 48
    /// covers ~2 hours of both windows together with headroom for
    /// status-line bursts that bypass the 5-min cadence.
    @Query(HeroStripCard.recentRateLimits) private var rateLimits: [RateLimitSample]
    /// Most-recent `extra_usage` sample. Only meaningful for Max-plan
    /// users who can exceed quota; nil for everyone else. fetchLimit
    /// = 1 keeps the materialization bounded.
    @Query(HeroStripCard.recentExtraUsage) private var extraUsages: [ExtraUsageSample]
    /// Scan-meta probe — used as the "data changed" tick that triggers
    /// the @State cache refresh. Per AGENTS.md performance invariants,
    /// every derived value heavier than O(N=10) lives in @State and is
    /// only recomputed when this value flips, NOT on every body pass.
    @Query(HeroStripCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    private static let recentRateLimits: FetchDescriptor<RateLimitSample> = {
        var d = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 48
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

    // MARK: - @State cache (refreshed on scan-meta tick)

    /// Snapshot of every derived value the body reads. Refreshed in
    /// `refreshCache()` from the @Query data; the body itself never
    /// iterates rate-limit rows or week aggregates.
    @State private var cached = Cached()

    private struct Cached {
        var todayCost: Double = 0
        var todayTokens: Int64 = 0
        var weekDeltaRatio: Double?
        var weekDeltaActiveDays: Int = 0
        var fiveHour: SampleSnapshot?
        var sevenDay: SampleSnapshot?
        var fiveHourBurn: BurnRate.Projection?
        var sevenDayBurn: BurnRate.Projection?
        /// Latest `extra_usage` value in USD. nil when Anthropic
        /// omitted the field; zero when we received it but it's at
        /// zero (no overage yet). Both render as "no chip"; we
        /// distinguish in the code path so we know whether to log.
        var extraUsageUSD: Double?
    }

    /// Sendable extract of the rate-limit row's display-relevant fields.
    /// SwiftData @Model classes aren't Sendable, so we copy what we
    /// need into a plain struct at refresh time.
    private struct SampleSnapshot {
        let window: String
        let usedPercentage: Double
        let resetsAt: Date?
    }

    private func refreshCache() {
        var next = Cached()
        next.todayCost = todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
        next.todayTokens = todayAggregates.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens
        }
        if let (ratio, activeDays) = computeWeekDelta() {
            next.weekDeltaRatio = ratio
            next.weekDeltaActiveDays = activeDays
        }
        if let s = rateLimits.first(where: { $0.window == "five_hour" }) {
            next.fiveHour = SampleSnapshot(
                window: s.window,
                usedPercentage: s.usedPercentage,
                resetsAt: s.resetsAt
            )
        }
        if let s = rateLimits.first(where: { $0.window == "seven_day" }) {
            next.sevenDay = SampleSnapshot(
                window: s.window,
                usedPercentage: s.usedPercentage,
                resetsAt: s.resetsAt
            )
        }
        next.fiveHourBurn = projection(forWindow: "five_hour")
        next.sevenDayBurn = projection(forWindow: "seven_day")
        if let latest = extraUsages.first {
            next.extraUsageUSD = latest.amountUSD
        }
        cached = next
    }

    private func computeWeekDelta() -> (ratio: Double, activeDays: Int)? {
        let todayString = TokenSample.formatDate(Date())
        var todayCost = 0.0
        var priorByDate: [String: Double] = [:]
        for r in weekAggregates {
            if r.date == todayString {
                todayCost += r.totalCostUSD
            } else {
                priorByDate[r.date, default: 0] += r.totalCostUSD
            }
        }
        let active = priorByDate.values.filter { $0 > 0.01 }
        guard !active.isEmpty else { return nil }
        let avg = active.reduce(0, +) / Double(active.count)
        guard avg > 0.01 else { return nil }
        return (todayCost / avg, active.count)
    }

    /// One-window burn-rate projection. Same algorithm as before,
    /// just moved out of the body so we can cache it.
    private func projection(forWindow window: String) -> BurnRate.Projection? {
        let samples = rateLimits
            .filter { $0.window == window }
            .map { BurnRate.Sample(sampledAt: $0.sampledAt, usedPercentage: $0.usedPercentage) }
        let resetsAt = rateLimits.first { $0.window == window }?.resetsAt
        return BurnRate.project(samples: samples, resetsAt: resetsAt)
    }

    var body: some View {
        HStack(spacing: 12) {
            costTile
            paceTile(
                label: "5-hour pace",
                sample: cached.fiveHour,
                burn: cached.fiveHourBurn,
                duration: 5 * 3600
            )
            paceTile(
                label: "7-day pace",
                sample: cached.sevenDay,
                burn: cached.sevenDayBurn,
                duration: 7 * 86400
            )
        }
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    // MARK: - Cost tile

    private var costTile: some View {
        HeroTile(label: "Today", onTap: onTodayTap) {
            VStack(alignment: .leading, spacing: 8) {
                Text(pacerCost(cached.todayCost))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 6) {
                    if let ratio = cached.weekDeltaRatio {
                        trendChip(ratio: ratio)
                    }
                    if let extra = cached.extraUsageUSD, extra > 0 {
                        // Max-plan overage. Tint orange (significant but
                        // not catastrophic — at Anthropic's metered
                        // rates a few dollars over isn't an emergency).
                        Chip(
                            text: "+\(pacerCost(extra)) over",
                            systemImage: "plus.forwardslash.minus",
                            tint: .orange,
                            size: .compact
                        )
                        .fixedSize()
                    }
                    Text("\(pacerTokens(cached.todayTokens)) tokens")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if dailyBudgetEnabled, dailyBudgetUSD > 0 {
                    budgetBar
                }
            }
        }
    }

    /// Progress bar showing today's cost as a fraction of the user's
    /// configured daily budget. Tints green (<80%), orange (≥80%),
    /// red (≥100%). The label says "$12 / $50 (24%)" — both raw and
    /// percentage so the user doesn't have to mental-math either
    /// side from the other.
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

    @ViewBuilder
    private func trendChip(ratio: Double) -> some View {
        let icon: String = ratio < 0.8 ? "arrow.down.right"
            : ratio < 1.2 ? "equal"
            : "arrow.up.right"
        let tint: Color = ratio < 0.8 ? .green
            : ratio < 1.5 ? .secondary
            : .orange
        let label: String = ratio >= 10 ? String(format: "%.0f×", ratio)
            : String(format: "%.1f×", ratio)
        Chip(text: label, systemImage: icon, tint: tint, size: .compact)
            .fixedSize()
    }

    // MARK: - Pace tile

    @ViewBuilder
    private func paceTile(
        label: String,
        sample: SampleSnapshot?,
        burn: BurnRate.Projection?,
        duration: TimeInterval
    ) -> some View {
        HeroTile(label: label) {
            if let s = sample, let resets = s.resetsAt {
                let pacePct = PaceMath.paceFraction(
                    now: Date(), resetsAt: resets, windowDuration: duration
                ) * 100
                let band = PaceBand(usedPct: s.usedPercentage, paceEndPct: pacePct)
                // Chip moved to its own row below the % line so it
                // can't ever wrap mid-word ("behi nd") when the tile
                // gets narrow. Layout: hero %, status row, optional
                // burn-rate forecast row.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(s.usedPercentage.rounded()))%")
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(color(for: band))
                            .lineLimit(1)
                        Text("/")
                            .font(.system(size: 18))
                            .foregroundStyle(.tertiary)
                        Text("\(Int(pacePct.rounded()))%")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        paceChip(band: band)
                        Text("resets \(pacerRelative(resets))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    burnRow(burn)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("—")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                    Text("collecting…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Optional burn-rate row inside a pace tile. Renders only when
    /// `BurnRate.project()` returned a result with a positive slope.
    /// When a limit hit is projected within the window, prefix with
    /// "→ limit at HH:MM" so the user sees the wall-clock impact at a
    /// glance; otherwise just the rate. Tint red when projecting a
    /// pre-reset hit.
    @ViewBuilder
    private func burnRow(_ projection: BurnRate.Projection?) -> some View {
        if let projection, projection.slopePercentPerHour > 0 {
            let rateText = "+\(formatSlope(projection.slopePercentPerHour))%/hr"
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(projection.willHitLimitBeforeReset ? Color.red : Color.secondary)
                if let projected = projection.projectedFullAt {
                    Text("\(rateText) · limit \(pacerRelative(projected, style: .short))")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text(rateText)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            // Empty placeholder of the same vertical footprint so the
            // tile height matches its sibling whose burn rate did
            // surface — otherwise the HStack's equal-height layout
            // would stretch the shorter tile and look misaligned.
            Text(" ")
                .font(.system(size: 11))
                .opacity(0)
        }
    }

    /// Round burn-rate slope for display: integer when ≥10, one
    /// decimal place otherwise. Avoids the "0.428%/hr" precision that
    /// looks more authoritative than the linear extrapolation deserves.
    private func formatSlope(_ pctPerHour: Double) -> String {
        if pctPerHour >= 10 {
            return String(format: "%.0f", pctPerHour)
        } else {
            return String(format: "%.1f", pctPerHour)
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
        // Lock the chip's width to its content so it can't get squeezed
        // and wrap. Layout above uses a Spacer/HStack that would
        // otherwise let the chip's text wrap when the tile narrows.
        .fixedSize()
    }

    private func color(for band: PaceBand) -> Color {
        switch band {
        case .green:  return .green
        case .white:  return .primary
        case .yellow: return .yellow
        case .red:    return .red
        }
    }
}

/// One tile in the hero strip. Cards-of-cards: each tile reuses the
/// app's standard PacerCard surface so spacing/radius/stroke stay
/// consistent with the rest of the dashboard.
///
/// When `onTap` is non-nil the tile becomes a hover-reactive button
/// — same surface, but with a subtle hover ring + pointing-hand
/// cursor so it reads as actionable. The tile remains a passive
/// surface when no callback is wired.
private struct HeroTile<Content: View>: View {
    let label: String
    var onTap: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        let surface = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Eyebrow(text: label)
                Spacer()
                if onTap != nil {
                    Image(systemName: "arrow.up.right.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1.0 : 0.0)
                }
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(PacerDesign.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: PacerDesign.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
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
            .help("Open today's breakdown")
            .accessibilityHint("Opens today's detailed breakdown")
        } else {
            surface
        }
    }
}
