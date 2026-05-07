import SwiftUI
import SwiftData
import Charts
import PacerCore

/// "All time" view — lifetime totals, monthly trend, the activity
/// heatmap, and most expensive days. Reads from `DailyAggregate` (the
/// canonical roll-up; pre-summed, so no per-row cost calc here).
///
/// Order: lifetime hero → 26-week heatmap → monthly bar chart → top
/// expensive days table.
struct HistoryView: View {
    @State private var selectedDay: SelectedDay?

    struct SelectedDay: Identifiable {
        let date: String
        var id: String { date }
    }

    var body: some View {
        PageScaffold("History", subtitle: "Lifetime view of your usage.") {
            LifetimeSummaryCard()
            HeatmapCard { dayKey in
                selectedDay = SelectedDay(date: dayKey)
            }
            MonthlyChartCard()
            TopDaysCard()
        }
        .sheet(item: $selectedDay) { sel in
            DayDetailView(date: sel.date)
        }
    }
}

// MARK: - Lifetime summary

private struct LifetimeSummaryCard: View {
    @Query(sort: \DailyAggregate.date, order: .reverse) private var aggregates: [DailyAggregate]

    private struct Totals {
        var cost: Double = 0
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var distinctDays: Int = 0
        var distinctModels: Int = 0
        var firstDate: String?
    }

    private var totals: Totals {
        var t = Totals()
        var dates = Set<String>()
        var models = Set<String>()
        var minDate: String?
        for row in aggregates {
            t.cost += row.totalCostUSD
            t.input += row.inputTokens
            t.output += row.outputTokens
            t.cacheRead += row.cacheReadTokens
            dates.insert(row.date)
            models.insert(row.model)
            if minDate == nil || row.date < minDate! { minDate = row.date }
        }
        t.distinctDays = dates.count
        t.distinctModels = models.count
        t.firstDate = minDate
        return t
    }

