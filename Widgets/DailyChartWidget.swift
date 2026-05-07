import WidgetKit
import SwiftUI
import SwiftData
import Charts
import PacerCore

/// Two-week daily-cost chart. Medium family shows the bar chart;
/// large adds the running 14-day total prominently above. Pulls
/// `DailyAggregate` rows summed by date — same source as
/// `DailyCostChartCard` on the dashboard.
struct DailyChartEntry: TimelineEntry {
    let date: Date
    let days: [DayCost]
    let totalCostUSD: Double
    let isFresh: Bool

    struct DayCost: Identifiable {
        let date: String
        let cost: Double
        var id: String { date }
    }
}

struct DailyChartProvider: TimelineProvider {
    func placeholder(in context: Context) -> DailyChartEntry {
        let now = Date()
        let cal = Calendar.current
        let days: [DailyChartEntry.DayCost] = (0..<14).reversed().map { i in
            let d = cal.date(byAdding: .day, value: -i, to: now) ?? now
            return DailyChartEntry.DayCost(
                date: TokenSample.formatDate(d),
                cost: Double.random(in: 1...30)
            )
        }
        return DailyChartEntry(
            date: now,
            days: days,
            totalCostUSD: days.reduce(0) { $0 + $1.cost },
            isFresh: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (DailyChartEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyChartEntry>) -> Void) {
        let entry = currentEntry()
        let nextRefresh = Date().addingTimeInterval(900)  // 15min
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func currentEntry() -> DailyChartEntry {
        do {
            let container = try PacerStore.makeModelContainer()
            let context = ModelContext(container)
            // Pull the last ~14 days. Fetch all aggregates sorted desc
            // by date, then group/sum by date in-memory; cheaper than
            // a SQL group-by we'd have to wedge through a SwiftData
            // predicate.
            let descriptor = FetchDescriptor<DailyAggregate>(
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            let aggregates = try context.fetch(descriptor)
            let grouped = Dictionary(grouping: aggregates, by: \.date)
            let sortedDates = grouped.keys.sorted()
            let recent = sortedDates.suffix(14)
            let days = recent.map { date in
                DailyChartEntry.DayCost(
                    date: date,
                    cost: grouped[date]?.reduce(0) { $0 + $1.totalCostUSD } ?? 0
                )
            }
            let total = days.reduce(0) { $0 + $1.cost }
            return DailyChartEntry(date: Date(), days: days, totalCostUSD: total, isFresh: true)
        } catch {
            return DailyChartEntry(date: Date(), days: [], totalCostUSD: 0, isFresh: false)
        }
    }
}

struct DailyChartWidgetView: View {
    var entry: DailyChartEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 14 days")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatCost(entry.totalCostUSD))
                    .font(.system(family == .systemLarge ? .title2 : .headline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            if entry.days.isEmpty {
                emptyState
            } else {
                chart
            }
        }
        .padding(family == .systemLarge ? 14 : 10)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var chart: some View {
        Chart(entry.days) { d in
            BarMark(
                x: .value("Date", d.date),
                y: .value("Cost", d.cost)
            )
            .foregroundStyle(.tint)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(compactDollar(v))
                            .font(.system(size: 8, design: .monospaced))
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        Text(entry.isFresh ? "No usage logged in the last 14 days." : "No data yet.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 1000 { return String(format: "$%.0f", usd) }
        if usd >= 100  { return String(format: "$%.0f", usd) }
        if usd >= 10   { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }

    private func compactDollar(_ usd: Double) -> String {
        if usd >= 100 { return String(format: "$%.0f", usd) }
        if usd >= 10  { return String(format: "$%.0f", usd) }
        return String(format: "$%.1f", usd)
    }
}

struct DailyChartWidget: Widget {
    let kind: String = "DailyChartWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DailyChartProvider()) { entry in
            DailyChartWidgetView(entry: entry)
        }
        .configurationDisplayName("Daily cost — last 14 days")
        .description("Bar chart of daily Claude Code cost.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
