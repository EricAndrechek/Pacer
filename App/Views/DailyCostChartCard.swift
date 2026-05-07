import SwiftUI
import SwiftData
import Charts
import PacerCore

/// 30-day rolling bar chart of daily cost in USD. Pulls
/// `DailyAggregate` rows ordered descending by date, takes the last
/// 30 days, sums per date (across models). Cost numbers are
/// validated end-to-end against `bun x ccusage daily --json` —
/// see `CCusageGroundTruthTests.dailyCostsMatchCapturedCcusageSnapshot`.
struct DailyCostChartCard: View {
    @Query(sort: \DailyAggregate.date, order: .reverse)
    private var aggregates: [DailyAggregate]
    @Query(DailyCostChartCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    /// Hover/selection target. macOS Charts binds the X-value on
    /// pointer move; we look it up in `dailyTotals` to render the
    /// callout. Nil → no hover, hide overlay.
    @State private var selectedDate: String?
    @State private var cached = Cached()

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    /// `dailyTotals` plus the precomputed annotation set. Without the
    /// cached set, `shouldAnnotate` re-sorted the full series for
    /// every bar (30 bars × O(n log n)) on every body re-eval.
    private struct Cached {
        var dailyTotals: [DailyTotal] = []
        var annotateDates: Set<String> = []
        var totalCost: Double = 0
    }

    private var dailyTotals: [DailyTotal] { cached.dailyTotals }

    private func refreshCache() {
        // Group by date (trim model dimension), sort ascending so the
        // chart reads left-to-right oldest → today.
        let grouped = Dictionary(grouping: aggregates, by: \.date)
        let sortedDates = grouped.keys.sorted()
        let lastN = sortedDates.suffix(30)
        let totals = lastN.map { date -> DailyTotal in
            let rows = grouped[date] ?? []
            return DailyTotal(
                date: date,
                cost: rows.reduce(0) { $0 + $1.totalCostUSD },
                tokens: rows.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens }
            )
        }
        let topThree = Set(
            totals.sorted { $0.cost > $1.cost }.prefix(3).map(\.date)
        )
        cached = Cached(
            dailyTotals: totals,
            annotateDates: topThree,
            totalCost: totals.reduce(0) { $0 + $1.cost }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("30-day cost")
                    .font(.title2.weight(.semibold))
                Spacer()
                if cached.totalCost > 0 {
                    Text("total: \(formatCost(cached.totalCost))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if dailyTotals.isEmpty {
                Text("No daily aggregates yet.")
                    .foregroundStyle(.secondary)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 200)
            } else {
                chart
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    @ChartContentBuilder
    private var chartContent: some ChartContent {
        ForEach(dailyTotals) { d in
            BarMark(
                x: .value("Date", d.date),
                y: .value("Cost", d.cost)
            )
            .foregroundStyle(barColor(for: d.cost))
            .annotation(position: .top, alignment: .center, spacing: 2) {
                if shouldAnnotate(d) {
                    Text(formatCost(d.cost))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            chartContent
            // Highlight the hovered bar with a subtle outline rule so
            // the callout has something to point at.
            if let selectedDate, dailyTotals.contains(where: { $0.date == selectedDate }) {
                RuleMark(x: .value("Selected", selectedDate))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .annotation(position: .top, alignment: .center, spacing: 4) {
                        if let row = dailyTotals.first(where: { $0.date == selectedDate }) {
                            calloutView(row)
                        }
                    }
            }
        }
        .frame(height: 200)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let dollars = value.as(Double.self) {
                        Text(formatCost(dollars))
                            .font(.system(size: 9, design: .monospaced))
                    }
                }
            }
        }
        .chartXAxis {
            // Showing every 5th label keeps the axis readable at 30 days.
            AxisMarks(values: stridedDates(every: 5)) { value in
                AxisValueLabel {
                    if let date = value.as(String.self) {
                        Text(shortDate(date))
                            .font(.system(size: 9, design: .monospaced))
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
    }

    @ViewBuilder
    private func calloutView(_ row: DailyTotal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.date)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(formatCost(row.cost))
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
    }

    /// Pick every Nth date from the rendered set so the x-axis isn't
    /// crowded. We read indices off `dailyTotals`, not a date math
    /// expression, so a partial-data window (e.g. only 7 days) still
    /// renders sensible labels.
    private func stridedDates(every n: Int) -> [String] {
        guard !dailyTotals.isEmpty else { return [] }
        return stride(from: 0, to: dailyTotals.count, by: n)
            .map { dailyTotals[$0].date }
    }

    /// Annotate only the top few cost days so the chart isn't a wall
    /// of overlapping labels. The set is precomputed in `refreshCache`
    /// so each bar's annotation is an O(1) lookup, not an O(n log n)
    /// re-sort per bar.
    private func shouldAnnotate(_ d: DailyTotal) -> Bool {
        cached.annotateDates.contains(d.date)
    }

    private func barColor(for cost: Double) -> Color {
        // Keep the visual story simple: any data is the same accent.
        // Color-by-magnitude can come later once notification thresholds
        // (M7) are wired and we want the chart to reinforce them.
        cost > 0 ? .accentColor : .accentColor.opacity(0.3)
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 100 { return String(format: "$%.0f", usd) }
        if usd >= 10  { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }

    /// `2026-04-30` → `04-30`. Keeps year out of the axis labels at
    /// this density; the user knows which month-year they're looking
    /// at from context.
    private func shortDate(_ ymd: String) -> String {
        guard ymd.count == 10 else { return ymd }
        return String(ymd.suffix(5))
    }
}

private struct DailyTotal: Identifiable {
    var id: String { date }
    let date: String
    let cost: Double
    let tokens: Int64
}
