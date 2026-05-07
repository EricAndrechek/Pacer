import SwiftUI
import SwiftData
import Charts
import PacerCore

/// Detail sheet for a single calendar day. Reachable from the History
/// tab's heatmap (click a cell). Shows cost / tokens summary, the
/// per-model donut breakdown for that day, and the projects active
/// that day.
struct DayDetailView: View {
    let date: String  // YYYY-MM-DD

    @Environment(\.dismissModal) private var dismissModal
    @Query private var aggregates: [DailyAggregate]
    @Query private var samples: [TokenSample]
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
        var byProject: [String: Acc] = [:]
        for s in samples {
            let key = s.projectPath ?? "(unknown)"
            var a = byProject[key] ?? Acc()
            a.cost += s.sourceCostUSD ?? 0
            a.tokens += s.inputTokens + s.outputTokens + s.cacheReadTokens
            byProject[key] = a
        }
        let rows = byProject.map { (key, a) in
            ProjectRow(
                path: key,
                displayName: pacerShortPath(key),
                cost: a.cost,
                tokens: a.tokens
            )
        }.sorted { $0.cost > $1.cost }

        cached = Cached(totals: t, projectRows: rows)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
                header
                summaryCard
                if !aggregates.isEmpty { modelsCard }
                if !projectRows.isEmpty { projectsCard }
            }
            .padding(24)
        }
        .frame(minWidth: 580, idealWidth: 660, minHeight: 480, idealHeight: 620)
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(prettyDate)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(date)
                    .font(.system(size: 11, design: .monospaced))
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
        let sorted: [DailyAggregate]
        switch modelsSort {
        case .name:
            sorted = aggregates.sorted { $0.model < $1.model }
        case .tokens:
            let totalTokens: (DailyAggregate) -> Int64 = { $0.inputTokens + $0.outputTokens + $0.cacheReadTokens }
            sorted = aggregates.sorted { totalTokens($0) < totalTokens($1) }
        case .cost:
            sorted = aggregates.sorted { $0.totalCostUSD < $1.totalCostUSD }
        }
        return modelsSortDescending ? sorted.reversed() : sorted
    }

    private var sortedProjectRows: [ProjectRow] {
        let sorted: [ProjectRow]
        switch projectsSort {
        case .name:
            sorted = projectRows.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .tokens:
            sorted = projectRows.sorted { $0.tokens < $1.tokens }
        case .cost:
            sorted = projectRows.sorted { $0.cost < $1.cost }
        }
        return projectsSortDescending ? sorted.reversed() : sorted
    }

    @State private var hoveredAggAngle: Double?

    private var hoveredAgg: DailyAggregate? {
        guard let angle = hoveredAggAngle else { return nil }
        let sorted = aggregates.sorted { $0.totalCostUSD > $1.totalCostUSD }
        var cumulative = 0.0
        for agg in sorted {
            cumulative += agg.totalCostUSD
            if angle <= cumulative { return agg }
        }
        return sorted.last
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
                Chart(aggregates.sorted { $0.totalCostUSD > $1.totalCostUSD }, id: \.dateModelKey) { agg in
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
                    }
                    .padding(.vertical, 2)
                }
            }
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
