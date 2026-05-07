import SwiftUI
import SwiftData
import Charts
import PacerCore

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

    @Environment(\.dismiss) private var dismiss
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
            Button("Close") { dismiss() }
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

    private var dailyChartCard: some View {
        PacerCard("Daily activity") {
            Chart(dailySeries) { d in
                BarMark(
                    x: .value("Date", d.date),
                    y: .value("Cost", d.cost)
                )
                .foregroundStyle(.tint)
                .cornerRadius(1.5)
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
            .chartXAxis(.hidden)
        }
    }

    private var modelsCard: some View {
        PacerCard("Models") {
            HStack(alignment: .top, spacing: 24) {
                Chart(modelSlices) { m in
                    SectorMark(
                        angle: .value("tokens", m.tokens),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Model", pacerShortModel(m.model)))
                    .cornerRadius(2)
                }
                .frame(width: 160, height: 160)
                .chartLegend(.hidden)
                VStack(alignment: .leading, spacing: 6) {
                    let total = modelSlices.reduce(Int64(0)) { $0 + $1.tokens }
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

    private var sessionsCard: some View {
        PacerCard("Sessions", trailing: {
            Text("\(sessionRows.count) total")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(sessionRows.prefix(20)), id: \.sessionId) { row in
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
                            .frame(width: 90, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
                if sessionRows.count > 20 {
                    Text("…and \(sessionRows.count - 20) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
        }
    }
}
