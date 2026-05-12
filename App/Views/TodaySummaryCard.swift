import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// "Today details" — token-flow breakdown for the current day. Sits
/// below the HeroStripCard which already shows today's cost; this card
/// answers the next-level question: where did those tokens come from?
/// Input vs output vs cache reads, how much cache writing happened,
/// how many distinct models the user touched.
///
/// Renamed from the original `TodaySummaryCard` (which had the cost
/// headline) — the redesign promotes today's cost into the hero strip,
/// so the body of this card focuses on the breakdown the hero strip
/// can't show.
struct TodayDetailsCard: View {
    @Query private var aggregates: [DailyAggregate]

    init() {
        let today = TokenSample.formatDate(Date())
        _aggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == today }
        )
    }

    private var totals: Totals { Totals(rows: aggregates) }

    var body: some View {
        PacerCard("Today's traffic", trailing: {
            Text(TokenSample.formatDate(Date()))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }) {
            if totals.isEmpty {
                Text("No usage logged today yet. Pacer will write within seconds of any Claude Code activity.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    metricGrid
                    if totals.cacheReadTokens > 0 {
                        cacheRatio
                    }
                }
            }
        }
    }

    /// Four-up tile row: input, output, cache read, models. Wraps to
    /// 2x2 on narrow widths via `LazyVGrid`.
    private var metricGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                count: 4
            ),
            alignment: .leading,
            spacing: 12
        ) {
            MetricTile(value: pacerTokens(totals.inputTokens), label: "input")
            MetricTile(value: pacerTokens(totals.outputTokens), label: "output")
            MetricTile(value: pacerTokens(totals.cacheReadTokens), label: "cache read")
            MetricTile(value: "\(totals.distinctModels)", label: "models")
        }
    }

    /// Cache-utilization line. Headline is the share of input bytes
    /// that were served from cache rather than re-billed at full input
    /// price. Sub-line shows the absolute cached / total counts so the
    /// user can see how much they actually saved (the % alone reads as
    /// "100%" for almost any heavily-cached workload).
    ///
    /// Display uses one decimal so a typical Claude Code session at
    /// 99.8% reads honestly instead of being floored or rounded to 100%.
    @ViewBuilder
    private var cacheRatio: some View {
        let r = totals.cacheHitRatio
        let pctText = String(format: "%.1f%%", r * 100)
        let totalReadlike = totals.cacheReadTokens + totals.inputTokens
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .foregroundStyle(.tint)
                    .font(.body)
                Text("Cache hit rate")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 6)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * r, height: 6)
                    }
                    .frame(height: 6)
                }
                .frame(maxWidth: 220)
                Text(pctText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
            HStack(spacing: 4) {
                // Indent past the icon column so the sub-line aligns
                // with the label rather than the icon.
                Spacer().frame(width: 21)
                Text("\(pacerTokens(totals.cacheReadTokens)) cached / \(pacerTokens(totalReadlike)) read")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
            }
        }
    }
}

/// Sums across the day's per-model aggregate rows.
private struct Totals {
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreation5mTokens: Int64
    let cacheCreation1hTokens: Int64
    let totalCostUSD: Double
    let distinctModels: Int

    init(rows: [DailyAggregate]) {
        self.inputTokens = rows.reduce(0) { $0 + $1.inputTokens }
        self.outputTokens = rows.reduce(0) { $0 + $1.outputTokens }
        self.cacheReadTokens = rows.reduce(0) { $0 + $1.cacheReadTokens }
        self.cacheCreation5mTokens = rows.reduce(0) { $0 + $1.cacheCreation5mTokens }
        self.cacheCreation1hTokens = rows.reduce(0) { $0 + $1.cacheCreation1hTokens }
        self.totalCostUSD = rows.reduce(0) { $0 + $1.totalCostUSD }
        self.distinctModels = Set(rows.map(\.model)).count
    }

    var isEmpty: Bool { inputTokens == 0 && outputTokens == 0 && cacheReadTokens == 0 }

    /// Cache reads / (cache reads + non-cache input). High ratios mean
    /// prompt caching is doing its job.
    var cacheHitRatio: Double {
        let denom = Double(cacheReadTokens + inputTokens)
        guard denom > 0 else { return 0 }
        return Double(cacheReadTokens) / denom
    }
}
