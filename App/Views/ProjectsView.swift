import SwiftUI
import SwiftData
import Charts
import PacerCore

/// Per-project breakdown. Reads `ProjectDailyAggregate` (precomputed by
/// the in-process scan) so the table is sub-10ms even on populated
/// installs, and never iterates raw `TokenSample`s.
///
/// Range picker controls how far back to look (persisted across
/// launches via @AppStorage). Sort picker controls the table's
/// primary order. Filter field narrows the list by path. Click a
/// project to drill into the detail sheet.
struct ProjectsView: View {
    @AppStorage(PacerSettings.Key.timeRange, store: PacerSettings.store)
    private var rangeRaw: String = TimeRange.ninetyDays.rawValue

    @AppStorage(PacerSettings.Key.projectsSort, store: PacerSettings.store)
    private var sortRaw: String = ProjectSort.cost.rawValue

    @State private var searchText: String = ""

    private var range: TimeRange {
        TimeRange(rawValue: rangeRaw) ?? .ninetyDays
    }
    private var sort: ProjectSort {
        ProjectSort(rawValue: sortRaw) ?? .cost
    }

    var body: some View {
        PageScaffold("Projects", subtitle: "Per-project rollup of cost and tokens.", trailing: {
            rangePicker
        }) {
            HStack(spacing: 12) {
                searchField
                sortPicker
            }
            // Re-key on (range, sort) so the inner view's @Query
            // rebuilds with a fresh predicate when either changes.
            ProjectsContent(
                range: range,
                sort: sort,
                searchText: searchText
            )
            .id("\(range.rawValue)|\(sort.rawValue)")
        }
    }

    private var rangePicker: some View {
        Picker("", selection: rangeBinding) {
            ForEach(TimeRange.allCases) { r in
                Text(r.label).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        .controlSize(.small)
        .labelsHidden()
    }

    private var rangeBinding: Binding<TimeRange> {
        Binding(
            get: { range },
            set: { rangeRaw = $0.rawValue }
        )
    }

    private var sortBinding: Binding<ProjectSort> {
        Binding(
            get: { sort },
            set: { sortRaw = $0.rawValue }
        )
    }

    private var sortPicker: some View {
        Menu {
            ForEach(ProjectSort.allCases) { s in
                Button {
                    sortRaw = s.rawValue
                } label: {
                    if s == sort {
                        Label(s.label, systemImage: "checkmark")
                    } else {
                        Text(s.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                Text("Sort: \(sort.label)")
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(PacerDesign.cardStroke, lineWidth: 1)
        )
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Filter projects by path", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(PacerDesign.cardStroke, lineWidth: 1)
        )
    }
}

/// What column the Projects table sorts by. Persisted via
/// `PacerSettings.Key.projectsSort`. Hooked up in the toolbar Menu so
/// the user can switch without re-rendering the entire page tree.
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
        case .name:       return "Name"
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

    init(range: TimeRange, sort: ProjectSort, searchText: String = "") {
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
        switch sort {
        case .cost:
            return unsorted.sorted { $0.cost > $1.cost }
        case .tokens:
            return unsorted.sorted { $0.totalTokens > $1.totalTokens }
        case .sessions:
            return unsorted.sorted { $0.sessionCount > $1.sessionCount }
        case .lastActive:
            return unsorted.sorted { $0.lastActive > $1.lastActive }
        case .name:
            return unsorted.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
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
        .sheet(item: $selected) { sel in
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

    private var overviewCard: some View {
        PacerCard("Top projects by cost") {
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
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(top.enumerated()), id: \.offset) { idx, row in
                        HStack(alignment: .firstTextBaseline) {
                            Circle()
                                .fill(legendColor(idx))
                                .frame(width: 8, height: 8)
                            Text(row.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: 220, alignment: .leading)
                            Spacer(minLength: 8)
                            Text(pacerCost(row.cost))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                            if totalCost > 0 {
                                Text("\(Int((row.cost / totalCost * 100).rounded()))%")
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

    private var projectListCard: some View {
        PacerCard("All projects", trailing: {
            Text("\(rows.count) project\(rows.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
            }
        }
    }

    private var tableHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Eyebrow(text: "Project")
                .padding(.leading, 8)
            Spacer()
            Eyebrow(text: "Tokens").frame(width: 100, alignment: .trailing)
            Eyebrow(text: "Sessions").frame(width: 70, alignment: .trailing)
            Eyebrow(text: "Last").frame(width: 90, alignment: .trailing)
            Eyebrow(text: "Cost").frame(width: 84, alignment: .trailing)
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
