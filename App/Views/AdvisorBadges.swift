import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Lightweight "things to notice today" badge strip, rendered in the
/// Dashboard page header's trailing slot (zero vertical cost — it used to
/// own a whole card row). Shows 1–2 hints from `UsageHints.compute` —
/// heavy premium-model share, low cache hit rate — plus engine notices,
/// when the underlying conditions are clearly true. Hidden entirely when
/// no hints fire, so the header stays calm in the common case.
struct AdvisorBadges: View {
    @Query private var todayAggregates: [DailyAggregate]
    @Query private var weekAggregates: [DailyAggregate]
    @Query(AdvisorBadges.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    /// Hints cached behind the scan-meta tick. Without this, the
    /// in-body `UsageHints.compute` call was re-iterating today + week
    /// aggregates on every body pass (hover, parent re-render, scroll)
    /// even when nothing had actually changed.
    @State private var cachedHints: [UsageHints.Hint] = []

    /// Engine-sourced notices (yesterday was one of your highest days; you're
    /// on your heaviest pace in weeks). Counting statements against the
    /// user's own history — they only fire when clearly notable, matching
    /// this card's hidden-when-calm contract.
    @Environment(\.usageEngine) private var engine
    @State private var engineHints: [EngineHint] = []

    struct EngineHint: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let detail: String
    }

    init() {
        let today = TokenSample.formatDate(Date())
        let cal = Calendar.current
        let weekAgo = TokenSample.formatDate(
            cal.date(byAdding: .day, value: -6, to: Date()) ?? Date()
        )
        _todayAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == today }
        )
        _weekAggregates = Query(
            filter: #Predicate<DailyAggregate> {
                $0.date >= weekAgo && $0.date <= today
            }
        )
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private func refreshCache() {
        cachedHints = UsageHints.compute(
            todayByModel: todayAggregates.map(Self.toTotals),
            thisWeekByModel: weekAggregates.map(Self.toTotals)
        )
    }

    private static func toTotals(_ row: DailyAggregate) -> UsageHints.ModelTotals {
        UsageHints.ModelTotals(
            model: row.model,
            costUSD: row.totalCostUSD,
            inputTokens: row.inputTokens,
            outputTokens: row.outputTokens,
            cacheReadTokens: row.cacheReadTokens
        )
    }

    var body: some View {
        // EmptyView'd entirely when no hints — kept inside a single
        // container so .onAppear/.onChange land in the view tree at
        // a stable identity. Without the wrapping Group, the
        // .onAppear-attached strip appears and disappears as
        // hints flip in/out, which (a) tears down + rebuilds the
        // SwiftData @Query subscriptions and (b) loses the
        // .onChange observer mid-tick.
        Group {
            if !cachedHints.isEmpty || !engineHints.isEmpty {
                HStack(spacing: 8) {
                    ForEach(engineHints) { hint in
                        engineBadge(hint)
                    }
                    ForEach(cachedHints.indices, id: \.self) { idx in
                        hintBadge(cachedHints[idx])
                    }
                }
            }
        }
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
        .task { await refreshEngineHints() }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshEngineHints() }
        }
    }

    /// Notable-only engine notices. Yesterday gets a counting statement when
    /// it ranked in the user's top few; today's pace fires only at the
    /// ladder's top rungs (≥85th percentile of their own days).
    private func refreshEngineHints() async {
        guard let engine else { return }
        var next: [EngineHint] = []
        if let y = await engine.yesterdayRank(), y.rankFromTop <= max(3, y.of / 10), y.of >= 14 {
            let weeks = max(1, Int((Double(y.of) / 7.0).rounded()))
            next.append(EngineHint(
                id: "yesterday-high",
                icon: "chart.bar.fill",
                tint: y.rankFromTop == 1 ? .orange : .secondary,
                title: "Yesterday: \(IntelligenceFormatting.ordinal(y.rankFromTop))-highest in \(weeks)w",
                detail: "\(pacerCostExact(y.cost)) — higher than \(y.of - y.rankFromTop) of your \(y.of) tracked days."))
        }
        let pace = await engine.ask(.pace)
        if !pace.isInsufficient, IntelligenceFormatting.ladderIndex(pace.value) >= 3 {
            let dayName = Date().formatted(.dateTime.weekday(.wide))
            next.append(EngineHint(
                id: "pace-heavy",
                icon: "speedometer",
                tint: .orange,
                title: pace.value >= 0.95 ? "Heaviest pace in weeks" : "One of your heavier days",
                detail: "Today's projected total sits at the \(Int((pace.value * 100).rounded()))th percentile of your \(dayName)s."))
        }
        engineHints = next
    }

    @ViewBuilder
    private func engineBadge(_ hint: EngineHint) -> some View {
        Chip(text: hint.title, systemImage: hint.icon, tint: hint.tint)
            .help(hint.detail)
    }

    @ViewBuilder
    private func hintBadge(_ hint: UsageHints.Hint) -> some View {
        Chip(text: shortTitle(for: hint), systemImage: icon(for: hint), tint: tint(for: hint))
            .help(detail(for: hint))
    }

    private func icon(for hint: UsageHints.Hint) -> String {
        switch hint {
        case .heavyPremiumShare: return "cpu"
        case .lowCacheHitRate: return "bolt.horizontal"
        }
    }

    private func tint(for hint: UsageHints.Hint) -> Color {
        switch hint {
        case .heavyPremiumShare: return .orange
        case .lowCacheHitRate: return .yellow
        }
    }

    private func shortTitle(for hint: UsageHints.Hint) -> String {
        switch hint {
        case .heavyPremiumShare:
            return "Mostly premium models today"
        case .lowCacheHitRate:
            return "Low cache hit rate"
        }
    }

    private func detail(for hint: UsageHints.Hint) -> String {
        switch hint {
        case .heavyPremiumShare(_, let cost):
            return "Sonnet 4.6 handles most coding tasks at a fraction of the per-token cost of Opus, Fable, or Mythos. Today's premium-model spend so far: \(pacerCost(cost))."
        case .lowCacheHitRate:
            return "Long-running sessions reuse cached system prompts. Closing Claude Code and starting fresh forces a re-cache."
        }
    }
}
