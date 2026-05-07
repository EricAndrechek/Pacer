import SwiftUI
import SwiftData
import Charts
import PacerCore

/// What field to sort the per-session table by. Persists per-table
/// in the App Group store (`pacer.projectDetail.sessionsSortField`).
enum SessionsSort: String, CaseIterable, Identifiable {
    case id, model, tokens, cost, lastSeen
    var id: String { rawValue }
}

/// Drill-down for a single project. Presented as a sheet from
/// `ProjectsView`. Shows:
///   - Cost / tokens summary headline
///   - Daily-cost mini-chart over the visible range
///   - Models-used pie chart
///   - Recent sessions list (sessionId, last seen, model)
///
/// Reads `ProjectDailyAggregate` and `SessionInfo` directly — both are
/// precomputed by the in-process scan's recomputers, so the view never
/// iterates raw `TokenSample`s.
struct ProjectDetailView: View {
    let projectPath: String
    let displayName: String
    let since: Date?

    @Environment(\.dismissModal) private var dismissModal
    @Query private var aggregates: [ProjectDailyAggregate]
    @Query private var sessionRows: [SessionInfo]

    init(projectPath: String, displayName: String, since: Date?) {
        self.projectPath = projectPath
        self.displayName = displayName
        self.since = since
        let path = projectPath
        if let cutoffDate = since {
            let cutoffString = TokenSample.formatDate(cutoffDate)
            _aggregates = Query(
                filter: #Predicate<ProjectDailyAggregate> {
                    $0.projectPath == path && $0.date >= cutoffString
                },
                sort: \.date
            )
            _sessionRows = Query(
                filter: #Predicate<SessionInfo> {
                    $0.projectPath == path && $0.lastSeenAt >= cutoffDate
                },
                sort: \.lastSeenAt,
                order: .reverse
            )
        } else {
            _aggregates = Query(
                filter: #Predicate<ProjectDailyAggregate> { $0.projectPath == path },
                sort: \.date
            )
            _sessionRows = Query(
                filter: #Predicate<SessionInfo> { $0.projectPath == path },
                sort: \.lastSeenAt,
                order: .reverse
            )
        }
    }

    private struct Totals {
        var cost: Double = 0
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
    }

    private var totals: Totals {
        var t = Totals()
        for r in aggregates {
            t.cost += r.totalCostUSD
            t.input += r.inputTokens
            t.output += r.outputTokens
            t.cacheRead += r.cacheReadTokens
        }
        return t
    }

    private struct DayPoint: Identifiable {
        let date: String
        let cost: Double
        let tokens: Int64
        var id: String { date }
    }

    private var dailySeries: [DayPoint] {
        aggregates.map { r in
            DayPoint(
                date: r.date,
                cost: r.totalCostUSD,
                tokens: r.inputTokens + r.outputTokens + r.cacheReadTokens
            )
        }
    }

    private struct ModelSlice: Identifiable {
        let model: String
        let tokens: Int64
        let cost: Double
        var id: String { model }
    }

    private var modelSlices: [ModelSlice] {
        var byModel: [String: (tokens: Int64, cost: Double)] = [:]
        let decoder = JSONDecoder()
        for r in aggregates {
            if let tokens = try? decoder.decode([String: Int64].self, from: r.modelTokensJSON) {
                for (model, t) in tokens {
                    byModel[model, default: (0, 0)].tokens += t
                }
            }
            if let costs = try? decoder.decode([String: Double].self, from: r.modelCostJSON) {
                for (model, c) in costs {
                    byModel[model, default: (0, 0)].cost += c
                }
            }
        }
        return byModel.map { (model, v) in
            ModelSlice(model: model, tokens: v.tokens, cost: v.cost)
        }.sorted { $0.tokens > $1.tokens }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                header
                summaryCard
                if !dailySeries.isEmpty { dailyChartCard }
                if !modelSlices.isEmpty { modelsCard }
                if !sessionRows.isEmpty { sessionsCard }
            }
            .padding(24)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 540, idealHeight: 720)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(projectPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            // Convenience for the user — jump to the project directory
            // in Finder. Disabled for the synthetic "(unknown)" path
            // that Pacer uses for samples whose JSONL line lacks `cwd`.
            if projectPath != ProjectDailyAggregate.unknownProjectPath {
                Button {
                    let url = URL(fileURLWithPath: projectPath)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                        .font(.system(size: 12))
                }
                .help("Open this project's folder in Finder")
            }
            Button("Close") { dismissModal() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var summaryCard: some View {
        let t = totals
        return PacerCard("Summary") {
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
                MetricTile(value: "\(aggregates.count)", label: "active days")
            }
        }
    }

    @State private var hoveredDate: String?

    private var dailyChartCard: some View {
        PacerCard("Daily activity", trailing: {
            // Hover swaps the trailing slot to show the selected
            // bar's date + cost — same pattern as DailyCostChartCard.
            // Keeps the chart's plot area a fixed height regardless of
            // hover state; the previous "annotation on rule mark" path
            // pushed the bars up and down on every hover.
            if let d = hoveredDate, let row = dailySeries.first(where: { $0.date == d }) {
                HStack(spacing: 8) {
                    Text(row.date)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(pacerCost(row.cost))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }) {
            Chart {
                ForEach(dailySeries) { d in
                    BarMark(
                        x: .value("Date", d.date),
                        y: .value("Cost", d.cost)
                    )
                    .foregroundStyle(.tint)
                    .cornerRadius(1.5)
                }
                if let h = hoveredDate, dailySeries.contains(where: { $0.date == h }) {
                    RuleMark(x: .value("Selected", h))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            .frame(height: 160)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(pacerCost(v))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                // Show every Nth date label so the axis isn't crowded
                // on long ranges. With ~90 days at default range, 10
                // strides ≈ 9 labels; reads well at the card's width.
                AxisMarks(values: stridedDailySeriesDates(every: max(dailySeries.count / 9, 1))) { value in
                    AxisValueLabel {
                        if let date = value.as(String.self) {
                            Text(shortDailyDate(date))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXSelection(value: $hoveredDate)
        }
    }

    private func stridedDailySeriesDates(every n: Int) -> [String] {
        guard !dailySeries.isEmpty, n > 0 else { return [] }
        return stride(from: 0, to: dailySeries.count, by: n).map { dailySeries[$0].date }
    }

    /// `2026-04-30` → `04-30`. Year omitted at this density; user
    /// already has page context (the project detail header shows the
    /// time range).
    private func shortDailyDate(_ ymd: String) -> String {
        guard ymd.count == 10 else { return ymd }
        return String(ymd.suffix(5))
    }

    @State private var hoveredModelAngle: Double?

    private var hoveredModelSlice: ModelSlice? {
        guard let angle = hoveredModelAngle, !modelSlices.isEmpty else { return nil }
        var cumulative = 0.0
        for slice in modelSlices {
            cumulative += Double(slice.tokens)
            if angle <= cumulative { return slice }
        }
        return modelSlices.last
    }

    private var modelsCard: some View {
        let total = modelSlices.reduce(Int64(0)) { $0 + $1.tokens }
        return PacerCard("Models", trailing: {
            if let m = hoveredModelSlice {
                let pct = total > 0 ? Int(Double(m.tokens) / Double(total) * 100) : 0
                HStack(spacing: 6) {
                    Text(pacerShortModel(m.model))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(pacerTokens(m.tokens))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("(\(pct)%)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }) {
            HStack(alignment: .top, spacing: 24) {
                Chart(modelSlices) { m in
                    SectorMark(
                        angle: .value("tokens", m.tokens),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Model", pacerShortModel(m.model)))
                    .cornerRadius(2)
                    .opacity(hoveredModelSlice.map { $0.id == m.id ? 1.0 : 0.45 } ?? 1.0)
                }
                .frame(width: 160, height: 160)
                .chartLegend(.hidden)
                .chartAngleSelection(value: $hoveredModelAngle)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(modelSlices) { m in
                        HStack(alignment: .firstTextBaseline) {
                            Text(pacerShortModel(m.model))
                                .font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 8)
                            Text(pacerTokens(m.tokens))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            if total > 0 {
                                Text("\(Int(Double(m.tokens) / Double(total) * 100))%")
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

    @AppStorage("pacer.projectDetail.sessionsSortField", store: PacerSettings.store)
    private var sessionsSortRaw: String = SessionsSort.lastSeen.rawValue
    @AppStorage("pacer.projectDetail.sessionsSortDescending", store: PacerSettings.store)
    private var sessionsSortDescending: Bool = true

    private var sessionsSort: SessionsSort {
        SessionsSort(rawValue: sessionsSortRaw) ?? .lastSeen
    }
    private var sessionsSortBinding: Binding<SessionsSort> {
        Binding(get: { sessionsSort }, set: { sessionsSortRaw = $0.rawValue })
    }

    private var sortedSessions: [SessionInfo] {
        let sorted: [SessionInfo]
        switch sessionsSort {
        case .id:
            sorted = sessionRows.sorted { $0.sessionId < $1.sessionId }
        case .model:
            sorted = sessionRows.sorted { $0.topModel < $1.topModel }
        case .tokens:
            sorted = sessionRows.sorted { $0.totalTokens < $1.totalTokens }
        case .cost:
            sorted = sessionRows.sorted { $0.cumulativeCostUSD < $1.cumulativeCostUSD }
        case .lastSeen:
            sorted = sessionRows.sorted { $0.lastSeenAt < $1.lastSeenAt }
        }
        return sessionsSortDescending ? sorted.reversed() : sorted
    }

    private var sessionsCard: some View {
        PacerCard("Sessions", trailing: {
            Text("\(sessionRows.count) total")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }) {
            VStack(alignment: .leading, spacing: 4) {
                sessionsHeader
                Divider().padding(.vertical, 2)
                // Inner scroll for the full list. The modal's outer
                // height is bounded by the dismissibleModal frame, so
                // showing every session needs an inner scrollable
                // region — without this we either showed "and X more"
                // pointing at nothing the user could reach, or the
                // modal stretched off-screen on big projects.
                if sortedSessions.count <= 12 {
                    // Tiny enough — no inner scroll needed.
                    ForEach(sortedSessions, id: \.sessionId) { row in
                        sessionRowView(row)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(sortedSessions, id: \.sessionId) { row in
                                sessionRowView(row)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .scrollIndicators(.automatic)
                }
            }
        }
    }

    private var sessionsHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            SortableColumnHeader(
                "ID",
                field: SessionsSort.id,
                alignment: .leading,
                active: sessionsSortBinding,
                descending: $sessionsSortDescending,
                defaultDescending: false
            ).frame(width: 80, alignment: .leading)
            SortableColumnHeader(
                "Model",
                field: SessionsSort.model,
                alignment: .leading,
                active: sessionsSortBinding,
                descending: $sessionsSortDescending,
                defaultDescending: false
            ).frame(maxWidth: 220, alignment: .leading)
            Spacer()
            SortableColumnHeader(
                "Tokens",
                field: SessionsSort.tokens,
                alignment: .trailing,
                active: sessionsSortBinding,
                descending: $sessionsSortDescending
            ).frame(width: 80)
            SortableColumnHeader(
                "Cost",
                field: SessionsSort.cost,
                alignment: .trailing,
                active: sessionsSortBinding,
                descending: $sessionsSortDescending
            ).frame(width: 70)
            SortableColumnHeader(
                "Last seen",
                field: SessionsSort.lastSeen,
                alignment: .trailing,
                active: sessionsSortBinding,
                descending: $sessionsSortDescending
            ).frame(width: 80)
            // Reserve room for the transcript-icon column so the
            // header columns line up with the row body.
            Spacer().frame(width: 24)
        }
    }

    @ViewBuilder
    private func sessionRowView(_ row: SessionInfo) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(String(row.sessionId.prefix(8)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(pacerShortModel(row.topModel))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
            Spacer(minLength: 8)
            Text(pacerTokens(row.totalTokens))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Text(pacerCost(row.cumulativeCostUSD))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(pacerRelative(row.lastSeenAt))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .trailing)
            // Reveal-transcript button. Walks `~/.claude/projects/*`
            // looking for `<sessionId>.jsonl` (subagent worktrees write
            // into a different encoded-cwd directory than the parent
            // project, so a literal lookup against `projectPath`
            // wouldn't work — we have to search). On hit, open Finder
            // selecting the file. Disabled-look when not found.
            Button {
                openTranscript(for: row.sessionId)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Reveal transcript JSONL in Finder")
            .frame(width: 24, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    /// Open Finder selecting the session's JSONL transcript. Searches
    /// every `~/.claude/projects/*` because canonicalized projects
    /// (worktree-spawned agents) live under a different encoded-cwd
    /// directory than the project they're attributed to.
    private func openTranscript(for sessionId: String) {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) {
                NSWorkspace.shared.activateFileViewerSelecting([candidate])
                return
            }
        }
    }
}
