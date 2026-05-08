import WidgetKit
import SwiftUI
import SwiftData
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
    static let lookbackDays = 7
    static let mediumRowCount = 4
    static let largeRowCount = 6
    static let rangeLabel = "last 7 days"
}

struct TopProjectsEntry: TimelineEntry {
    let date: Date
    let rangeLabel: String       // "last 7 days"
    let totalCostUSD: Double
    let projectCount: Int
    let rows: [Row]

    struct Row: Identifiable {
        let displayName: String
        let costUSD: Double
        var id: String { displayName }
    }
}

struct TopProjectsProvider: TimelineProvider {
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
            rangeLabel: "\(K.rangeLabel)",
            totalCostUSD: rows.reduce(0) { $0 + $1.costUSD },
            projectCount: rows.count,
            rows: rows
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TopProjectsEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TopProjectsEntry>) -> Void) {
        let entry = currentEntry()
        let nextRefresh = Date().addingTimeInterval(1800)  // 30 min
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func currentEntry() -> TopProjectsEntry {
        do {
            let container = try PacerStore.makeModelContainer()
            let context = ModelContext(container)
            // Fetch the last N days of project aggregates. We don't predicate
            // on date here — SwiftData string-comparing YYYY-MM-DD is cheap,
            // but small-N row scans in memory after fetch are simpler and
            // ProjectDailyAggregate stays in the low thousands of rows even
            // on a year-old install.
            let descriptor = FetchDescriptor<ProjectDailyAggregate>(
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            let aggregates = try context.fetch(descriptor)
            let cutoff = TokenSample.formatDate(
                Calendar.current.date(byAdding: .day, value: -(K.lookbackDays - 1), to: Date()) ?? Date()
            )
            let inRange = aggregates.filter { $0.date >= cutoff }
            // Sum cost per project over the window.
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
                rangeLabel: K.rangeLabel,
                totalCostUSD: allRanked.reduce(0) { $0 + $1.cost },
                projectCount: allRanked.count,
                rows: Array(topRows)
            )
        } catch {
            return TopProjectsEntry(
                date: Date(),
                rangeLabel: K.rangeLabel,
                totalCostUSD: 0,
                projectCount: 0,
                rows: []
            )
        }
    }
}

// MARK: - Views

struct TopProjectsWidgetView: View {
    let entry: TopProjectsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 6) {
            header
            if visibleRows.isEmpty {
                WidgetEmptyState(message: "No project activity in the last 7 days.")
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
        .padding(family == .systemLarge ? WidgetStyle.largePad : WidgetStyle.mediumPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetCardBackground, for: .widget)
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
        WidgetTitleBar(title: "TOP PROJECTS · 7d") {
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
}

// MARK: - Configuration

struct TopProjectsWidget: Widget {
    let kind: String = "TopProjectsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TopProjectsProvider()) { entry in
            TopProjectsWidgetView(entry: entry)
        }
        .configurationDisplayName("Top projects")
        // Literal string — no interpolation. `WidgetConfiguration.description(_:)`
        // takes `LocalizedStringKey`, and interpolating into it asserts
        // at extension launch.
        .description("Project breakdown over the last 7 days.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
