import WidgetKit
import SwiftUI
import SwiftData
import PacerCore

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
    static let mediumRowCount = 3
    static let largeRowCount = 5
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
                    displayName: shortPath($0.path),
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
        switch family {
        case .systemLarge: large
        default:           medium
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
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(showFooter: false)
            if visibleRows.isEmpty {
                emptyState
            } else {
                VStack(spacing: 4) {
                    ForEach(visibleRows) { row in
                        bar(for: row)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(showFooter: false)
            if visibleRows.isEmpty {
                emptyState
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 6) {
                    ForEach(visibleRows) { row in
                        bar(for: row)
                    }
                }
                Spacer(minLength: 0)
                Divider()
                footer
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func header(showFooter: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Top projects")
                .font(.caption.weight(.semibold))
            Text("·")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(entry.rangeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatCost(entry.totalCostUSD))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
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
            // If there's spillover beyond the visible rows, hint at it
            // so the user knows the widget is summarized rather than
            // showing the universe.
            if entry.projectCount > visibleRows.count {
                Text("+\(entry.projectCount - visibleRows.count) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func bar(for row: TopProjectsEntry.Row) -> some View {
        let fraction = max(0.04, min(1, row.costUSD / maxCost))
        return HStack(spacing: 8) {
            Text(row.displayName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 90, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.tint)
                        .frame(width: geo.size.width * CGFloat(fraction))
                }
            }
            .frame(height: 8)
            Text(formatCost(row.costUSD))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No project activity in the \(K.rangeLabel).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Formatters

    private func formatCost(_ usd: Double) -> String {
        if usd >= 1000 { return String(format: "$%.0f", usd) }
        if usd >= 100  { return String(format: "$%.0f", usd) }
        if usd >= 10   { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }
}

private func shortPath(_ path: String) -> String {
    if path == ProjectDailyAggregate.unknownProjectPath { return "(unknown)" }
    let last = (path as NSString).lastPathComponent
    return last.isEmpty ? path : last
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
        // takes `LocalizedStringKey`, and interpolating ANY value (even a
        // literal Int or a static String) into it asserts at extension
        // launch. Hardcode the lookback in the user-visible string and
        // keep `K.lookbackDays` for the data math.
        .description("Top projects by Claude Code cost over the last 7 days.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
