import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// "Today details" — token-flow breakdown for the current day. The Now
/// strip's Today tile carries the cost headline, so this card answers
/// the next-level question: where did those tokens come from? Input vs
/// output vs cache reads, how much cache writing happened, how many
/// distinct models the user touched.
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
            MetricTile(
                value: pacerTokens(totals.inputTokens),
                label: "input",
                tooltip: pacerTokensExact(totals.inputTokens)
            )
            MetricTile(
                value: pacerTokens(totals.outputTokens),
                label: "output",
                tooltip: pacerTokensExact(totals.outputTokens)
            )
            MetricTile(
                value: pacerTokens(totals.cacheReadTokens),
                label: "cache read",
                tooltip: pacerTokensExact(totals.cacheReadTokens)
            )
            MetricTile(value: "\(totals.distinctModels)", label: "models")
        }
    }

    /// Cache-utilization line. Headline is the standard cache hit rate
    /// (reads as a fraction of total cache traffic — reads + writes),
    /// which actually moves session-to-session unlike the older
    /// `read/(read+input)` definition that pegged at ~100%. Sub-line
    /// shows absolute read / written counts, reuse factor (how many
    /// times each written token paid off), and the dollar value the
    /// cache saved vs a hypothetical no-cache day.
    @ViewBuilder
    private var cacheRatio: some View {
        let r = totals.cacheHitRate
        let pctText = String(format: "%.1f%%", r * 100)
        let savings = totals.cacheSavingsUSD(snapshot: SampleCostCache.current())
        let written = totals.cacheCreation5mTokens + totals.cacheCreation1hTokens
        let reuse = totals.cacheReuseFactor
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
                if savings > 0 {
                    Text("saved \(pacerCost(savings))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                        .frame(minWidth: 88, alignment: .trailing)
                        .help("Saved \(pacerCostExact(savings)) by reusing cached prompts")
                }
            }
            HStack(spacing: 4) {
                // Indent past the icon column so the sub-line aligns
                // with the label rather than the icon.
                Spacer().frame(width: 21)
                Text(subline(read: totals.cacheReadTokens, written: written, reuse: reuse))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
            }
        }
    }

    /// "1.59B read · 31.3M written · 51× reuse" — the three numbers
    /// that together explain the headline hit rate. Reuse drops out
    /// when there were no writes (trivially infinite).
    private func subline(read: Int64, written: Int64, reuse: Double) -> String {
        let base = "\(pacerTokens(read)) read · \(pacerTokens(written)) written"
        guard reuse > 0 else { return base }
        let reuseText: String
        if reuse >= 10 {
            reuseText = String(format: "%.0f×", reuse)
        } else {
            reuseText = String(format: "%.1f×", reuse)
        }
        return "\(base) · \(reuseText) reuse"
    }
}

/// Sums across the day's per-model aggregate rows. Holds the rows
/// themselves (not just the column sums) so per-model pricing can be
/// applied for the savings calculation — a cross-model day priced at
/// a single average rate would mis-attribute Haiku/Opus savings.
private struct Totals {
    let rows: [DailyAggregate]
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreation5mTokens: Int64
    let cacheCreation1hTokens: Int64
    let totalCostUSD: Double
    let distinctModels: Int

    init(rows: [DailyAggregate]) {
        self.rows = rows
        self.inputTokens = rows.reduce(0) { $0 + $1.inputTokens }
        self.outputTokens = rows.reduce(0) { $0 + $1.outputTokens }
        self.cacheReadTokens = rows.reduce(0) { $0 + $1.cacheReadTokens }
        self.cacheCreation5mTokens = rows.reduce(0) { $0 + $1.cacheCreation5mTokens }
        self.cacheCreation1hTokens = rows.reduce(0) { $0 + $1.cacheCreation1hTokens }
        self.totalCostUSD = rows.reduce(0) { $0 + $1.totalCostUSD }
        self.distinctModels = Set(rows.map(\.model)).count
    }

    var isEmpty: Bool { inputTokens == 0 && outputTokens == 0 && cacheReadTokens == 0 }

    /// Standard cache hit rate: reads / (reads + writes). Replaces the
    /// older `reads/(reads+input)` definition that always pegged at
    /// ~100% because input is negligible next to cache_read for any
    /// real Claude Code session. This formula moves meaningfully —
    /// long agent runs that thrash the 1h cache window will visibly
    /// drop into the 80–95% range.
    var cacheHitRate: Double {
        let written = cacheCreation5mTokens + cacheCreation1hTokens
        let denom = Double(cacheReadTokens + written)
        guard denom > 0 else { return 0 }
        return Double(cacheReadTokens) / denom
    }

    /// How many times each cache-written token was read back. Tells
    /// you whether the cache writes paid for themselves — a 5m write
    /// costs 1.25× a fresh input token, so anything above 12.5× reuse
    /// is net-positive vs not caching.
    var cacheReuseFactor: Double {
        let written = cacheCreation5mTokens + cacheCreation1hTokens
        guard written > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(written)
    }

    /// Dollar savings vs. a hypothetical day where every input-side
    /// token (input + cache_read + cache_creation) was billed at the
    /// model's fresh-input rate. Output cost cancels out and is not
    /// included. Per-model so a mixed Opus/Haiku/Sonnet day prices
    /// each row at the right rate.
    ///
    /// Uses base (not above-200k) rates — daily aggregates lose the
    /// per-request tier boundary, so this is a display approximation.
    /// The dominant Claude Code message is under 200k, so the
    /// approximation is within a few percent of invoice-accurate.
    @MainActor
    func cacheSavingsUSD(snapshot: PricingTable.Snapshot) -> Double {
        var total: Double = 0
        for row in rows {
            guard let p = snapshot.pricing(for: row.model) else { continue }
            let inputRate = p.inputCostPerToken ?? 0
            let cacheReadRate = p.cacheReadInputTokenCost ?? 0
            let cache5mRate = p.cacheCreationInputTokenCost ?? 0
            let cache1hRate = p.cacheCreationInputTokenCostAbove1hr
                ?? p.cacheCreationInputTokenCost ?? 0
            let inputSide = row.inputTokens + row.cacheReadTokens
                + row.cacheCreation5mTokens + row.cacheCreation1hTokens
            let hypothetical = Double(inputSide) * inputRate
            let actual = Double(row.inputTokens) * inputRate
                + Double(row.cacheReadTokens) * cacheReadRate
                + Double(row.cacheCreation5mTokens) * cache5mRate
                + Double(row.cacheCreation1hTokens) * cache1hRate
            total += max(0, hypothetical - actual)
        }
        return total
    }
}
