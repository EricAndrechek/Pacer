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

    @Environment(\.dismiss) private var dismiss
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
            Button("Close") { dismiss() }
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

    private var modelsCard: some View {
        PacerCard("Models") {
            HStack(alignment: .top, spacing: 24) {
                Chart(aggregates, id: \.dateModelKey) { agg in
                    SectorMark(
                        angle: .value("Cost", agg.totalCostUSD),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Model", pacerShortModel(agg.model)))
                    .cornerRadius(2)
                }
                .frame(width: 160, height: 160)
                .chartLegend(.hidden)
                VStack(alignment: .leading, spacing: 6) {
                    let total = aggregates.reduce(0) { $0 + $1.totalCostUSD }
                    ForEach(aggregates.sorted { $0.totalCostUSD > $1.totalCostUSD }, id: \.dateModelKey) { agg in
                        HStack(alignment: .firstTextBaseline) {
                            Text(pacerShortModel(agg.model))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
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
        PacerCard("Projects") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(projectRows) { row in
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
