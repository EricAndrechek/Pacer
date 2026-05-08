import WidgetKit
import SwiftUI
import SwiftData
import Charts
import PacerCore

/// Two-week daily-cost chart. Medium family shows the bar chart;
/// large adds a stat row with today/avg/total for the period above
/// the chart. Today's bar is rendered in full tint so the right edge
/// reads as "where I am now" instead of just another stripe.
///
/// Pulls `DailyAggregate` rows summed by date — same source as
/// `DailyCostChartCard` on the dashboard.

struct DailyChartEntry: TimelineEntry {
    let date: Date
    let days: [DayCost]
    let totalCostUSD: Double
    let avgCostUSD: Double
    let todayCostUSD: Double
    let isFresh: Bool

    struct DayCost: Identifiable {
        let date: String
        let cost: Double
        var id: String { date }
        var isToday: Bool { date == TokenSample.formatDate(Date()) }
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
        let total = days.reduce(0) { $0 + $1.cost }
        return DailyChartEntry(
            date: now,
            days: days,
            totalCostUSD: total,
            avgCostUSD: total / Double(max(1, days.count)),
            todayCostUSD: days.last?.cost ?? 0,
            isFresh: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (DailyChartEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyChartEntry>) -> Void) {
        let entry = currentEntry()
        let nextRefresh = Date().addingTimeInterval(900)  // 15 min
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func currentEntry() -> DailyChartEntry {
        do {
            let container = try PacerStore.makeModelContainer()
            let context = ModelContext(container)
            // Pull all aggregates desc by date and group/sum in-memory;
            // SwiftData predicates over date strings would work but the
            // small-N rollup here is cheap enough not to bother.
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
            let today = TokenSample.formatDate(Date())
            return DailyChartEntry(
                date: Date(),
                days: days,
                totalCostUSD: total,
                avgCostUSD: total / Double(max(1, days.count)),
                todayCostUSD: days.first { $0.date == today }?.cost ?? 0,
                isFresh: true
            )
        } catch {
            return DailyChartEntry(
                date: Date(),
                days: [],
                totalCostUSD: 0,
                avgCostUSD: 0,
                todayCostUSD: 0,
                isFresh: false
            )
        }
    }
}

struct DailyChartWidgetView: View {
    var entry: DailyChartEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 6) {
            header
            if entry.days.isEmpty {
                WidgetEmptyState(message: entry.isFresh ? "No usage logged in the last 14 days." : "No data yet.")
            } else {
                chart
                if family == .systemLarge {
                    statRow
                }
            }
        }
        .padding(family == .systemLarge ? WidgetStyle.largePad : WidgetStyle.mediumPad)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var header: some View {
        WidgetTitleBar(title: "LAST 14 DAYS") {
            Text(formatCostUSD(entry.totalCostUSD))
                .font(.system(family == .systemLarge ? .title3 : .headline, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
    }

    private var chart: some View {
        Chart(entry.days) { d in
            BarMark(
                x: .value("Date", d.date),
                y: .value("Cost", d.cost),
                width: .ratio(0.7)
            )
            // Today's bar full-tint, everything else dimmed so the
            // current day reads as "this is now" instead of a stripe
            // among many.
            .foregroundStyle(d.isToday ? Color.accentColor : Color.accentColor.opacity(0.55))
            .cornerRadius(2)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(compactDollar(v))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statRow: some View {
        HStack(spacing: 0) {
            stat(label: "today", value: formatCostUSD(entry.todayCostUSD))
            Divider().frame(height: 24)
            stat(label: "14-day avg", value: formatCostUSD(entry.avgCostUSD))
            Divider().frame(height: 24)
            stat(label: "peak day", value: formatCostUSD(entry.days.map(\.cost).max() ?? 0))
        }
    }

    private func stat(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
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
        .configurationDisplayName("Daily cost")
        .description("Last 14 days of Claude Code spend.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
