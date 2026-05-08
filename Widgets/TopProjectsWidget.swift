import WidgetKit
import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

/// Top projects by cost over the last N days, rendered as a horizontal
/// bar chart with cost labels. Answers "where's my Claude budget
/// actually going" at a glance — the existing daily-cost widget shows
/// the *what* (a sum), this surfaces the *where*.
///
/// Reads from `ProjectDailyAggregate`, which the daemon recomputes
/// every scan cycle. Bars are normalized against the top project's
/// cost so a heavy week stays readable; medium shows top 3, large
/// shows top 5.
///
/// 30-min refresh: this view rarely changes inside a single hour, so a
/// shorter cadence would just burn the widget budget for visually
/// identical updates.

// Constants inside the struct namespace rather than at file scope —
// file-scope `private let`s referenced from a Widget's `body` getter
// crashed the extension on launch (every Pacer widget invisible in
// the gallery, multiple PacerWidgets-*.ips reports all pinned to
// `TopProjectsWidget.body.getter`). Static constants nested in the
// struct sidestep whatever runtime path the file-scoped-let was
// tripping in the sandboxed extension's `body` evaluation, and we
// don't lose anything by scoping them to the widget that uses them.
private enum K {
    static let mediumRowCount = 4
    static let largeRowCount = 6
}

struct TopProjectsEntry: TimelineEntry {
    let date: Date
    let range: LookbackRangeOption
    let totalCostUSD: Double
    let projectCount: Int
    let rows: [Row]
    /// Single-project focus mode: when the user pins a project in the
    /// intent, this gets populated with that project's stats and the
    /// view switches from a top-N bar list to a one-card detail layout.
    let focus: Focus?

    struct Row: Identifiable {
        let displayName: String
        let costUSD: Double
        var id: String { displayName }
    }

    /// Per-day spend + totals for a single pinned project. View needs
    /// a sparkline + headline cost + day count, so we precompute all
    /// three on the provider side.
    struct Focus {
        let displayName: String
        let totalCostUSD: Double
        let dayCount: Int
        let days: [Day]
        struct Day: Identifiable {
            let date: String
            let cost: Double
            var id: String { date }
        }
    }
}

struct TopProjectsProvider: AppIntentTimelineProvider {
    typealias Intent = TopProjectsConfigurationIntent
    typealias Entry = TopProjectsEntry

    func placeholder(in context: Context) -> TopProjectsEntry {
        let rows = [
            ("ccmac",       342.10),
            ("public-blog", 156.40),
            ("example-proj",      88.75),
            ("openexp",      42.30),
            ("scratch",      18.05),
        ].map { TopProjectsEntry.Row(displayName: $0.0, costUSD: $0.1) }
        return TopProjectsEntry(
            date: Date(),
            range: .days7,
            totalCostUSD: rows.reduce(0) { $0 + $1.costUSD },
            projectCount: rows.count,
            rows: rows,
            focus: nil
        )
    }

    func snapshot(for configuration: TopProjectsConfigurationIntent, in context: Context) async -> TopProjectsEntry {
        currentEntry(configuration: configuration)
    }

    func timeline(for configuration: TopProjectsConfigurationIntent, in context: Context) async -> Timeline<TopProjectsEntry> {
        let entry = currentEntry(configuration: configuration)
        let nextRefresh = Date().addingTimeInterval(1800)  // 30 min
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func currentEntry(configuration: TopProjectsConfigurationIntent) -> TopProjectsEntry {
        let range = configuration.range
        do {
            let container = try PacerStore.makeModelContainer()
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<ProjectDailyAggregate>(
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            let aggregates = try context.fetch(descriptor)
            let cutoff = TokenSample.formatDate(
                Calendar.current.date(byAdding: .day, value: -(range.days - 1), to: Date()) ?? Date()
            )
            let inRange = aggregates.filter { $0.date >= cutoff }

            // Pinned-project focus mode: filter to that project's rows
            // only, build a per-day series for the sparkline.
            if let pinned = configuration.pinnedProject {
                let projectRows = inRange.filter { $0.projectPath == pinned.id }
                let grouped = Dictionary(grouping: projectRows, by: \.date)
                let days = grouped.keys.sorted().map { date in
                    TopProjectsEntry.Focus.Day(
                        date: date,
                        cost: grouped[date]?.reduce(0) { $0 + $1.totalCostUSD } ?? 0
                    )
                }
                let total = days.reduce(0) { $0 + $1.cost }
                return TopProjectsEntry(
                    date: Date(),
                    range: range,
                    totalCostUSD: total,
                    projectCount: 1,
                    rows: [],
                    focus: TopProjectsEntry.Focus(
                        displayName: pinned.displayName,
                        totalCostUSD: total,
                        dayCount: days.filter { $0.cost > 0 }.count,
                        days: days
                    )
                )
            }

            // Standard top-N mode.
            var totals: [String: Double] = [:]
            for row in inRange {
                totals[row.projectPath, default: 0] += row.totalCostUSD
            }
            let allRanked = totals
                .map { (path: $0.key, cost: $0.value) }
                .filter { $0.cost > 0 }
                .sorted { $0.cost > $1.cost }
            let topRows = allRanked.prefix(K.largeRowCount).map {
                TopProjectsEntry.Row(
                    displayName: pacerShortPath($0.path),
                    costUSD: $0.cost
                )
            }
            return TopProjectsEntry(
                date: Date(),
                range: range,
                totalCostUSD: allRanked.reduce(0) { $0 + $1.cost },
                projectCount: allRanked.count,
                rows: Array(topRows),
                focus: nil
            )
        } catch {
            return TopProjectsEntry(
                date: Date(),
                range: range,
                totalCostUSD: 0,
                projectCount: 0,
                rows: [],
                focus: nil
            )
        }
    }
}

// MARK: - Views

struct TopProjectsWidgetView: View {
    let entry: TopProjectsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let focus = entry.focus {
                focusCard(focus)
            } else {
                topNList
            }
        }
        .padding(family == .systemLarge ? WidgetStyle.largePad : WidgetStyle.mediumPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetCardBackground, for: .widget)
    }

