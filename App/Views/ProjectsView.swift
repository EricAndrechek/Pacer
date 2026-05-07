import SwiftUI
import SwiftData
import Charts
import PacerCore

/// Per-project breakdown. Pulls `TokenSample` rows directly because
/// `DailyAggregate` is keyed on (date, model) and doesn't carry the
/// project dimension.
///
/// Filter limit: last 90 days by default to keep fetch + group cost
/// bounded. The view exposes a small picker for "30d / 90d / all"; on
/// large datasets users will care about recent activity anyway.
struct ProjectsView: View {
    @State private var range: ProjectRange = .ninetyDays
    @State private var searchText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                searchField
                // Inner view re-inits whenever `range` changes so its
                // @Query rebuilds with a fresh predicate. `id(range)`
                // makes the structural identity update explicit.
                ProjectsContent(range: range, searchText: searchText)
                    .id(range)
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 600)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Projects")
                .font(.largeTitle.weight(.semibold))
            Spacer()
            Picker("", selection: $range) {
                ForEach(ProjectRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        }
        .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter projects by path", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

enum ProjectRange: String, CaseIterable, Identifiable {
    case thirtyDays = "30d"
    case ninetyDays = "90d"
    case all        = "all"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .thirtyDays: return "Last 30 days"
        case .ninetyDays: return "Last 90 days"
        case .all:        return "All time"
        }
    }
    var days: Int? {
        switch self {
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        case .all:        return nil
        }
    }
}

private struct ProjectsContent: View {
    /// Pre-computed `(project, date)` rollup. Two thousand rows tops
    /// on a populated install (vs ~30k raw TokenSamples) and grouping
    /// by project for the table is a single in-memory pass over those
    /// rows. The daemon maintains this table via
    /// `ProjectAggregateRecomputer`; the view never iterates raw
    /// samples.
    @Query private var aggregates: [ProjectDailyAggregate]

    @State private var selected: SelectedProject?

    /// Sheet's `item:` binding requires Identifiable; wrap the path
    /// plus our display-friendly fields so the detail view doesn't
    /// need to re-derive them.
    struct SelectedProject: Identifiable {
        let path: String
        let displayName: String
        let since: Date?
        var id: String { path }
    }

    let rangeSince: Date?
    let searchText: String

    init(range: ProjectRange, searchText: String = "") {
        let since: Date?
        let cutoffString: String?
        if let days = range.days {
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
            since = cutoffDate
            cutoffString = TokenSample.formatDate(cutoffDate)
        } else {
            since = nil
            cutoffString = nil
        }
        self.rangeSince = since
        self.searchText = searchText
        if let cutoffString {
            _aggregates = Query(
                filter: #Predicate<ProjectDailyAggregate> { $0.date >= cutoffString }
            )
        } else {
            _aggregates = Query()
        }
    }

    private struct ProjectRow: Identifiable {
        let path: String
        let displayName: String
        let cost: Double
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheReadTokens: Int64
        let totalTokens: Int64
        let sessionCount: Int
        let lastActive: Date
        let modelCount: Int
        var id: String { path }
    }

    /// One in-memory pass over the precomputed daily rollup, grouped
    /// by `projectPath`. With ~2k rows max this is sub-10ms even on
    /// the main thread, so we don't bother with a worker hop.
    private var allRows: [ProjectRow] {
        struct Acc {
            var cost: Double = 0
            var input: Int64 = 0
            var output: Int64 = 0
            var cacheRead: Int64 = 0
            // Aggregating sessions/models across days slightly
            // overcounts (a session that crossed midnight gets
            // double-counted). For the list view we accept it; the
            // detail view unions sessionIdsJSON for accuracy.
            var sessionCount: Int = 0
            var modelCount: Int = 0
            var lastActive: Date = .distantPast
        }
        var byProject: [String: Acc] = [:]
        for r in aggregates {
            var a = byProject[r.projectPath] ?? Acc()
            a.cost += r.totalCostUSD
            a.input += r.inputTokens
            a.output += r.outputTokens
            a.cacheRead += r.cacheReadTokens
            a.sessionCount += r.sessionCount
            a.modelCount += r.modelCount
            if r.lastActive > a.lastActive { a.lastActive = r.lastActive }
            byProject[r.projectPath] = a
        }
        return byProject.map { (key, a) in
            ProjectRow(
                path: key,
                displayName: shortPath(key),
                cost: a.cost,
                inputTokens: a.input,
                outputTokens: a.output,
                cacheReadTokens: a.cacheRead,
                totalTokens: a.input + a.output + a.cacheRead,
                sessionCount: a.sessionCount,
                lastActive: a.lastActive,
                modelCount: a.modelCount
            )
        }.sorted { $0.cost > $1.cost }
    }

