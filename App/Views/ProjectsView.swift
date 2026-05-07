import SwiftUI
import SwiftData
import Charts
import PacerCore

/// Per-project breakdown. Reads `ProjectDailyAggregate` (precomputed by
/// the in-process scan) so the table is sub-10ms even on populated
/// installs, and never iterates raw `TokenSample`s.
///
/// **Layout**: page header is just title + subtitle. Range picker
/// lives inline next to the data card it scopes (per the user's
/// "closer to the thing we are showing" feedback). Sort is driven by
/// clicking the table column headers; arrows on the active column
/// indicate direction. Both range and sort persist via App Group
/// `UserDefaults` under per-view keys so Models doesn't share state
/// with Projects.
struct ProjectsView: View {
    @AppStorage("pacer.projects.range", store: PacerSettings.store)
    private var rangeRaw: String = TimeRange.ninetyDays.rawValue

    @AppStorage(PacerSettings.Key.projectsSort, store: PacerSettings.store)
    private var sortRaw: String = ProjectSort.cost.rawValue

    @AppStorage("pacer.projects.sortDescending", store: PacerSettings.store)
    private var sortDescending: Bool = true

    @AppStorage("pacer.projects.overviewMetric", store: PacerSettings.store)
    private var overviewMetricRaw: String = ProjectMetric.cost.rawValue

    @State private var searchText: String = ""

    private var range: TimeRange {
        TimeRange(rawValue: rangeRaw) ?? .ninetyDays
    }
    private var sort: ProjectSort {
        ProjectSort(rawValue: sortRaw) ?? .cost
    }
    private var overviewMetric: ProjectMetric {
        ProjectMetric(rawValue: overviewMetricRaw) ?? .cost
    }

    var body: some View {
        PageScaffold("Projects", subtitle: "Per-project rollup of cost and tokens.") {
            ProjectsContent(
                range: range,
                sort: sort,
                descending: sortDescending,
                overviewMetric: overviewMetric,
                searchText: searchText,
                rangeBinding: rangeBinding,
                sortFieldBinding: sortFieldBinding,
                sortDescendingBinding: $sortDescending,
                overviewMetricBinding: overviewMetricBinding,
                searchBinding: $searchText
            )
            .id("\(range.rawValue)")
        }
    }

    private var rangeBinding: Binding<TimeRange> {
        Binding(get: { range }, set: { rangeRaw = $0.rawValue })
    }
    private var sortFieldBinding: Binding<ProjectSort> {
        Binding(get: { sort }, set: { sortRaw = $0.rawValue })
    }
    private var overviewMetricBinding: Binding<ProjectMetric> {
        Binding(get: { overviewMetric }, set: { overviewMetricRaw = $0.rawValue })
    }
}

/// What column the Projects table sorts by. The direction is held in
/// a separate `Bool` so users can sort ascending OR descending on any
/// column — both bits are persisted independently.
enum ProjectSort: String, CaseIterable, Identifiable {
    case cost
    case tokens
    case sessions
    case lastActive
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cost:       return "Cost"
        case .tokens:     return "Tokens"
        case .sessions:   return "Sessions"
        case .lastActive: return "Last active"
        case .name:       return "Project"
        }
    }
}

/// Metric a metric-pickable card colors / sizes by. Shared between
/// the top-projects donut card and the heatmap.
enum ProjectMetric: String, CaseIterable, Identifiable {
    case cost
    case tokens
    case sessions

    var id: String { rawValue }
    var label: String {
        switch self {
        case .cost:     return "Cost"
        case .tokens:   return "Tokens"
        case .sessions: return "Sessions"
        }
    }
}

private struct ProjectsContent: View {
    @Query private var aggregates: [ProjectDailyAggregate]

    @State private var selected: SelectedProject?

    struct SelectedProject: Identifiable {
        let path: String
        let displayName: String
        let since: Date?
        var id: String { path }
    }

    let rangeSince: Date?
    let searchText: String
    let sort: ProjectSort
    let descending: Bool
    let overviewMetric: ProjectMetric