    // MARK: Top-N (no project pinned)

    @ViewBuilder
    private var topNList: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 6) {
            header
            if visibleRows.isEmpty {
                WidgetEmptyState(message: "No project activity in the \(entry.range.longLabel).")
            } else {
                VStack(spacing: family == .systemLarge ? 6 : 5) {
                    ForEach(visibleRows) { row in
                        bar(for: row)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                if family == .systemLarge {
                    Spacer(minLength: 0)
                    Divider()
                    footer
                }
            }
        }
    }

    private var visibleRows: [TopProjectsEntry.Row] {
        let cap = (family == .systemLarge) ? K.largeRowCount : K.mediumRowCount
        return Array(entry.rows.prefix(cap))
    }

    private var maxCost: Double {
        max(entry.rows.first?.costUSD ?? 0, 1)
    }

    @ViewBuilder
    private var header: some View {
        WidgetTitleBar(title: "TOP PROJECTS · \(entry.range.shortLabel)") {
            Text(pacerCost(entry.totalCostUSD))
                .font(.system(family == .systemLarge ? .title3 : .subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Text("\(entry.projectCount) active project\(entry.projectCount == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            if entry.projectCount > visibleRows.count {
                Text("+\(entry.projectCount - visibleRows.count) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func bar(for row: TopProjectsEntry.Row) -> some View {
        let fraction = row.costUSD / maxCost
        return HStack(spacing: 8) {
            Text(row.displayName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: WidgetStyle.labelColumnWidth, alignment: .leading)
            WidgetProgressBar(fraction: fraction, height: family == .systemLarge ? 9 : 8)
            Text(pacerCost(row.costUSD))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: WidgetStyle.costColumnWidth, alignment: .trailing)
        }
    }

    // MARK: Pinned-project focus card

    @ViewBuilder
    private func focusCard(_ focus: TopProjectsEntry.Focus) -> some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 6) {
            // Tight header: project name on top, range chip on the
            // right, headline total below — mirrors the dashboard
            // detail-card hierarchy.
            WidgetTitleBar(title: focus.displayName.uppercased()) {
                Text(entry.range.shortLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(pacerCost(focus.totalCostUSD))
                    .font(.system(family == .systemLarge ? .largeTitle : .title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(focus.dayCount == 1 ? "/ 1 active day" : "/ \(focus.dayCount) active days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Sparkline of per-day spend across the range. Bars only —
            // no axes — to read at a glance like a usage pulse.
            if !focus.days.isEmpty {
                Chart(focus.days) { d in
                    BarMark(
                        x: .value("Date", d.date),
                        y: .value("Cost", d.cost),
                        width: .ratio(0.7)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.8))
                    .cornerRadius(2)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(maxHeight: .infinity)
            } else {
                Text("No activity in the \(entry.range.longLabel).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

// MARK: - Configuration

struct TopProjectsWidget: Widget {
    let kind: String = "TopProjectsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: TopProjectsConfigurationIntent.self,
            provider: TopProjectsProvider()
        ) { entry in
            TopProjectsWidgetView(entry: entry)
        }
        .configurationDisplayName("Top projects")
        // Literal string — no interpolation. `WidgetConfiguration.description(_:)`
        // takes `LocalizedStringKey`, and interpolating into it asserts
        // at extension launch.
        .description("Project breakdown over a configurable lookback. Pin a single project to focus on its daily spend.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
