import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

/// Detail sheet for a single calendar day. Reachable from the History
/// tab's heatmap (click a cell). Shows cost / tokens summary, the
/// per-model donut breakdown for that day, and the projects active
/// that day.
struct DayDetailView: View {
    let date: String  // YYYY-MM-DD

    @Environment(\.dismissModal) private var dismissModal
    @Query private var aggregates: [DailyAggregate]
    @Query private var samples: [TokenSample]
    @Query private var sessionRows: [SessionInfo]
    @Query(DayDetailView.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    @State private var cached = Cached()

    init(date: String) {
        self.date = date
        _aggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == date }
        )
        _samples = Query(
            filter: #Predicate<TokenSample> { $0.date == date }
        )
        // Sessions that touched this day: overlap on [dayStart, dayEnd].
        // A session spanning multiple days shows up on every day it was
        // active. Filter via lastSeenAt ≥ dayStart AND firstSeenAt < dayEnd.
        let dayStart = Self.startOfDay(for: date)
        let dayEnd = dayStart.addingTimeInterval(86400)
        _sessionRows = Query(
            filter: #Predicate<SessionInfo> {
                $0.lastSeenAt >= dayStart && $0.firstSeenAt < dayEnd
            },
            sort: \.lastSeenAt,
            order: .reverse
        )
    }

    /// Local-midnight Date for a YYYY-MM-DD key. Falls back to
    /// distantPast on parse failure so a malformed date key just
    /// surfaces an empty sessions list rather than crashing.
    private static func startOfDay(for ymd: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd) ?? .distantPast
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private struct Totals {
        var cost: Double = 0
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheCreation: Int64 = 0
    }

    private struct ProjectRow: Identifiable {
        let path: String
        let displayName: String
        let cost: Double
        let tokens: Int64
        var id: String { path }
    }

    private struct Cached {
        var totals = Totals()
        var projectRows: [ProjectRow] = []
    }

    private var totals: Totals { cached.totals }
    private var projectRows: [ProjectRow] { cached.projectRows }

    @MainActor
    private func refreshCache() {
        var t = Totals()
        for r in aggregates {
            t.cost += r.totalCostUSD
            t.input += r.inputTokens
            t.output += r.outputTokens
            t.cacheRead += r.cacheReadTokens
            t.cacheCreation += r.cacheCreation5mTokens + r.cacheCreation1hTokens
        }

        struct Acc {
            var cost: Double = 0
            var tokens: Int64 = 0
        }
        let mode = PacerPreferences.costMode()
        var byProject: [String: Acc] = [:]
        for s in samples {
            let key = s.projectPath ?? "(unknown)"
            var a = byProject[key] ?? Acc()
            // Single source of truth: TokenSample.effectiveCostUSD(mode:)
            // applies the same calculate/auto/display logic the
            // recomputers use, so the day modal shows the same number
            // as Projects/Models/Dashboard for the same data.
            a.cost += s.effectiveCostUSD(mode: mode)
            a.tokens += s.inputTokens + s.outputTokens + s.cacheReadTokens
            byProject[key] = a
        }
        // Stable sort: by cost desc, with displayName as a deterministic
        // tiebreaker so $0 rows don't shuffle on every scan tick.
        let rows = byProject.map { (key, a) in
            ProjectRow(
                path: key,
                displayName: pacerShortPath(key),
                cost: a.cost,
                tokens: a.tokens
            )
        }.sorted { lhs, rhs in
            if lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        cached = Cached(totals: t, projectRows: rows)

        // Refresh the donut hover index. Pre-sorts by cost desc and
        // builds the cumulative-angle table in one pass so hover
        // ticks are O(rows) over an already-built array.
        let sorted = aggregates.sorted { $0.totalCostUSD > $1.totalCostUSD }
        var running = 0.0
        var built: [(agg: DailyAggregate, max: Double)] = []
        built.reserveCapacity(sorted.count)
        for agg in sorted {
            running += agg.totalCostUSD
            built.append((agg, running))
        }
        sortedAggsByCost = sorted
        aggCumulative = built
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                header
                summaryCard
                if !aggregates.isEmpty { modelsCard }
                if !projectRows.isEmpty { projectsCard }
                if !sessionRows.isEmpty { sessionsCard }
            }
            .padding(24)
        }
        .scrollIndicators(.never)
        .frame(minWidth: 580, idealWidth: 660, minHeight: 480, idealHeight: 620)
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
        // Open the project's detail view stacked on top of this day
        // modal — keeps the user oriented in the day context they
        // started from. They can dismiss back into the day, or
        // chain through sessions inside the project view.
        .dismissibleModal(item: $selectedProject) { sel in
            ProjectDetailView(
                projectPath: sel.path,
                displayName: sel.displayName,
                since: sel.since
            )
        }
        .dismissibleModal(item: $selectedSession) { sel in
            SessionDetailView(session: sel.session, projectDisplayName: pacerShortPath(sel.session.projectPath))
        }
    }

    @State private var selectedProject: ProjectsView.SelectedProject?
    @State private var selectedSession: ProjectDetailView.SelectedSession?

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(prettyDate)
                    .font(.title)
                    .fontWeight(.semibold)
                    .fontDesign(.rounded)
                Text(date)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismissModal() }
                .keyboardShortcut(.cancelAction)
        }
    }

    /// `2026-04-30` → `Thursday, April 30, 2026`. Falls back to the raw
    /// key on parse failure.
    private var prettyDate: String {
        let inputFmt = DateFormatter()
        inputFmt.dateFormat = "yyyy-MM-dd"
        inputFmt.timeZone = .current
        guard let d = inputFmt.date(from: date) else { return date }
        let outFmt = DateFormatter()
        outFmt.dateStyle = .full
        outFmt.timeZone = .current
        return outFmt.string(from: d)
    }

    private var summaryCard: some View {
        let t = totals
        return PacerCard("Summary", trailing: {
            if aggregates.isEmpty {
                Text("no data")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }) {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                        count: 5
                    ),
                    alignment: .leading,
                    spacing: 12
                ) {
                    MetricTile(value: pacerCost(t.cost), label: "cost", size: .hero)
                    MetricTile(value: pacerTokens(t.input), label: "input")
                    MetricTile(value: pacerTokens(t.output), label: "output")
                    MetricTile(value: pacerTokens(t.cacheRead), label: "cache read")
                    MetricTile(value: pacerTokens(t.cacheCreation), label: "cache write")
                }
                if t.cacheRead > 0 {
                    cacheRatioRow
                }
            }
        }
    }

    /// Cache-utilization line for this day. Same shape as the
    /// dashboard's TodayDetailsCard so the user sees the metric the
    /// same way regardless of which surface they're inspecting. Lets
    /// them click through expensive days from the heatmap and check
    /// whether caching was the lever that made them expensive.
    @ViewBuilder
    private var cacheRatioRow: some View {
        let t = totals
        let denom = Double(t.cacheRead + t.input)
        let r = denom > 0 ? Double(t.cacheRead) / denom : 0
        let pctText = String(format: "%.1f%%", r * 100)
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 13))
            Text("Cache hit rate")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 6)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * r, height: 6)
                }
                .frame(height: 6)
            }
            .frame(maxWidth: 220)
            Text(pctText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
    }

    @AppStorage("pacer.dayDetail.modelsSort", store: PacerSettings.store)
    private var modelsSortRaw: String = DayModelsSort.cost.rawValue
    @AppStorage("pacer.dayDetail.modelsSortDescending", store: PacerSettings.store)
    private var modelsSortDescending: Bool = true

    @AppStorage("pacer.dayDetail.projectsSort", store: PacerSettings.store)
    private var projectsSortRaw: String = DayProjectsSort.cost.rawValue
    @AppStorage("pacer.dayDetail.projectsSortDescending", store: PacerSettings.store)
    private var projectsSortDescending: Bool = true

    private var modelsSort: DayModelsSort {
        DayModelsSort(rawValue: modelsSortRaw) ?? .cost
    }
    private var projectsSort: DayProjectsSort {
        DayProjectsSort(rawValue: projectsSortRaw) ?? .cost
    }
    private var modelsSortBinding: Binding<DayModelsSort> {
        Binding(get: { modelsSort }, set: { modelsSortRaw = $0.rawValue })
    }
    private var projectsSortBinding: Binding<DayProjectsSort> {
        Binding(get: { projectsSort }, set: { projectsSortRaw = $0.rawValue })
    }

    private var sortedAggregates: [DailyAggregate] {
        // All sorts pin a deterministic tiebreaker (the model name) so
        // a column of equal values doesn't reshuffle each scan tick.
        let primary: (DailyAggregate, DailyAggregate) -> Bool
        switch modelsSort {
        case .name:
            primary = { $0.model < $1.model }
        case .tokens:
            let totalTokens: (DailyAggregate) -> Int64 = {
                $0.inputTokens + $0.outputTokens + $0.cacheReadTokens
            }
            primary = { totalTokens($0) < totalTokens($1) }
        case .cost:
            primary = { $0.totalCostUSD < $1.totalCostUSD }
        }
        let sorted = aggregates.sorted { lhs, rhs in
            if primary(lhs, rhs) { return true }
            if primary(rhs, lhs) { return false }
            return lhs.model < rhs.model
        }
        return modelsSortDescending ? sorted.reversed() : sorted
    }

    /// Tap handler on a day-detail project row: open the project's
    /// detail view stacked on top of the day modal so the user stays
    /// oriented in the day they came from. Skip the synthetic
    /// "(unknown)" path — there's no project to open.
    private func openProject(_ row: ProjectRow) {
        guard row.path != ProjectDailyAggregate.unknownProjectPath else { return }
        selectedProject = ProjectsView.SelectedProject(
            path: row.path,
            displayName: row.displayName,
            since: nil  // day detail has no time-range scope, so go all-time
        )
    }

    private var sortedProjectRows: [ProjectRow] {
        let primary: (ProjectRow, ProjectRow) -> Bool
        switch projectsSort {
        case .name:
            primary = { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .tokens:
            primary = { $0.tokens < $1.tokens }
        case .cost:
            primary = { $0.cost < $1.cost }
        }
        let sorted = projectRows.sorted { lhs, rhs in
            if primary(lhs, rhs) { return true }
            if primary(rhs, lhs) { return false }
            return lhs.path < rhs.path
        }
        return projectsSortDescending ? sorted.reversed() : sorted
    }

    @State private var hoveredAggAngle: Double?

    /// Pre-sorted aggregates + cumulative-angle table for the donut.
    /// Recomputed in `refreshCache()`; hover lookups walk the table
    /// without re-sorting. Without this every hover tick was an
    /// N·log(N) sort + a fresh `cumulative += ...` loop.
    @State private var sortedAggsByCost: [DailyAggregate] = []
    @State private var aggCumulative: [(agg: DailyAggregate, max: Double)] = []

    /// VoiceOver summary of the per-model donut for this day.
    private var modelsAccessibilitySummary: String {
        let total = aggregates.reduce(0) { $0 + $1.totalCostUSD }
        guard total > 0 else { return "no data" }
        return sortedAggsByCost.prefix(5).map { agg in
            let pct = Int(agg.totalCostUSD / total * 100)
            return "\(pacerShortModel(agg.model)) \(pct) percent"
        }.joined(separator: ", ")
    }

    private var hoveredAgg: DailyAggregate? {
        guard let angle = hoveredAggAngle, !aggCumulative.isEmpty else { return nil }
        for entry in aggCumulative where angle <= entry.max {
            return entry.agg
        }
        return aggCumulative.last?.agg
    }

    private var modelsCard: some View {
        PacerCard("Models", trailing: {
            if let agg = hoveredAgg {
                let total = aggregates.reduce(0) { $0 + $1.totalCostUSD }
                let pct = total > 0 ? Int(agg.totalCostUSD / total * 100) : 0
                HStack(spacing: 6) {
                    Text(pacerShortModel(agg.model))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(pacerCost(agg.totalCostUSD))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("(\(pct)%)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }) {
            HStack(alignment: .top, spacing: 24) {
                // Use pre-sorted aggregates from the cache so we don't
                // re-sort the array on every body render (which fired
                // on every hover tick before).
                Chart(sortedAggsByCost, id: \.dateModelKey) { agg in
                    SectorMark(
                        angle: .value("Cost", agg.totalCostUSD),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Model", pacerShortModel(agg.model)))
                    .cornerRadius(2)
                    .opacity(hoveredAgg.map { $0.dateModelKey == agg.dateModelKey ? 1.0 : 0.45 } ?? 1.0)
                }
                .frame(width: 160, height: 160)
                .chartLegend(.hidden)
                .chartAngleSelection(value: $hoveredAggAngle)
                .accessibilityLabel("Models used on \(prettyDate)")
                .accessibilityValue(modelsAccessibilitySummary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        SortableColumnHeader(
                            "Model",
                            field: DayModelsSort.name,
                            alignment: .leading,
                            active: modelsSortBinding,
                            descending: $modelsSortDescending,
                            defaultDescending: false
                        )
                        Spacer()
                        SortableColumnHeader(
                            "Tokens",
                            field: DayModelsSort.tokens,
                            alignment: .trailing,
                            active: modelsSortBinding,
                            descending: $modelsSortDescending
                        ).frame(width: 70)
                        SortableColumnHeader(
                            "Cost",
                            field: DayModelsSort.cost,
                            alignment: .trailing,
                            active: modelsSortBinding,
                            descending: $modelsSortDescending
                        ).frame(width: 70)
                    }
                    Divider().padding(.vertical, 2)
                    let total = aggregates.reduce(0) { $0 + $1.totalCostUSD }
                    ForEach(sortedAggregates, id: \.dateModelKey) { agg in
                        HStack(alignment: .firstTextBaseline) {
                            Text(pacerShortModel(agg.model))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(pacerTokens(agg.inputTokens + agg.outputTokens + agg.cacheReadTokens))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                            Text(pacerCost(agg.totalCostUSD))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                            if total > 0 {
                                Text("\(Int(agg.totalCostUSD / total * 100))%")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    private var projectsCard: some View {
        PacerCard("Projects", trailing: {
            Text("\(projectRows.count) project\(projectRows.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SortableColumnHeader(
                        "Project",
                        field: DayProjectsSort.name,
                        alignment: .leading,
                        active: projectsSortBinding,
                        descending: $projectsSortDescending,
                        defaultDescending: false
                    )
                    Spacer()
                    SortableColumnHeader(
                        "Tokens",
                        field: DayProjectsSort.tokens,
                        alignment: .trailing,
                        active: projectsSortBinding,
                        descending: $projectsSortDescending
                    ).frame(width: 90)
                    SortableColumnHeader(
                        "Cost",
                        field: DayProjectsSort.cost,
                        alignment: .trailing,
                        active: projectsSortBinding,
                        descending: $projectsSortDescending
                    ).frame(width: 70)
                }
                Divider().padding(.vertical, 2)
                ForEach(sortedProjectRows) { row in
                    HoverRow(action: { openProject(row) }) {
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
                            Text(pacerTokens(row.tokens))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 90, alignment: .trailing)
                            Text(pacerCost(row.cost))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, alignment: .trailing)
                        }
                    }
                    .contextMenu {
                        if row.path != ProjectDailyAggregate.unknownProjectPath {
                            Button("Open project") { openProject(row) }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: row.path)]
                                )
                            }
                            Divider()
                        }
                        Button("Copy path") { pacerCopyToPasteboard(row.path) }
                        Button("Copy cost") { pacerCopyToPasteboard(pacerCost(row.cost)) }
                    }
                }
            }
        }
    }

    @AppStorage("pacer.dayDetail.sessionsSort", store: PacerSettings.store)
    private var sessionsSortRaw: String = SessionsTableSort.cost.rawValue
    @AppStorage("pacer.dayDetail.sessionsSortDescending", store: PacerSettings.store)
    private var sessionsSortDescending: Bool = true

    private var sessionsSort: SessionsTableSort {
        SessionsTableSort(rawValue: sessionsSortRaw) ?? .cost
    }
    private var sessionsSortBinding: Binding<SessionsTableSort> {
        Binding(get: { sessionsSort }, set: { sessionsSortRaw = $0.rawValue })
    }

    /// Sessions active on this day — same shared SessionsTable that
    /// the project modal uses, with the "Project" column enabled
    /// because a day spans many projects. All rows reachable via the
    /// table's inner scroll once the count exceeds the inline
    /// threshold; no more "+N more" dead-end.
    private var sessionsCard: some View {
        PacerCard("Sessions", trailing: {
            Text("\(sessionRows.count) on this day")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }) {
            SessionsTable(
                rows: sessionRows,
                showProjectColumn: true,
                sort: sessionsSortBinding,
                sortDescending: $sessionsSortDescending,
                onSessionTap: {
                    selectedSession = ProjectDetailView.SelectedSession(session: $0)
                }
            )
        }
    }
}

/// Sort fields for the Day detail's Models / Projects mini-tables.
enum DayModelsSort: String, CaseIterable, Identifiable {
    case name, tokens, cost
    var id: String { rawValue }
}

enum DayProjectsSort: String, CaseIterable, Identifiable {
    case name, tokens, cost
    var id: String { rawValue }
}
