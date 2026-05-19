import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// "What's happening right now" — token & cost burn rate over the last
/// hour, plus a projection for end-of-day. Helps catch a runaway
/// session early ("oh I just burned through $5 in 20 minutes").
///
/// Reads `TokenSample` rows from the last hour. With cursor-based
/// scanning Pacer writes near-realtime, so this card moves visibly
/// while Claude Code is actively running.
struct LiveActivityCard: View {
    @Query private var recentSamples: [TokenSample]
    @Query private var todayAggregates: [DailyAggregate]
    /// Most-recent sample (any age). When the last-hour set is empty
    /// this lets us say "last activity 3h ago" instead of a flat
    /// "no samples" — much more useful when the user comes back to
    /// the dashboard after a break.
    @Query(LiveActivityCard.latestSampleProbe) private var latestSamples: [TokenSample]

    init() {
        let cutoff = Date().addingTimeInterval(-3600)  // 1h
        _recentSamples = Query(
            filter: #Predicate<TokenSample> { $0.sampledAt >= cutoff },
            sort: \.sampledAt,
            order: .reverse
        )
        let today = TokenSample.formatDate(Date())
        _todayAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == today }
        )
    }

    private static let latestSampleProbe: FetchDescriptor<TokenSample> = {
        var d = FetchDescriptor<TokenSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 1
        return d
    }()

    private struct LiveStats {
        var tokensLastHour: Int64 = 0
        var costLastHour: Double = 0
        var sampleCount: Int = 0
        var lastSampleAt: Date?
        var hasFreshActivity: Bool {
            lastSampleAt.map { Date().timeIntervalSince($0) < 600 } ?? false
        }
    }

    @AppStorage(PacerSettings.Key.costMode, store: PacerSettings.store)
    private var costModeRaw: String = CostMode.auto.rawValue

    /// Derived synchronously from `recentSamples` so the first render
    /// already shows the real metric grid. The previous @State + onAppear
    /// pattern flashed the empty state for one frame on each tab switch,
    /// reflowing all cards below.
    private var stats: LiveStats {
        var s = LiveStats()
        let mode = CostMode(rawValue: costModeRaw) ?? .auto
        for sample in recentSamples {
            s.tokensLastHour += sample.inputTokens + sample.outputTokens + sample.cacheReadTokens
            // Single shared helper — same one DayDetail / TodayTimeline
            // / CSVExporter use. Replaces the per-card pricing-snapshot
            // dance with a process-wide cache warmed at app launch.
            s.costLastHour += sample.effectiveCostUSD(mode: mode)
            s.sampleCount += 1
            if sample.sampledAt > (s.lastSampleAt ?? .distantPast) {
                s.lastSampleAt = sample.sampledAt
            }
        }
        return s
    }

    private var todayCostSoFar: Double {
        todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
    }

    /// "(hourly rate) × (hours left in day)" projection. Bounded by
    /// wall-clock so a 10-minute spike at midnight doesn't extrapolate
    /// to nonsense.
    private func projectedEndOfDay(stats: LiveStats) -> Double {
        let now = Date()
        let cal = Calendar.current
        let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        let hoursLeft = max(0, endOfDay.timeIntervalSince(now) / 3600.0)
        return todayCostSoFar + stats.costLastHour * hoursLeft
    }

    var body: some View {
        let s = stats
        PacerCard("Live activity", trailing: { freshnessChip(stats: s) }) {
            if s.sampleCount == 0 {
                emptyState
            } else {
                metricGrid(stats: s)
            }
        }
        // The pricing cache needs an explicit reload when the user
        // toggles cost mode — `effectiveCostUSD` reads it. Body re-eval
        // alone won't trigger that, so we keep this side-effect.
        .onChange(of: costModeRaw) { _, _ in
            Task { await SampleCostCache.reload() }
        }
    }

    @ViewBuilder
    private func freshnessChip(stats: LiveStats) -> some View {
        if stats.hasFreshActivity {
            Chip(text: "live", systemImage: "bolt.fill", tint: .yellow, size: .compact)
        } else if let last = stats.lastSampleAt {
            Text("last sample \(pacerRelative(last))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let latest = latestSamples.first {
            VStack(alignment: .leading, spacing: 4) {
                Text("No traffic in the last hour.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Last sample \(pacerRelative(latest.sampledAt)) — \(pacerShortModel(latest.model)).")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text("No samples yet. This card will light up as Claude Code activity hits the store.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func metricGrid(stats: LiveStats) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                count: 4
            ),
            alignment: .leading,
            spacing: 12
        ) {
            MetricTile(
                value: pacerCost(stats.costLastHour),
                label: "last hour cost",
                hint: "\(stats.sampleCount) sample\(stats.sampleCount == 1 ? "" : "s")"
            )
            MetricTile(
                value: pacerTokens(stats.tokensLastHour),
                label: "last hour tokens"
            )
            MetricTile(
                value: pacerCost(todayCostSoFar),
                label: "today so far"
            )
            MetricTile(
                value: pacerCost(projectedEndOfDay(stats: stats)),
                label: "projected EOD",
                hint: "if rate holds"
            )
        }
    }
}
