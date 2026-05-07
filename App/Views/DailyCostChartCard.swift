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

    private var dailyTotals: [DailyTotal] {
        // Group by date (trim model dimension), sort ascending so the
        // chart reads left-to-right oldest → today.
        let grouped = Dictionary(grouping: aggregates, by: \.date)
        let sortedDates = grouped.keys.sorted()
        // Take the most-recent 30 entries from the ascending-sorted
        // unique dates. Fewer-than-30 days of data is normal on a
        // fresh install; the chart just renders shorter.
        let lastN = sortedDates.suffix(30)
        return lastN.map { date in
            let rows = grouped[date] ?? []
            return DailyTotal(
                date: date,
                cost: rows.reduce(0) { $0 + $1.totalCostUSD },
                tokens: rows.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens }
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("30-day cost")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let total = dailyTotals.map(\.cost).reduce(0, +) as Double?,
                   total > 0 {
                    Text("total: \(formatCost(total))")
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
    /// of overlapping labels. Sorts descending and takes the top 3.
    private func shouldAnnotate(_ d: DailyTotal) -> Bool {
        let topThree = Set(
            dailyTotals.sorted { $0.cost > $1.cost }.prefix(3).map(\.date)
        )
        return topThree.contains(d.date)
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
