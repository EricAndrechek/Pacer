import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// "This 7 days vs the 7 before that" — a behavioral signal the
/// dashboard otherwise lacks. The hero strip's trend chip uses the
/// same week, but as a single ratio; this card breaks it down into
/// cost, tokens, active days, and cache-hit-rate so the user can see
/// *why* the trend chip moved.
///
/// Sources from `DailyAggregate` rolled up into two 7-day buckets.
/// We pull a 14-day predicate from SwiftData; the in-view group is
/// over ≤70 rows (14 × ~5 models/day) so it stays sub-millisecond.
struct WeeklyComparisonCard: View {
    @Query private var aggregates: [DailyAggregate]
    @Query(WeeklyComparisonCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    /// Cached totals refreshed on scan-meta tick. Per AGENTS.md, every
    /// derived value heavier than O(N=10) belongs behind a @State
    /// cache — the in-body group-by used to run on every body pass.
    @State private var cachedThisWeek = WeekTotals()
    @State private var cachedLastWeek = WeekTotals()

    init() {
        // 14-day window covering this week + last week. Predicate is
        // anchored on the date string format (`YYYY-MM-DD`) so it
        // sorts/compares lexicographically and uses the existing
        // `[\.date]` index on DailyAggregate.
        let now = Date()
        let cal = Calendar.current
        let lowerBound = cal.date(byAdding: .day, value: -13, to: now) ?? now
        let lowerStr = TokenSample.formatDate(lowerBound)
        _aggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date >= lowerStr }
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
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var cacheReadTokens: Int64 = 0
        var distinctDates: Set<String> = []

        var totalTokens: Int64 { inputTokens + outputTokens + cacheReadTokens }
        var activeDays: Int { distinctDates.filter { _ in true }.count }
        /// cacheRead / (cacheRead + nonCacheInput). Same definition the
        /// TodayDetailsCard uses; the per-message Claude API price for
        /// cached reads is ~10% of fresh input, so this is the dominant
        /// efficiency lever.
        var cacheHitRatio: Double {
            let denom = Double(cacheReadTokens + inputTokens)
            guard denom > 0 else { return 0 }
            return Double(cacheReadTokens) / denom
        }
        /// Cost per million tokens — orientation-invariant productivity
        /// metric. Numbers in the $1–$15 range are typical for Claude
        /// Code workloads (varies by model + cache hit rate).
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
                t.inputTokens += row.inputTokens
                t.outputTokens += row.outputTokens
                t.cacheReadTokens += row.cacheReadTokens
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
    }

    @ViewBuilder
    private func content(thisWeek: WeekTotals, lastWeek: WeekTotals) -> some View {
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
                hint: deltaHint(this: thisWeek.cost, last: lastWeek.cost, formatter: pacerCost)
            )
            MetricTile(
                value: pacerTokens(thisWeek.totalTokens),
                label: "tokens",
                hint: deltaHint(
                    this: Double(thisWeek.totalTokens),
                    last: Double(lastWeek.totalTokens),
                    formatter: { pacerTokens(Int64($0)) }
                )
            )
            MetricTile(
                value: "\(thisWeek.distinctDates.count)",
                label: "active days",
                hint: lastWeek.distinctDates.isEmpty
                    ? nil
                    : "vs \(lastWeek.distinctDates.count) prior"
            )
            if let cpmt = thisWeek.costPerMillionTokens {
                MetricTile(
                    value: pacerCost(cpmt),
                    label: "per 1M tokens",
                    hint: cacheHitHint(thisWeek)
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

    /// "82% cache hits" — only when there's enough data and only when
    /// cache-read is meaningfully present (>5% of input).
    private func cacheHitHint(_ t: WeekTotals) -> String? {
        let r = t.cacheHitRatio
        guard r > 0.05 else { return nil }
        return String(format: "%.0f%% cache hits", r * 100)
    }
}
