import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// "This 7 days vs the 7 before that" — a behavioral signal the
/// dashboard otherwise lacks. The hero strip's trend chip uses the
/// same week, but as a single ratio; this card breaks it down into
/// cost, tokens, active days and cost per million tokens, then splits
/// the week's cost by priced part (the shared `PacerCostBreakdownView`,
/// with each part's tokens and the cache hit rate) so the user can see
/// *why* the trend chip moved.
///
/// Sources from `DailyAggregate` rolled up into two 7-day buckets.
/// We pull a 14-day predicate from SwiftData; the in-view group is
/// over ≤70 rows (14 × ~5 models/day) so it stays sub-millisecond.
struct WeeklyComparisonCard: View {
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
    @Query(WeeklyComparisonCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    /// Cached totals refreshed on scan-meta tick. Per AGENTS.md, every
    /// derived value heavier than O(N=10) belongs behind a @State
    /// cache — the in-body group-by used to run on every body pass.
    @State private var cachedThisWeek = WeekTotals()
    @State private var cachedLastWeek = WeekTotals()

    init(scopeAccountId: String? = nil) {
        // 14-day window covering this week + last week. Predicate is
        // anchored on the date string format (`YYYY-MM-DD`) so it
        // sorts/compares lexicographically and uses the existing
        // `[\.date]` index on DailyAggregate.
        let now = Date()
        let cal = Calendar.current
        let lowerBound = cal.date(byAdding: .day, value: -13, to: now) ?? now
        let lowerStr = TokenSample.formatDate(lowerBound)
        _globalAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date >= lowerStr }
        )
        let acct = scopeAccountId ?? UsageScope.noAccountSentinel
        _scopedAggregates = Query(
            filter: #Predicate<AccountDailyAggregate> {
                $0.date >= lowerStr && $0.accountId == acct
            }
        )
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private struct WeekTotals {
        var cost: Double = 0
        var tokens = TokenBreakdown.zero
        /// The week's cost by priced part, with each part's tokens (#225),
        /// summed from the same rows as `cost` and `tokens`.
        var breakdown = CostBreakdown.zero
        var distinctDates: Set<String> = []

        /// All five parts (#215). This was input + output, which left out the
        /// cache reads and writes that are most of a week's tokens.
        var totalTokens: Int64 { tokens.all }
        var activeDays: Int { distinctDates.filter { _ in true }.count }
        /// Cost per million tokens, every token counted — the blended rate
        /// the week paid. Cache reads are most of the volume and the
        /// cheapest part, so this sits well under a model's input rate; it
        /// was per million input + output once, which priced the week's
        /// cache bill against a fraction of its tokens.
        var costPerMillionTokens: Double? {
            guard totalTokens > 0 else { return nil }
            return cost / (Double(totalTokens) / 1_000_000)
        }
    }

    /// Refresh the @State caches from the @Query rows. Called on
    /// .onAppear and every scan-meta tick. The in-body view code only
    /// reads `cachedThisWeek` / `cachedLastWeek` — never iterates
    /// `aggregates` directly.
    private func refreshCache() {
        let now = Date()
        let cal = Calendar.current
        let todayStr = TokenSample.formatDate(now)
        let weekAgoStr = TokenSample.formatDate(
            cal.date(byAdding: .day, value: -6, to: now) ?? now
        )
        let twoWeeksAgoStr = TokenSample.formatDate(
            cal.date(byAdding: .day, value: -13, to: now) ?? now
        )

        var this = WeekTotals()
        var last = WeekTotals()
        for row in aggregates {
            let bucket: WeekTotalsKeyPath
            if row.date >= weekAgoStr && row.date <= todayStr {
                bucket = .thisWeek
            } else if row.date >= twoWeeksAgoStr && row.date < weekAgoStr {
                bucket = .lastWeek
            } else {
                continue
            }
            func add(to t: inout WeekTotals) {
                t.cost += row.totalCostUSD
                t.tokens += row.tokens
                t.breakdown += row.costBreakdown
                t.distinctDates.insert(row.date)
            }
            switch bucket {
            case .thisWeek: add(to: &this)
            case .lastWeek: add(to: &last)
            }
        }
        cachedThisWeek = this
        cachedLastWeek = last
    }

    private enum WeekTotalsKeyPath { case thisWeek, lastWeek }

    var body: some View {
        // Read here as well as inside `PacerCard`'s stored closure (#140).
        let _ = (cachedThisWeek, cachedLastWeek)
        PacerCard("This week") {
            if cachedThisWeek.cost == 0 && cachedLastWeek.cost == 0 {
                Text("No usage in the last 14 days. Once Pacer has data for both this week and the prior week, comparisons appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                content(thisWeek: cachedThisWeek, lastWeek: cachedLastWeek)
            }
        }
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
        // The scope is an input to the cache like the data is: without this
        // the card kept the previous account after a switch until a scan
        // ingested something, which on an idle machine may be never (#141).
        .onChange(of: scope.accountId) { _, _ in refreshCache() }
    }

    @ViewBuilder
    private func content(thisWeek: WeekTotals, lastWeek: WeekTotals) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            comparisonGrid(thisWeek: thisWeek, lastWeek: lastWeek)
            if PacerCostBreakdownView.hasContent(thisWeek.breakdown) {
                PacerCostBreakdownView(thisWeek.breakdown)
            }
        }
    }

    private func comparisonGrid(thisWeek: WeekTotals, lastWeek: WeekTotals) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                count: 4
            ),
            alignment: .leading,
            spacing: 12
        ) {
            MetricTile(
                value: pacerCost(thisWeek.cost),
                label: "cost",
                hint: deltaHint(this: thisWeek.cost, last: lastWeek.cost, formatter: pacerCost),
                tooltip: deltaTooltip(this: thisWeek.cost, last: lastWeek.cost, exact: pacerCostExact)
            )
            MetricTile(
                value: pacerTokens(thisWeek.totalTokens),
                label: "tokens",
                hint: deltaHint(
                    this: Double(thisWeek.totalTokens),
                    last: Double(lastWeek.totalTokens),
                    formatter: { pacerTokens(Int64($0)) }
                ),
                tooltip: deltaTooltip(
                    this: Double(thisWeek.totalTokens),
                    last: Double(lastWeek.totalTokens),
                    exact: { pacerTokensExact(Int64($0)) }
                )
            )
            MetricTile(
                value: "\(thisWeek.distinctDates.count)",
                label: "active days",
                hint: lastWeek.distinctDates.isEmpty
                    ? nil
                    : "vs \(lastWeek.distinctDates.count) prior"
            )
            // No cache-hit hint under this tile any more: the breakdown below
            // prints the week's hit rate in its own row.
            if let cpmt = thisWeek.costPerMillionTokens {
                MetricTile(
                    value: pacerCost(cpmt),
                    label: "per 1M tokens",
                    tooltip: pacerCostExact(cpmt)
                )
            } else {
                MetricTile(
                    value: "—",
                    label: "per 1M tokens",
                    hint: nil
                )
            }
        }
    }

    /// Compact "↑ 12% (vs $4.20)" / "↓ 8% (vs $5.40)" / "first week"
    /// hint string. Returns nil when the prior week is zero (a "first
    /// week of usage" case) — the % delta would be infinite.
    private func deltaHint(
        this: Double,
        last: Double,
        formatter: (Double) -> String
    ) -> String? {
        guard last > 0 else {
            return this > 0 ? "first 7 days" : nil
        }
        let ratio = this / last
        let pct = abs((ratio - 1) * 100)
        let arrow: String = ratio >= 1.05 ? "↑" : ratio <= 0.95 ? "↓" : "≈"
        return String(format: "%@ %.0f%% (vs %@)", arrow, pct, formatter(last))
    }

    /// Both endpoints of the week-over-week comparison, exact —
    /// "$4,203.11 → $14,602.55". The tile already shows this week
    /// compact as its value and last week compact inside `deltaHint`,
    /// so the one thing hover can still add is the pair at full
    /// precision, in the order the change happened. Falls back to this
    /// week alone when there is no prior week, matching `deltaHint`'s
    /// own "first 7 days" case.
    private func deltaTooltip(
        this: Double,
        last: Double,
        exact: (Double) -> String
    ) -> String {
        guard last > 0 else { return exact(this) }
        return "\(exact(last)) → \(exact(this))"
    }
}
