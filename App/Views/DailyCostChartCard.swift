import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// The last 30 days as a chart. "This month" is its own card under it
/// (`MonthOutlookCard`): the two were one card for a round, but they are
/// different periods, and the owner chose two cards.
///
/// The chart is the shared `PacerStackedPartChart`: each bar stacked by
/// priced part (#225), coloured by part only, with a hover card over the
/// chart that gives the day's cost, tokens, breakdown and top models. One
/// encoding per chart: the split by model lives on the Models tab. Click a
/// bar to drill into the per-day modal (same view the History tab's heatmap
/// opens).
struct DailyCostChartCard: View {
    /// Optional callback fired when the user clicks a bar. Wiring is
    /// at the parent (DashboardView), so each surface can decide whether to
    /// open the day modal locally or stay quiet.
    let onDayTap: ((String) -> Void)?

    init(scopeAccountId: String? = nil, onDayTap: ((String) -> Void)? = nil) {
        self.onDayTap = onDayTap
        // Scope the @Query to the chart's display window. Card renders
        // exactly 30 days; the prior unbounded query materialized every
        // DailyAggregate row (730+ on a 2-year DB) just so refreshDerived
        // could `.suffix(30)` after grouping. With the predicate the
        // fetch is 30 × N_models rows (~150 typical), using the
        // existing `(date)` index for a range scan.
        let cutoffString = TokenSample.formatDate(
            Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        )
        _globalAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date >= cutoffString },
            sort: \DailyAggregate.date,
            order: .reverse
        )
        let acct = scopeAccountId ?? UsageScope.noAccountSentinel
        _scopedAggregates = Query(
            filter: #Predicate<AccountDailyAggregate> {
                $0.date >= cutoffString && $0.accountId == acct
            },
            sort: \AccountDailyAggregate.date,
            order: .reverse
        )
    }

    @Query private var globalAggregates: [DailyAggregate]
    /// The same rollup sliced to one account. Which of the two is
    /// rendered is the scope switch; the card's layout does not change.
    @Query private var scopedAggregates: [AccountDailyAggregate]
    @State private var scope = UsageScope.shared

    /// What the card renders: every account, or one. Both queries are
    /// live, so switching is a re-read rather than a recompute.
    private var aggregates: [DailyRow] {
        scope.isAll
            ? globalAggregates.map(\.dailyRow)
            : scopedAggregates.map(\.dailyRow)
    }
    /// Singleton-row probe — fires once per scan cycle. Drives the
    /// `Derived` cache refresh so the bucketing runs at most once per
    /// cycle instead of on every body render.
    @Query(ScanMetaFetchDescriptor.scanCompletedProbe)
    private var scanMeta: [ClaudeCodeMeta]

    @State private var cachedDerived = Derived()

    /// The bars and the header's total. Each bucket carries its breakdown
    /// and top models, built here, so hovering a bar reads precomputed
    /// numbers and never re-sums the rows.
    private struct Derived {
        var buckets: [PacerChartBucket] = []
        var totalCost: Double = 0
    }

    private func refreshDerived() {
        var builder = PacerChartBucketBuilder()
        for row in aggregates {
            builder.add(row.date, row.costBreakdown, model: row.model)
        }
        let buckets = builder.buckets(last: 30)
        cachedDerived = Derived(
            buckets: buckets,
            // The chart's days, not every row fetched: the header total is
            // the last 30 bars' sum.
            totalCost: buckets.reduce(0) { $0 + $1.total }
        )
    }

    var body: some View {
        // Read here as well as inside `PacerCard`'s stored closures (#140).
        let d = cachedDerived
        PacerCard("Last 30 days", trailing: {
            // The hovered day's numbers are in the card floating over the
            // chart, so this slot no longer swaps on hover and the header
            // never moves.
            if d.totalCost > 0 {
                Text("total \(pacerCost(d.totalCost))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(pacerCostExact(d.totalCost))
            }
        }) {
            if d.buckets.isEmpty {
                Text("No usage in the last 30 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 220)
            } else {
                PacerStackedPartChart(d.buckets, kind: .day, onTap: onDayTap)
                    .accessibilityLabel("Daily cost by part over the last 30 days")
                    .accessibilityHint(onDayTap != nil ? "Click a bar to drill into that day" : "")
            }
        }
        .onAppear { refreshDerived() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshDerived() }
        // The scope is a refresh trigger like any other. Without it the cache
        // holds the previous account's numbers until the *next scan cycle*
        // happens to fire — which on an idle machine is seven to ten seconds,
        // and looks exactly like a very slow render rather than a stale one.
        .onChange(of: scope.accountId) { _, _ in refreshDerived() }
    }
}