    let rangeBinding: Binding<TimeRange>
    let sortFieldBinding: Binding<ProjectSort>
    let sortDescendingBinding: Binding<Bool>
    let overviewMetricBinding: Binding<ProjectMetric>
    let searchBinding: Binding<String>

    init(
        range: TimeRange,
        sort: ProjectSort,
        descending: Bool,
        overviewMetric: ProjectMetric,
        searchText: String,
        rangeBinding: Binding<TimeRange>,
        sortFieldBinding: Binding<ProjectSort>,
        sortDescendingBinding: Binding<Bool>,
        overviewMetricBinding: Binding<ProjectMetric>,
        searchBinding: Binding<String>
    ) {
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
        self.sort = sort
        self.descending = descending
        self.overviewMetric = overviewMetric
        self.rangeBinding = rangeBinding
        self.sortFieldBinding = sortFieldBinding
        self.sortDescendingBinding = sortDescendingBinding
        self.overviewMetricBinding = overviewMetricBinding
        self.searchBinding = searchBinding
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

    private var allRows: [ProjectRow] {
        struct Acc {
            var cost: Double = 0
            var input: Int64 = 0
            var output: Int64 = 0
            var cacheRead: Int64 = 0
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
        let unsorted = byProject.map { (key, a) in
            ProjectRow(
                path: key,
                displayName: pacerShortPath(key),
                cost: a.cost,
                inputTokens: a.input,
                outputTokens: a.output,
                cacheReadTokens: a.cacheRead,
                totalTokens: a.input + a.output + a.cacheRead,
                sessionCount: a.sessionCount,
                lastActive: a.lastActive,
                modelCount: a.modelCount
            )
        }
        return apply(sort: sort, descending: descending, to: unsorted)
    }

    private func apply(sort: ProjectSort, descending: Bool, to rows: [ProjectRow]) -> [ProjectRow] {
        let sorted: [ProjectRow]
        switch sort {
        case .cost:
            sorted = rows.sorted { $0.cost < $1.cost }
        case .tokens:
            sorted = rows.sorted { $0.totalTokens < $1.totalTokens }
        case .sessions:
            sorted = rows.sorted { $0.sessionCount < $1.sessionCount }
        case .lastActive:
            sorted = rows.sorted { $0.lastActive < $1.lastActive }
        case .name:
            sorted = rows.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        return descending ? sorted.reversed() : sorted
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
                VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                    overviewCard
                    projectListCard
                }
            }
        }
        .dismissibleModal(item: $selected) { sel in
            ProjectDetailView(
                projectPath: sel.path,
                displayName: sel.displayName,
                since: sel.since
            )
        }
    }

