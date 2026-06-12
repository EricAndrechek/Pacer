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

    /// The shared intelligence engine — owns the end-of-day projection, so
    /// this card no longer learns its own hour-of-day profile.
    @Environment(\.usageEngine) private var engine
    /// Engine answers, refreshed when the engine refits: the projection, the
    /// typical-day band (the range bar's reference tick), and the engine's
    /// earned evening accuracy (the footer).
    @State private var eodEstimate: Estimate?
    @State private var typical: Estimate?
    @State private var record: UsageIntelligenceEngine.TrackRecord?
    @State private var trainingDays = 0

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

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    /// Re-ask the engine for the end-of-day answers.
    private func refreshEOD() async {
        guard let engine else { return }
        eodEstimate = await engine.ask(.projectedCost(.today))
        typical = await engine.ask(.typicalUsage)
        record = await engine.eveningTrackRecord()
        trainingDays = await engine.trainingDayCount()
    }

    /// Hint under the projected-EOD tile: the calibrated range when it's
    /// decision-useful, an honest "early read" while it's still too wide,
    /// the naive fallback's caveat otherwise.
    private var eodHint: String? {
        guard let e = eodEstimate, !e.isInsufficient else { return "if rate holds" }
        guard let band = e.interval80, e.value > 0 else { return nil }
        guard IntelligenceFormatting.rangeIsActionable(e, spendSoFar: todayCostSoFar) else {
            return "early read — wide range"
        }
        return "likely \(pacerCost(max(band.lowerBound, todayCostSoFar)))–\(pacerCost(band.upperBound))"
    }

    /// Once the range is decision-useful: the projection in the context of
    /// the user's own typical range — a Weather-style range bar (calibrated
    /// 80% band as the segment, point marker, tick at the typical day) with
    /// the asymmetric anchors beneath. Hidden while it's still early; the
    /// projected-EOD tile's "early read" hint carries that state.
    @ViewBuilder private var projectionRow: some View {
        if let e = eodEstimate, IntelligenceFormatting.rangeIsActionable(e, spendSoFar: todayCostSoFar),
           let band = e.interval80 {
            VStack(alignment: .leading, spacing: 5) {
                RangeBar(domain: projectionDomain(e),
                         range: IntelligenceFormatting.outward(band),
                         point: e.value,
                         reference: (typical?.isInsufficient ?? true) ? nil : typical?.value)
                    .help(rangeBarHelp)
                Text("today: \(IntelligenceFormatting.anchors(band))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func projectionDomain(_ e: Estimate) -> ClosedRange<Double> {
        var hi = e.value * 1.2
        if let band = e.interval80 { hi = max(hi, band.upperBound * 1.05) }
        if let t = typical, !t.isInsufficient, let t80 = t.interval80 { hi = max(hi, t80.upperBound) }
        return 0...max(hi, 1)
    }

    private var rangeBarHelp: String {
        var s = "Today's projected total with its 80% range"
        if let t = typical, !t.isInsufficient {
            s += " · tick = your typical \(Date().formatted(.dateTime.weekday(.wide))) (\(pacerCost(t.value)))"
        }
        return s
    }

    /// The engine's earned accuracy, in plain frequency terms — only shown
    /// once there's a real track record.
    @ViewBuilder private var accuracyFooter: some View {
        if let r = record {
            Text("Evening projections have landed within ~\(Int(r.medianAbsPctError.rounded()))% for you · \(r.days) days scored")
        } else if trainingDays > 0 && eodEstimate != nil {
            Text("Projection still calibrating — \(trainingDays) days observed")
        }
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

    /// End-of-day cost projection — the engine's answer (its per-user
    /// clock↔shape router, validated to never be worse than the simple pace
    /// baseline and better in the evening). Falls back to the naive
    /// "(last-hour rate) × (hours left)" only when the engine can't answer
    /// yet (cold start, no spend today).
    private func projectedEndOfDay(stats: LiveStats) -> Double {
        // Floor at spend-so-far: the engine refits up to ~20s behind the live
        // rollup, and a projection below money already displayed reads broken.
        if let e = eodEstimate, !e.isInsufficient { return max(e.value, todayCostSoFar) }
        let now = Date()
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        let hoursLeft = max(0, endOfDay.timeIntervalSince(now) / 3600.0)
        return todayCostSoFar + stats.costLastHour * hoursLeft
    }

    var body: some View {
        let s = stats
        PacerCard("Live activity", trailing: { freshnessChip(stats: s) }) {
            if s.sampleCount == 0 {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    metricGrid(stats: s)
                    projectionRow
                }
            }
        } footer: {
            accuracyFooter
        }
        // The pricing cache needs an explicit reload when the user
        // toggles cost mode — `effectiveCostUSD` reads it. Body re-eval
        // alone won't trigger that, so we keep this side-effect.
        .onChange(of: costModeRaw) { _, _ in
            Task { await SampleCostCache.reload() }
        }
        // The EOD estimate refreshes when the engine refits — not per render.
        .task { await refreshEOD() }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshEOD() }
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
                hint: "\(stats.sampleCount) sample\(stats.sampleCount == 1 ? "" : "s")",
                tooltip: pacerCostExact(stats.costLastHour)
            )
            MetricTile(
                value: pacerTokens(stats.tokensLastHour),
                label: "last hour tokens",
                tooltip: pacerTokensExact(stats.tokensLastHour)
            )
            MetricTile(
                value: pacerCost(todayCostSoFar),
                label: "today so far",
                tooltip: pacerCostExact(todayCostSoFar)
            )
            MetricTile(
                value: pacerCost(projectedEndOfDay(stats: stats)),
                label: "projected EOD",
                hint: eodHint,
                tooltip: pacerCostExact(projectedEndOfDay(stats: stats))
            )
        }
    }
}
