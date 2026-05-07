import SwiftUI
import SwiftData
import PacerCore

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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    metricGrid
                    if totals.cacheHitRatio > 0 {
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

    @ViewBuilder
    private var cacheRatio: some View {
        let pct = Int((totals.cacheHitRatio * 100).rounded())
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 13))
            Text("Cache hit ratio")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            // Background bar with filled progress, percent at right.
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 6)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * totals.cacheHitRatio, height: 6)
                }
                .frame(height: 6)
            }
            .frame(maxWidth: 220)
            Text("\(pct)%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
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
