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
    /// Hour buckets for "recent" activity. Previously this card
    /// queried every `TokenSample` in the last hour and called
    /// `effectiveCostUSD(mode:)` per row to compute the rate — fine on
    /// a quiet day, but on an active session with hundreds of samples
    /// per hour this re-walked them on every scan tick. The hourly
    /// rollup is keyed `(date, hour, model)` with cost already
    /// applied; summing the two most-recent hour buckets is a stable
    /// rolling-rate approximation (the window slides between exactly
    /// 1 hour at the top of the hour and ~2 hours just before the
    /// next rollover). The exact 60-minute precision the old query
    /// gave isn't load-bearing — this card is a "what's the
    /// hour-scale burn rate" indicator, not a billing report.
    @Query private var recentHourlyRows: [HourlyAggregate]
    @Query private var todayAggregates: [DailyAggregate]
    /// Most-recent sample (any age). When the recent set is empty this
    /// lets us say "last activity 3h ago" instead of a flat "no
    /// samples" — much more useful when the user comes back to the
    /// dashboard after a break. fetchLimit=1 keeps it cheap.
    @Query(LiveActivityCard.latestSampleProbe) private var latestSamples: [TokenSample]

    init() {
        // Two-hour window covers the current hour bucket plus the
        // previous one, which together always include a full
        // "last hour" worth of samples (the precise span depends on
        // where in the current hour we are). The cutoff is computed
        // by hour boundary so the predicate maps cleanly to the
        // rollup's date+hour keying.
        let now = Date()
        let cal = Calendar.current
        let currentHourStart = cal.date(
            bySettingHour: cal.component(.hour, from: now),
            minute: 0,
            second: 0,
            of: now
        ) ?? now
        let twoHoursAgoStart = cal.date(byAdding: .hour, value: -1, to: currentHourStart) ?? now
        // Predicate is "row's hour-start >= twoHoursAgoStart"; expressed
        // via the (date, hour) key range to avoid a sampledAt predicate
        // on a derived column. Today + (possibly) yesterday for the
        // midnight-crossing case.
        let todayString = TokenSample.formatDate(now)
        let yesterdayString = TokenSample.formatDate(twoHoursAgoStart)
        let lowestHour = cal.component(.hour, from: twoHoursAgoStart)
        if todayString == yesterdayString {
            // Same day: a simple (date == today, hour >= lowestHour).
            _recentHourlyRows = Query(
                filter: #Predicate<HourlyAggregate> {
                    $0.date == todayString && $0.hour >= lowestHour
                }
            )
        } else {
            // Midnight cross: today's hour-0/1 buckets plus yesterday's
            // hour-23 bucket. Express as union via OR — both legs use
            // the `(date, hour)` index.
            _recentHourlyRows = Query(
                filter: #Predicate<HourlyAggregate> {
                    $0.date == todayString
                    || ($0.date == yesterdayString && $0.hour >= lowestHour)
                }
            )
        }
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

    /// Cost mode is read here purely to drive the
    /// `SampleCostCache.reload()` side effect below — the data path
    /// no longer touches `effectiveCostUSD(mode:)` (cost is baked into
    /// HourlyAggregate at recompute time). Other views that still
    /// call the per-sample helper (e.g. `ProjectDetailView`'s
    /// Subprojects card) rely on this global reload, so it stays.
    @AppStorage(PacerSettings.Key.costMode, store: PacerSettings.store)
    private var costModeRaw: String = CostMode.auto.rawValue

    /// Derived synchronously from the hourly rollup so the first render
    /// already shows real numbers. Cost is the recomputer's stored
    /// value — no per-render `effectiveCostUSD(mode:)` calls, no
    /// pricing lookups on the body path. `lastSampleAt` comes from the
    /// fetchLimit=1 probe; sampleCount is summed from the same buckets
    /// the rate metric uses (recomputer writes it on every upsert).
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
