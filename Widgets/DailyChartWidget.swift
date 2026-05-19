import WidgetKit
import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

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
    /// Lookback range chosen by the user. Drives the header label, the
    /// stat-row "N-day avg" copy, and how many days the provider rolls up.
    let range: LookbackRangeOption

    struct DayCost: Identifiable {
        let date: String
        let cost: Double
        var id: String { date }
        var isToday: Bool { date == TokenSample.formatDate(Date()) }
    }
}

struct DailyChartProvider: AppIntentTimelineProvider {
    typealias Intent = DailyChartConfigurationIntent
    typealias Entry = DailyChartEntry

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
            isFresh: true,
            range: .days14
        )
    }

    func snapshot(for configuration: DailyChartConfigurationIntent, in context: Context) async -> DailyChartEntry {
        currentEntry(range: configuration.range)
    }

    func timeline(for configuration: DailyChartConfigurationIntent, in context: Context) async -> Timeline<DailyChartEntry> {
        let entry = currentEntry(range: configuration.range)
        let nextRefresh = Date().addingTimeInterval(900)  // 15 min
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func currentEntry(range: LookbackRangeOption) -> DailyChartEntry {
        do {
            let container = try PacerStore.sharedModelContainer()
            let context = ModelContext(container)
            // Predicate-scoped fetch — on a power user's 2-year DB the
            // unbounded form materialized ~3650 rows (730 days × 5
            // models) on every 15-min widget refresh. The
            // `(date)` index makes this a range scan; the in-memory
            // group-by then runs over at most range.days × N_models
            // rows.
            let cutoffString = TokenSample.formatDate(
                Calendar.current.date(byAdding: .day, value: -(range.days - 1), to: Date()) ?? Date()
            )
            let descriptor = FetchDescriptor<DailyAggregate>(
                predicate: #Predicate<DailyAggregate> { $0.date >= cutoffString },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            let aggregates = try context.fetch(descriptor)
            let grouped = Dictionary(grouping: aggregates, by: \.date)
            let sortedDates = grouped.keys.sorted()
            let recent = sortedDates.suffix(range.days)
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
                isFresh: true,
                range: range
            )
        } catch {
            return DailyChartEntry(
                date: Date(),
                days: [],
                totalCostUSD: 0,
                avgCostUSD: 0,
                todayCostUSD: 0,
                isFresh: false,
                range: range
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
                WidgetEmptyState(message: entry.isFresh ? "No usage logged in the \(entry.range.longLabel)." : "No data yet.")
            } else {
                chart
                if family == .systemLarge {
                    statRow
                }
            }
        }
        .padding(family == .systemLarge ? WidgetStyle.largePad : WidgetStyle.mediumPad)
        .containerBackground(widgetCardBackground, for: .widget)
    }

    @ViewBuilder
    private var header: some View {
        // Title adapts to the chosen range so the user always sees a
        // matching label for whatever they picked in the intent ("LAST
        // 7 DAYS", "LAST 30 DAYS", etc.).
        WidgetTitleBar(title: "LAST \(entry.range.shortLabel.uppercased())") {
            Text(pacerCost(entry.totalCostUSD))
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
            stat(label: "today", value: pacerCost(entry.todayCostUSD))
            Divider().frame(height: 24)
            stat(label: "\(entry.range.shortLabel) avg", value: pacerCost(entry.avgCostUSD))
            Divider().frame(height: 24)
            stat(label: "peak day", value: pacerCost(entry.days.map(\.cost).max() ?? 0))
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
    let kind: String = WidgetKinds.dailyChart

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: DailyChartConfigurationIntent.self,
            provider: DailyChartProvider()
        ) { entry in
            DailyChartWidgetView(entry: entry)
        }
        .configurationDisplayName("Daily cost")
        // Description stays generic — the actual range is user-picked.
        .description("Daily Claude Code spend over a configurable lookback window.")
        .supportedFamilies([.systemMedium, .systemLarge])
        // See `PaceChartWidget` for the rationale: drops the system's
        // ~16pt default content margin so `WidgetStyle.*Pad` is the
        // only inset.
        .contentMarginsDisabled()
    }
}
