import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Lightweight "things to notice today" card. Renders 1–2 hints from
/// `UsageHints.compute` — heavy premium-model share, low cache hit rate — when
/// the underlying conditions are clearly true. Hidden entirely when no
/// hints fire, so the dashboard stays calm in the common case.
struct AdvisorCard: View {
    @Query private var todayAggregates: [DailyAggregate]
    @Query private var weekAggregates: [DailyAggregate]
    @Query(AdvisorCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    /// Hints cached behind the scan-meta tick. Without this, the
    /// in-body `UsageHints.compute` call was re-iterating today + week
    /// aggregates on every body pass (hover, parent re-render, scroll)
    /// even when nothing had actually changed.
    @State private var cachedHints: [UsageHints.Hint] = []

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
        // .onAppear-attached PacerCard appears and disappears as
        // hints flip in/out, which (a) tears down + rebuilds the
        // SwiftData @Query subscriptions and (b) loses the
        // .onChange observer mid-tick.
        Group {
            if !cachedHints.isEmpty {
                PacerCard("Notice") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(cachedHints.indices, id: \.self) { idx in
                            hintRow(cachedHints[idx])
                            if idx != cachedHints.indices.last {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    @ViewBuilder
    private func hintRow(_ hint: UsageHints.Hint) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: hint))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint(for: hint))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: hint))
                    .font(.callout)
                    .fontWeight(.medium)
                Text(detail(for: hint))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
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

    private func title(for hint: UsageHints.Hint) -> String {
        switch hint {
        case .heavyPremiumShare(let pct, _):
            return "Heavy premium-model day · \(Int((pct * 100).rounded()))% of today"
        case .lowCacheHitRate(let ratio, _):
            return "Low cache hit rate · \(Int((ratio * 100).rounded()))%"
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
