import SwiftUI
import SwiftData
import Charts
import PacerCore

/// "All time" view — lifetime totals, monthly trend, and most expensive
/// days. Reads from `DailyAggregate` (which is the canonical roll-up;
/// it's already pre-summed, so there's no per-row cost calc here).
///
/// The cards stack vertically and scroll. Order is: lifetime headline →
/// monthly bar chart → top expensive days table.
struct HistoryView: View {
    @State private var selectedDay: SelectedDay?

    /// Sheet's `item:` requires Identifiable. Wrapping the raw date
    /// string keeps the heatmap → detail handoff cheap.
    struct SelectedDay: Identifiable {
        let date: String
        var id: String { date }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("History")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)

                LifetimeSummaryCard()
                HeatmapCard { dayKey in
                    selectedDay = SelectedDay(date: dayKey)
                }
                MonthlyChartCard()
                TopDaysCard()
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 600)
        .sheet(item: $selectedDay) { sel in
            DayDetailView(date: sel.date)
        }
    }
}

// MARK: - Lifetime summary

private struct LifetimeSummaryCard: View {
    /// All-time aggregates. Read only from `refreshCache()`; body
    /// reads `cached.totals` so a SwiftData save doesn't re-iterate
    /// the whole table per tick (it's small now, but the History tab
    /// stacks four cards that all do this and the body re-eval cost
    /// adds up).
    @Query(sort: \DailyAggregate.date, order: .reverse) private var aggregates: [DailyAggregate]
    @Query(LifetimeSummaryCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cached = Totals()

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private struct Totals {
        var cost: Double = 0
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var distinctDays: Int = 0
        var distinctModels: Int = 0
        var firstDate: String?
    }

    private func refreshCache() {
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
        cached = t
    }

    var body: some View {
        let t = cached
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lifetime")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let first = t.firstDate {
                    Text("since \(first)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if t.distinctDays == 0 {
                Text("No history yet — start using Claude Code and Pacer will catch up.")
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))
            } else {
                HStack(alignment: .top, spacing: 32) {
                    metric("cost", formatCost(t.cost))
                    metric("input", formatTokens(t.input))
                    metric("output", formatTokens(t.output))
                    metric("cache read", formatTokens(t.cacheRead))
                    metric("active days", "\(t.distinctDays)")
                    metric("models", "\(t.distinctModels)")
                    Spacer()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    @ViewBuilder
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 10_000 { return String(format: "$%.0f", usd) }
        if usd >= 1_000  { return String(format: "$%.0f", usd) }
        if usd >= 100    { return String(format: "$%.1f", usd) }
        if usd >= 10     { return String(format: "$%.2f", usd) }
        return String(format: "$%.2f", usd)
    }

    private func formatTokens(_ count: Int64) -> String {
        let n = Double(count)
        switch n {
        case 1_000_000_000_000...: return String(format: "%.2fT", n / 1_000_000_000_000)
        case 1_000_000_000...:     return String(format: "%.2fB", n / 1_000_000_000)
        case 1_000_000...:         return String(format: "%.2fM", n / 1_000_000)
        case 10_000...:            return String(format: "%.1fK", n / 1_000)
        case 1_000...:             return String(format: "%.2fK", n / 1_000)
        default:                   return "\(count)"
        }
    }
}

// MARK: - Monthly bar chart

private struct MonthlyChartCard: View {
    @Query(sort: \DailyAggregate.date, order: .reverse) private var aggregates: [DailyAggregate]
    @Query(MonthlyChartCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    @State private var selectedMonth: String?
    @State private var cached: [MonthBucket] = []

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private struct MonthBucket: Identifiable {
        let month: String  // YYYY-MM
        let cost: Double
        var id: String { month }
    }

    private var monthly: [MonthBucket] { cached }

    /// Group by YYYY-MM (substring of `date` which is YYYY-MM-DD).
    /// Last 12 months only — older data is too small to be useful here
    /// at this density.
    private func refreshCache() {
        var totals: [String: Double] = [:]
        for row in aggregates {
            guard row.date.count >= 7 else { continue }
            let key = String(row.date.prefix(7))
            totals[key, default: 0] += row.totalCostUSD
        }
        let sorted = totals.keys.sorted()
        let last12 = sorted.suffix(12)
        cached = last12.map { MonthBucket(month: $0, cost: totals[$0] ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Last 12 months")
                    .font(.title2.weight(.semibold))
                Spacer()
                if !monthly.isEmpty {
                    Text("total: \(formatCost(monthly.reduce(0) { $0 + $1.cost }))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if monthly.isEmpty {
                Text("No monthly history yet.")
                    .foregroundStyle(.secondary)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 200)
            } else {
                Chart {
                    ForEach(monthly) { m in
                        BarMark(
                            x: .value("Month", m.month),
                            y: .value("Cost", m.cost)
                        )
                        .foregroundStyle(.tint)
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            if m.cost > 0 && m.month != selectedMonth {
                                Text(formatCost(m.cost))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let selectedMonth, let row = monthly.first(where: { $0.month == selectedMonth }) {
                        RuleMark(x: .value("Selected", selectedMonth))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            .annotation(position: .top, alignment: .center, spacing: 4) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(longMonth(row.month))
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
                    }
                }
                .frame(height: 220)
                .chartXSelection(value: $selectedMonth)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let d = value.as(Double.self) {
                                Text(formatCost(d))
                                    .font(.system(size: 9, design: .monospaced))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let m = value.as(String.self) {
                                Text(shortMonth(m))
                                    .font(.system(size: 9, design: .monospaced))
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    /// `2026-04` → `Apr 26`. Compact form for the X axis at 12 months.
    private func shortMonth(_ ym: String) -> String {
        guard ym.count == 7,
              let yearInt = Int(ym.prefix(4)),
              let monthInt = Int(ym.suffix(2))
        else { return ym }
        let names = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        guard monthInt >= 1 && monthInt <= 12 else { return ym }
        return "\(names[monthInt - 1]) \(yearInt % 100)"
    }

    /// `2026-04` → `April 2026`. Used for hover callouts where there's
    /// room for a longer label.
    private func longMonth(_ ym: String) -> String {
        guard ym.count == 7,
              let yearInt = Int(ym.prefix(4)),
              let monthInt = Int(ym.suffix(2))
        else { return ym }
        let names = ["January","February","March","April","May","June","July","August","September","October","November","December"]
        guard monthInt >= 1 && monthInt <= 12 else { return ym }
        return "\(names[monthInt - 1]) \(yearInt)"
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 10_000 { return String(format: "$%.0f", usd) }
        if usd >= 1_000  { return String(format: "$%.0fk", usd / 1000) }
        if usd >= 100    { return String(format: "$%.0f", usd) }
        if usd >= 10     { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }
}

// MARK: - Top days

private struct TopDaysCard: View {
    @Query(sort: \DailyAggregate.date, order: .reverse) private var aggregates: [DailyAggregate]
    @Query(TopDaysCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cached: [DayRow] = []

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private struct DayRow: Identifiable {
        let date: String
        let cost: Double
        let tokens: Int64
        var id: String { date }
    }

    private var topRows: [DayRow] { cached }

    private func refreshCache() {
        var byDate: [String: (cost: Double, tokens: Int64)] = [:]
        for row in aggregates {
            var v = byDate[row.date] ?? (0, 0)
            v.cost += row.totalCostUSD
            v.tokens += row.inputTokens + row.outputTokens + row.cacheReadTokens
            byDate[row.date] = v
        }
        let rows = byDate.map { DayRow(date: $0.key, cost: $0.value.cost, tokens: $0.value.tokens) }
        cached = rows.sorted { $0.cost > $1.cost }.prefix(10).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Most expensive days")
                .font(.title2.weight(.semibold))
            if topRows.isEmpty {
                Text("No data yet.")
                    .foregroundStyle(.secondary)
                    .font(.system(.caption, design: .monospaced))
            } else {
                ForEach(topRows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.date)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 110, alignment: .leading)
                        Spacer(minLength: 16)
                        Text(formatTokens(row.tokens))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .trailing)
                        Text(formatCost(row.cost))
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .frame(width: 90, alignment: .trailing)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 100 { return String(format: "$%.0f", usd) }
        if usd >= 10  { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }

    private func formatTokens(_ count: Int64) -> String {
        let n = Double(count)
        switch n {
        case 1_000_000_000...: return String(format: "%.2fB", n / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", n / 1_000_000)
        case 1_000...:         return String(format: "%.1fK", n / 1_000)
        default:               return "\(count)"
        }
    }
}
