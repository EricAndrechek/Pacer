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

    @State private var selectedDate: String?

    private struct Derived {
        let dailyTotals: [DailyTotal]
        let annotateDates: Set<String>
        let totalCost: Double
    }

    private var derived: Derived {
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
        let topThree = Set(totals.sorted { $0.cost > $1.cost }.prefix(3).map(\.date))
        return Derived(
            dailyTotals: totals,
            annotateDates: topThree,
            totalCost: totals.reduce(0) { $0 + $1.cost }
        )
    }

    var body: some View {
        let d = derived
        PacerCard("Last 30 days", trailing: {
            // Hover swaps "total $X.X" for the selected day's date + cost
            // — surfacing the info up here means the chart's plot area
            // never has to expand to fit a callout, so the chart stops
            // jumping in height when the user moves the pointer over
            // bars. Same trick is applied in MonthlyChartCard.
            if let selectedDate, let row = d.dailyTotals.first(where: { $0.date == selectedDate }) {
                HStack(spacing: 8) {
                    Text(row.date)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(pacerCost(row.cost))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            } else if d.totalCost > 0 {
                Text("total \(pacerCost(d.totalCost))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }) {
            if d.dailyTotals.isEmpty {
                Text("No daily aggregates yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(height: 200)
            } else {
                chart(annotateDates: d.annotateDates, totals: d.dailyTotals)
            }
        }
    }

    private func chart(annotateDates: Set<String>, totals: [DailyTotal]) -> some View {
        Chart {
            ForEach(totals) { d in
                BarMark(
                    x: .value("Date", d.date),
                    y: .value("Cost", d.cost)
                )
                .foregroundStyle(barColor(for: d.cost))
                .cornerRadius(2)
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    if annotateDates.contains(d.date) {
                        Text(pacerCost(d.cost))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Selected-date marker is just a thin dashed rule now —
            // no annotation. The selection callout lives in the card
            // header (see body) so the chart's plot area stays a fixed
            // size regardless of hover state.
            if let selectedDate, totals.contains(where: { $0.date == selectedDate }) {
                RuleMark(x: .value("Selected", selectedDate))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(height: 200)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let dollars = value.as(Double.self) {
                        Text(pacerCost(dollars))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: stridedDates(every: 5, totals: totals)) { value in
                AxisValueLabel {
                    if let date = value.as(String.self) {
                        Text(shortDate(date))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
    }

    private func stridedDates(every n: Int, totals: [DailyTotal]) -> [String] {
        guard !totals.isEmpty else { return [] }
        return stride(from: 0, to: totals.count, by: n)
            .map { totals[$0].date }
    }

    private func barColor(for cost: Double) -> Color {
        cost > 0 ? .accentColor : .accentColor.opacity(0.3)
    }

    /// `2026-04-30` → `04-30`. Year out of axis labels at this density
    /// since the user knows their context.
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