    private var rows: [ProjectRow] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        let base = allRows
        guard !needle.isEmpty else { return base }
        let lower = needle.lowercased()
        return base.filter {
            $0.path.lowercased().contains(lower) ||
            $0.displayName.lowercased().contains(lower)
        }
    }

    var body: some View {
        Group {
            if rows.isEmpty && !searchText.isEmpty {
                noSearchMatchesState
            } else if rows.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    overviewCard
                    projectListCard
                }
            }
        }
        .sheet(item: $selected) { sel in
            ProjectDetailView(
                projectPath: sel.path,
                displayName: sel.displayName,
                since: sel.since
            )
        }
    }

    private var noSearchMatchesState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("No projects match \u{201C}\(searchText)\u{201D}")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Text("Try clearing the filter or widening the time range.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No project activity in the selected range.")
                .foregroundStyle(.secondary)
            Text("Pacer reads `cwd` from each Claude Code JSONL line, so projects show up automatically as soon as you run Claude Code in a directory.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top projects by cost")
                .font(.title2.weight(.semibold))
            // Top 5 share-of-cost donut.
            let top = Array(rows.prefix(5))
            let totalCost = rows.reduce(0) { $0 + $1.cost }
            HStack(alignment: .top, spacing: 24) {
                Chart(top) { row in
                    SectorMark(
                        angle: .value("Cost", row.cost),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Project", row.displayName))
                    .cornerRadius(2)
                }
                .frame(width: 160, height: 160)
                .chartLegend(.hidden)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(top.enumerated()), id: \.offset) { idx, row in
                        HStack(alignment: .firstTextBaseline) {
                            Circle()
                                .fill(legendColor(idx))
                                .frame(width: 8, height: 8)
                            Text(row.displayName)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: 220, alignment: .leading)
                            Spacer(minLength: 8)
                            Text(formatCost(row.cost))
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .frame(width: 70, alignment: .trailing)
                            if totalCost > 0 {
                                Text("\(Int((row.cost / totalCost * 100).rounded()))%")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 40, alignment: .trailing)
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
    }

    private var projectListCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("All projects")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(rows.count) project\(rows.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Tokens")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
                Text("Sessions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                Text("Last active")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
                Text("Cost")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
            Divider()
            ForEach(rows) { row in
                Button {
                    selected = SelectedProject(
                        path: row.path,
                        displayName: row.displayName,
                        since: rangeSince
                    )
                } label: {
                    projectRow(row)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func projectRow(_ row: ProjectRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Text(row.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(formatTokens(row.totalTokens))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 100, alignment: .trailing)
            Text("\(row.sessionCount)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(relative(row.lastActive))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(formatCost(row.cost))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    /// `/Users/eric/Code/public-projects/ccmac` → `ccmac`. Falls back to
    /// the full path if there's nothing to trim.
    private func shortPath(_ path: String) -> String {
        if path == "(unknown)" { return path }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 1_000 { return String(format: "$%.0f", usd) }
        if usd >= 100   { return String(format: "$%.0f", usd) }
        if usd >= 10    { return String(format: "$%.1f", usd) }
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

    private func legendColor(_ idx: Int) -> Color {
        // Same default order Charts assigns when the foregroundStyle uses
        // `by:` — keeps the legend swatches and donut sectors in sync.
        let palette: [Color] = [.blue, .green, .orange, .red, .purple, .pink, .teal, .yellow]
        return palette[idx % palette.count]
    }
}
