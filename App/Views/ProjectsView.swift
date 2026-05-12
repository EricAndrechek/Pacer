import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

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
    /// Lifted from ProjectsContent so the dismissibleModal modifier
    /// can attach OUTSIDE the PageScaffold's ScrollView. Without
    /// lifting this state up, the modal overlay sat inside the
    /// ScrollView's content frame and (a) scrolled with the page,
    /// (b) added empty padding to the bottom of the scrollable area
    /// equal to the modal's frame.
    @State private var selectedProject: SelectedProject?

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
                selectedBinding: $selectedProject
            )
            .id("\(range.rawValue)")
        }
        // Native macOS search field lives in the window toolbar — frees
        // the card header from the custom magnifying-glass + xmark
        // arrangement we built by hand, and gets the standard search
        // chrome (clear button, placeholder, a11y) for free. Each
        // sidebar destination has its own toolbar context inside the
        // NavigationSplitView, so the field only appears while
        // Projects is the active destination.
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "Filter projects"
        )
        .dismissibleModal(item: $selectedProject) { sel in
            ProjectDetailView(
                projectPath: sel.path,
                displayName: sel.displayName,
                since: sel.since
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .pacerOpenProject)) { note in
            // DayDetailView posts this when the user clicks a project
            // row inside the day modal. We open the project modal
            // immediately; the day modal is responsible for dismissing
            // itself before posting.
            if let req = note.object as? SelectedProject {
                selectedProject = req
            }
        }
    }

    /// Identifies the project the user clicked into. Lives at this
    /// level so the modal stays out of the scroll content.
    struct SelectedProject: Identifiable {
        let path: String
        let displayName: String
        let since: Date?
        var id: String { path }
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

    let rangeSince: Date?
    let searchText: String
    let sort: ProjectSort
    let descending: Bool
    let overviewMetric: ProjectMetric

    let rangeBinding: Binding<TimeRange>
    let sortFieldBinding: Binding<ProjectSort>
    let sortDescendingBinding: Binding<Bool>
    let overviewMetricBinding: Binding<ProjectMetric>
    let selectedBinding: Binding<ProjectsView.SelectedProject?>

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
        selectedBinding: Binding<ProjectsView.SelectedProject?>
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
        self.selectedBinding = selectedBinding
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
        // Closures take an `(lhs, rhs)` and return ascending order. We
        // chain a deterministic tiebreaker (path) into every primary
        // comparison so rows with equal primary values don't shuffle
        // when SwiftData refreshes — concretely, before the
        // tiebreaker, all-$0 day-detail / 0-token projects swapped
        // positions on every scan tick.
        let primary: (ProjectRow, ProjectRow) -> Bool
        switch sort {
        case .cost:
            primary = { $0.cost < $1.cost }
        case .tokens:
            primary = { $0.totalTokens < $1.totalTokens }
        case .sessions:
            primary = { $0.sessionCount < $1.sessionCount }
        case .lastActive:
            primary = { $0.lastActive < $1.lastActive }
        case .name:
            primary = { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        let sorted = rows.sorted { lhs, rhs in
            if primary(lhs, rhs) { return true }
            if primary(rhs, lhs) { return false }
            // Deterministic tiebreaker: path (always unique per row).
            return lhs.path < rhs.path
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
        // No more `.dismissibleModal` here — it lives on the outer
        // ProjectsView so the overlay sits ABOVE the PageScaffold's
        // ScrollView rather than inside its content. This view just
        // sets the binding when the user picks a project; the parent
        // owns the modal layer.
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
    @State private var hoveredOverviewAngle: Double?

    /// Cumulative-angle index over the top-5 rows for the active
    /// metric. Derived synchronously so a Projects-tab mount renders
    /// the donut at its real size on the first frame — the previous
    /// @State + .onAppear pattern showed an empty donut briefly, then
    /// snapped to the populated layout one tick later.
    private var overviewIndex: (cumulative: [(row: ProjectRow, max: Double)], total: Double) {
        let top = Array(rows.prefix(5))
        var running = 0.0
        var built: [(row: ProjectRow, max: Double)] = []
        built.reserveCapacity(top.count)
        for row in top {
            running += value(for: overviewMetric, in: row)
            built.append((row, running))
        }
        return (built, running)
    }

    private func hoveredOverviewProject(cumulative: [(row: ProjectRow, max: Double)]) -> ProjectRow? {
        guard let angle = hoveredOverviewAngle, !cumulative.isEmpty else { return nil }
        for entry in cumulative where angle <= entry.max {
            return entry.row
        }
        return cumulative.last?.row
    }

    private var overviewCard: some View {
        let top = Array(rows.prefix(5))
        let index = overviewIndex
        let totalForMetric = index.total
        let hovered = hoveredOverviewProject(cumulative: index.cumulative)
        return PacerCard("Top projects", trailing: {
            HStack(spacing: 12) {
                if let h = hovered {
                    let v = value(for: overviewMetric, in: h)
                    let pct = totalForMetric > 0 ? Int(v / totalForMetric * 100) : 0
                    HStack(spacing: 6) {
                        Text(h.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(formatMetric(v, kind: overviewMetric))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("(\(pct)%)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Picker("Overview metric", selection: overviewMetricBinding) {
                    ForEach(ProjectMetric.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .controlSize(.small)
                .labelsHidden()
            }
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
                    .opacity(hovered.map { $0.id == row.id ? 1.0 : 0.45 } ?? 1.0)
                }
                .frame(width: 160, height: 160)
                .chartLegend(.hidden)
                .chartAngleSelection(value: $hoveredOverviewAngle)
                .accessibilityLabel("Top 5 projects by \(overviewMetric.label)")
                .accessibilityValue(topProjectsSummary(top: top, total: totalForMetric))
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

    /// VoiceOver alternative to the donut. Lists each top project with
    /// its share of the active metric, comma-separated.
    private func topProjectsSummary(top: [ProjectRow], total: Double) -> String {
        guard total > 0 else { return "no data yet" }
        return top.map { row in
            let v = value(for: overviewMetric, in: row)
            let pct = Int((v / total * 100).rounded())
            return "\(row.displayName) \(pct) percent"
        }.joined(separator: ", ")
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
    ///
    /// The text filter moved out of the card trailing into the window
    /// toolbar via `.searchable` on the parent view — gives users the
    /// native macOS search field (system clear button, accessibility
    /// label, placement consistency with Mail / Finder / Notes).
    private var projectListCard: some View {
        PacerCard("All projects", trailing: {
            HStack(spacing: 10) {
                Picker("Time range", selection: rangeBinding) {
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
                        selectedBinding.wrappedValue = ProjectsView.SelectedProject(
                            path: row.path,
                            displayName: row.displayName,
                            since: rangeSince
                        )
                    }) {
                        projectRow(row)
                    }
                    .contextMenu {
                        Button("Open project") {
                            selectedBinding.wrappedValue = ProjectsView.SelectedProject(
                                path: row.path,
                                displayName: row.displayName,
                                since: rangeSince
                            )
                        }
                        if row.path != ProjectDailyAggregate.unknownProjectPath {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: row.path)]
                                )
                            }
                        }
                        Divider()
                        Button("Copy path") {
                            pacerCopyToPasteboard(row.path)
                        }
                        Button("Copy display name") {
                            pacerCopyToPasteboard(row.displayName)
                        }
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
