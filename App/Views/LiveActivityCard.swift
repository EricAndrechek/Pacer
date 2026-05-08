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
    /// Lightweight signal that the scan loop just ran; drives cache
    /// invalidation without forcing a fetch of recentSamples on every
    /// body refresh.
    @Query(LiveActivityCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cachedStats = LiveStats()

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

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

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

    private var stats: LiveStats { cachedStats }

    @MainActor
    private func refreshStats() {
        var s = LiveStats()
        let mode = CostMode(rawValue: costModeRaw) ?? .auto
        for sample in recentSamples {
            s.tokensLastHour += sample.inputTokens + sample.outputTokens + sample.cacheReadTokens
            // Single shared helper — same one DayDetail / TodayTimeline
            // / CSVExporter use. Replaces the per-card pricing-snapshot
            // dance with a process-wide cache warmed at app launch.
            s.costLastHour += sample.effectiveCostUSD(mode: mode)
            s.sampleCount += 1
            if s.lastSampleAt == nil || sample.sampledAt > s.lastSampleAt! {
                s.lastSampleAt = sample.sampledAt
            }
        }
        cachedStats = s
    }

    private var todayCostSoFar: Double {
        todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
    }

    /// "(hourly rate) × (hours left in day)" projection. Bounded by
    /// wall-clock so a 10-minute spike at midnight doesn't extrapolate
    /// to nonsense.
    private var projectedEndOfDay: Double {
        let now = Date()
        let cal = Calendar.current
        let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        let hoursLeft = max(0, endOfDay.timeIntervalSince(now) / 3600.0)
        return todayCostSoFar + stats.costLastHour * hoursLeft
    }

    var body: some View {
        PacerCard("Live activity", trailing: { freshnessChip }) {
            if stats.sampleCount == 0 {
                emptyState
            } else {
                metricGrid
            }
        }
        .onAppear { refreshStats() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshStats() }
        // When cost mode changes the cache needs to refresh too —
        // ensureLoaded is cheap if pricing is already in memory.
        .onChange(of: costModeRaw) { _, _ in
            Task {
                await SampleCostCache.reload()
                await MainActor.run { refreshStats() }
            }
        }
    }

    @ViewBuilder
    private var freshnessChip: some View {
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Last sample \(pacerRelative(latest.sampledAt)) — \(pacerShortModel(latest.model)).")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text("No samples yet. This card will light up as Claude Code activity hits the store.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var metricGrid: some View {
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
                value: pacerCost(projectedEndOfDay),
                label: "projected EOD",
                hint: "if rate holds"
            )
        }
    }
}