    private var noSearchMatchesState: some View {
        PacerCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("No projects match \u{201C}\(searchText)\u{201D}")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Text("Try clearing the filter or widening the time range.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var emptyState: some View {
        PacerCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("No project activity in the selected range.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Pacer reads `cwd` from each Claude Code JSONL line, so projects show up automatically as soon as you run Claude Code in a directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Top-N projects donut + ranking. The metric the donut/legend uses
    /// (cost, tokens, sessions) is user-selectable via segmented picker
    /// in the card header — mirrors the heatmap's metric picker so the
    /// app feels consistent.
    private var overviewCard: some View {
        let top = Array(rows.prefix(5))
        let totalForMetric = rows.reduce(0.0) { $0 + value(for: overviewMetric, in: $1) }
        return PacerCard("Top projects", trailing: {
            Picker("", selection: overviewMetricBinding) {
                ForEach(ProjectMetric.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .controlSize(.small)
            .labelsHidden()
        }) {
            HStack(alignment: .top, spacing: 24) {
                Chart(top) { row in
                    SectorMark(
                        angle: .value("Metric", value(for: overviewMetric, in: row)),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Project", row.displayName))
                    .cornerRadius(2)
                }
                .frame(width: 160, height: 160)
                .chartLegend(.hidden)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(top.enumerated()), id: \.offset) { idx, row in
                        let v = value(for: overviewMetric, in: row)
                        HStack(alignment: .firstTextBaseline) {
                            Circle()
                                .fill(legendColor(idx))
                                .frame(width: 8, height: 8)
                            Text(row.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: 220, alignment: .leading)
                            Spacer(minLength: 8)
                            Text(formatMetric(v, kind: overviewMetric))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                            if totalForMetric > 0 {
                                Text("\(Int((v / totalForMetric * 100).rounded()))%")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    private func value(for metric: ProjectMetric, in row: ProjectRow) -> Double {
        switch metric {
        case .cost:     return row.cost
        case .tokens:   return Double(row.totalTokens)
        case .sessions: return Double(row.sessionCount)
        }
    }

    private func formatMetric(_ v: Double, kind: ProjectMetric) -> String {
        switch kind {
        case .cost:     return pacerCost(v)
        case .tokens:   return pacerTokens(Int64(v))
        case .sessions: return "\(Int(v))"
        }
    }

    /// Big project list with sortable column headers + range picker
    /// inline in the card header. The range picker lives here (not in
    /// the page toolbar) per the "closer to the thing we are showing"
    /// principle — every card that scopes its data to a time window
    /// announces the window right next to the data.
    private var projectListCard: some View {
        PacerCard("All projects", trailing: {
            HStack(spacing: 10) {
                searchField
                Picker("", selection: rangeBinding) {
                    ForEach(TimeRange.allCases) { r in
                        Text(r.label).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                .controlSize(.small)
                .labelsHidden()
            }
        }) {
            VStack(alignment: .leading, spacing: 0) {
                tableHeader
                Divider().padding(.vertical, 4)
                ForEach(rows) { row in
                    HoverRow(action: {
                        selected = SelectedProject(
                            path: row.path,
                            displayName: row.displayName,
                            since: rangeSince
                        )
                    }) {
                        projectRow(row)
                    }
                }
                HStack {
                    Text("\(rows.count) project\(rows.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField("Filter", text: searchBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 140)
            if !searchText.isEmpty {
                Button {
                    searchBinding.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(PacerDesign.cardStroke, lineWidth: 1)
        )
    }

    /// Column headers double as sort controls. Click an inactive column
    /// to make it the sort field; click the active column to flip
    /// direction. Visual: tracked uppercase label + a small chevron on
    /// the active column.
    private var tableHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            SortableColumnHeader(
                "Project",
                field: ProjectSort.name,
                alignment: .leading,
                active: sortFieldBinding,
                descending: sortDescendingBinding,
                defaultDescending: false
            )
            .padding(.leading, 8)

            Spacer()

            SortableColumnHeader(
                "Tokens",
                field: ProjectSort.tokens,
                alignment: .trailing,
                active: sortFieldBinding,
                descending: sortDescendingBinding
            ).frame(width: 100)
            SortableColumnHeader(
                "Sessions",
                field: ProjectSort.sessions,
                alignment: .trailing,
                active: sortFieldBinding,
                descending: sortDescendingBinding
            ).frame(width: 70)
            SortableColumnHeader(
                "Last",
                field: ProjectSort.lastActive,
                alignment: .trailing,
                active: sortFieldBinding,
                descending: sortDescendingBinding
            ).frame(width: 90)
            SortableColumnHeader(
                "Cost",
                field: ProjectSort.cost,
                alignment: .trailing,
                active: sortFieldBinding,
                descending: sortDescendingBinding
            ).frame(width: 84)
        }
        .padding(.trailing, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func projectRow(_ row: ProjectRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(row.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(pacerTokens(row.totalTokens))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)
            Text("\(row.sessionCount)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(pacerRelative(row.lastActive))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(pacerCost(row.cost))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
    }

    private func legendColor(_ idx: Int) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .red, .purple, .pink, .teal, .yellow]
        return palette[idx % palette.count]
    }
}