    var body: some View {
        let t = totals
        PacerCard("Lifetime", trailing: {
            if let first = t.firstDate {
                Text("since \(first)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }) {
            if t.distinctDays == 0 {
                Text("No history yet — start using Claude Code and Pacer will catch up.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                        count: 6
                    ),
                    alignment: .leading,
                    spacing: 12
                ) {
                    MetricTile(value: pacerCost(t.cost), label: "cost", size: .hero)
                    MetricTile(value: pacerTokens(t.input), label: "input")
                    MetricTile(value: pacerTokens(t.output), label: "output")
                    MetricTile(value: pacerTokens(t.cacheRead), label: "cache read")
                    MetricTile(value: "\(t.distinctDays)", label: "active days")
                    MetricTile(value: "\(t.distinctModels)", label: "models")
                }
            }
        }
    }
}

// MARK: - Monthly bar chart

private struct MonthlyChartCard: View {
    @Query(sort: \DailyAggregate.date, order: .reverse) private var aggregates: [DailyAggregate]

    @State private var selectedMonth: String?

    private struct MonthBucket: Identifiable {
        let month: String  // YYYY-MM
        let cost: Double
        var id: String { month }
    }

    private var monthly: [MonthBucket] {
        var totals: [String: Double] = [:]
        for row in aggregates {
            guard row.date.count >= 7 else { continue }
            let key = String(row.date.prefix(7))
            totals[key, default: 0] += row.totalCostUSD
        }
        let sorted = totals.keys.sorted()
        let last12 = sorted.suffix(12)
        return last12.map { MonthBucket(month: $0, cost: totals[$0] ?? 0) }
    }

    var body: some View {
        let total = monthly.reduce(0) { $0 + $1.cost }
        PacerCard("Last 12 months", trailing: {
            if let selectedMonth, let row = monthly.first(where: { $0.month == selectedMonth }) {
                HStack(spacing: 8) {
                    Text(longMonth(row.month))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(pacerCost(row.cost))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            } else if !monthly.isEmpty {
                Text("total \(pacerCost(total))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }) {
            if monthly.isEmpty {
                Text("No monthly history yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(height: 200)
            } else {
                chart
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(monthly) { m in
                BarMark(
                    x: .value("Month", m.month),
                    y: .value("Cost", m.cost)
                )
                .foregroundStyle(.tint)
                .cornerRadius(2)
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    if m.cost > 0 && m.month != selectedMonth {
                        Text(pacerCost(m.cost))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Selection callout moved to the card header so the chart
            // doesn't reflow on hover. Just keep a thin dashed rule
            // to mark the selected bar.
            if selectedMonth != nil,
               let m = selectedMonth,
               monthly.contains(where: { $0.month == m }) {
                RuleMark(x: .value("Selected", m))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(height: 220)
        .chartXSelection(value: $selectedMonth)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(pacerCost(d))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let m = value.as(String.self) {
                        Text(shortMonth(m))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// `2026-04` → `Apr` (or `Apr '26` when the visible window straddles
    /// a year boundary). Previously this rendered as "Apr 26" which
    /// looked like the 26th of April rather than April 2026 — confusing
    /// when the cells are big.
    private func shortMonth(_ ym: String) -> String {
        guard ym.count == 7,
              let yearInt = Int(ym.prefix(4)),
              let monthInt = Int(ym.suffix(2))
        else { return ym }
        let names = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        guard monthInt >= 1 && monthInt <= 12 else { return ym }
        let yearsInWindow = Set(monthly.map { String($0.month.prefix(4)) }).count
        if yearsInWindow > 1 {
            return "\(names[monthInt - 1]) ’\(String(format: "%02d", yearInt % 100))"
        }
        return names[monthInt - 1]
    }

    private func longMonth(_ ym: String) -> String {
        guard ym.count == 7,
              let yearInt = Int(ym.prefix(4)),
              let monthInt = Int(ym.suffix(2))
        else { return ym }
        let names = ["January","February","March","April","May","June","July","August","September","October","November","December"]
        guard monthInt >= 1 && monthInt <= 12 else { return ym }
        return "\(names[monthInt - 1]) \(yearInt)"
    }
}

// MARK: - Top days

private struct TopDaysCard: View {
    @Query(sort: \DailyAggregate.date, order: .reverse) private var aggregates: [DailyAggregate]

    private struct DayRow: Identifiable {
        let date: String
        let cost: Double
        let tokens: Int64
        var id: String { date }
    }

    private var topRows: [DayRow] {
        var byDate: [String: (cost: Double, tokens: Int64)] = [:]
        for row in aggregates {
            var v = byDate[row.date] ?? (0, 0)
            v.cost += row.totalCostUSD
            v.tokens += row.inputTokens + row.outputTokens + row.cacheReadTokens
            byDate[row.date] = v
        }
        let rows = byDate.map { DayRow(date: $0.key, cost: $0.value.cost, tokens: $0.value.tokens) }
        return rows.sorted { $0.cost > $1.cost }.prefix(10).map { $0 }
    }

    var body: some View {
        PacerCard("Most expensive days") {
            if topRows.isEmpty {
                Text("No data yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                let maxCost = topRows.map(\.cost).max() ?? 1
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(topRows.enumerated()), id: \.element.id) { idx, row in
                        topRow(idx: idx, row: row, maxCost: maxCost)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func topRow(idx: Int, row: DayRow, maxCost: Double) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("#\(idx + 1)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .leading)
            Text(prettyDate(row.date))
                .font(.system(size: 12, weight: .medium))
                .frame(width: 140, alignment: .leading)
            // Inline mini-bar showing the day's relative cost.
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 6)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(
                            width: geo.size.width * CGFloat(row.cost / max(maxCost, 0.0001)),
                            height: 6
                        )
                }
                .frame(height: 6)
            }
            Text(pacerTokens(row.tokens))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Text(pacerCost(row.cost))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    /// `2026-04-30` → `Thu Apr 30`. Compact + day-of-week so the user
    /// can spot patterns ("oh I always burn on Wednesdays").
    private func prettyDate(_ ymd: String) -> String {
        let inFmt = DateFormatter()
        inFmt.dateFormat = "yyyy-MM-dd"
        inFmt.timeZone = .current
        guard let d = inFmt.date(from: ymd) else { return ymd }
        let outFmt = DateFormatter()
        outFmt.dateFormat = "EEE MMM d"
        outFmt.timeZone = .current
        return outFmt.string(from: d)
    }
}
