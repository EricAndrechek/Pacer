import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

// Sort enum was forked into the shared SessionsTable component; this
// view now reuses `SessionsTableSort` directly.

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
    @Environment(\.pacerModalPush) private var push
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
        .scrollIndicators(.never)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 540, idealHeight: 720)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            PacerModalBackButton()
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.title)
                    .fontWeight(.semibold)
                    .fontDesign(.rounded)
                Text(projectPath)
                    .font(.system(.caption, design: .monospaced))
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
                }
                .controlSize(.small)
                .help("Open this project's folder in Finder")
            }
            Button("Close") { dismissModal() }
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
            // Arrow cursor (default) per macOS HIG — clickable charts
            // don't warrant the link cursor.
            .contentShape(Rectangle())
            .onTapGesture {
                if let d = hoveredDate {
                    push(.day(date: d))
                }
            }
            .accessibilityLabel("Daily cost for \(displayName)")
            .accessibilityHint("Click a bar to drill into that day")
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

    /// VoiceOver alternative to the model donut — per-model token share
    /// read as a comma list.
    private func modelSlicesSummary(total: Int64) -> String {
        guard total > 0 else { return "no data" }
        return modelSlices.prefix(5).map { m in
            let pct = Int(Double(m.tokens) / Double(total) * 100)
            return "\(pacerShortModel(m.model)) \(pct) percent"
        }.joined(separator: ", ")
    }

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
                .accessibilityLabel("Model share for \(displayName)")
                .accessibilityValue(modelSlicesSummary(total: total))
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
    private var sessionsSortRaw: String = SessionsTableSort.lastSeen.rawValue
    @AppStorage("pacer.projectDetail.sessionsSortDescending", store: PacerSettings.store)
    private var sessionsSortDescending: Bool = true

    private var sessionsSort: SessionsTableSort {
        SessionsTableSort(rawValue: sessionsSortRaw) ?? .lastSeen
    }
    private var sessionsSortBinding: Binding<SessionsTableSort> {
        Binding(get: { sessionsSort }, set: { sessionsSortRaw = $0.rawValue })
    }

    private var sessionsCard: some View {
        PacerCard("Sessions", trailing: {
            Text("\(sessionRows.count) total")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }) {
            // Single shared sortable table. Project-detail hides the
            // "Project" column since the modal is already scoped to
            // one project; day-detail enables the same column.
            SessionsTable(
                rows: sessionRows,
                showProjectColumn: false,
                sort: sessionsSortBinding,
                sortDescending: $sessionsSortDescending,
                onSessionTap: { session in
                    push(.session(
                        sessionId: session.sessionId,
                        projectDisplayName: displayName
                    ))
                }
            )
        }
    }
}
