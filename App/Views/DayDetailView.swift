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
    /// Aggregates for the day — small (≤ a handful of models) so we
    /// keep reading them directly. Used for the donut and the row
    /// list, where we need the live items for ForEach identity.
    @Query private var aggregates: [DailyAggregate]
    /// Samples for the day — can be a few thousand on a busy day.
    /// Read only via `refreshCache()`; body looks at cached fields.
    @Query private var samples: [TokenSample]
    @Query(DayDetailView.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    @State private var cached = Cached()

    init(date: String) {
        self.date = date
        _aggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == date }
        )
        // Pull samples that fall on this calendar day for project
        // and session detail. We compare by the pre-formatted date
        // string column so the predicate matches what the daemon
        // wrote — no timezone math here.
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
                displayName: shortPath(key),
                cost: a.cost,
                tokens: a.tokens
            )
        }.sorted { $0.cost > $1.cost }

        cached = Cached(totals: t, projectRows: rows)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summaryCard
                if !aggregates.isEmpty {
                    modelsCard
                }
                if !projectRows.isEmpty {
                    projectsCard
                }
            }
            .padding(24)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 600)
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(prettyDate)
                    .font(.title.weight(.semibold))
                Text(date)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    /// `2026-04-30` → `Thursday, April 30, 2026`. Falls back to the
    /// raw key on parse failure.
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
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Summary").font(.headline)
                Spacer()
                if aggregates.isEmpty {
                    Text("no data")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .top, spacing: 32) {
                metric("cost", formatCost(t.cost))
                metric("input", formatTokens(t.input))
                metric("output", formatTokens(t.output))
                metric("cache read", formatTokens(t.cacheRead))
                metric("cache write", formatTokens(t.cacheCreation))
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Models").font(.headline)
            HStack(alignment: .top, spacing: 24) {
                Chart(aggregates, id: \.dateModelKey) { agg in
                    SectorMark(
                        angle: .value("Cost", agg.totalCostUSD),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Model", shortModel(agg.model)))
                    .cornerRadius(2)
                }
                .frame(width: 160, height: 160)
                .chartLegend(.hidden)
                VStack(alignment: .leading, spacing: 6) {
                    let total = aggregates.reduce(0) { $0 + $1.totalCostUSD }
                    ForEach(aggregates.sorted { $0.totalCostUSD > $1.totalCostUSD }, id: \.dateModelKey) { agg in
                        HStack(alignment: .firstTextBaseline) {
                            Text(shortModel(agg.model))
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(formatCost(agg.totalCostUSD))
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .frame(width: 70, alignment: .trailing)
                            if total > 0 {
                                Text("\(Int(agg.totalCostUSD / total * 100))%")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 36, alignment: .trailing)
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

    private var projectsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Projects").font(.headline)
            ForEach(projectRows) { row in
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
                    Text(formatTokens(row.tokens))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Text(formatCost(row.cost))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .frame(width: 70, alignment: .trailing)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func shortPath(_ path: String) -> String {
        if path == "(unknown)" { return path }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    private func shortModel(_ name: String) -> String {
        if let lastSlash = name.lastIndex(of: "/") {
            return String(name[name.index(after: lastSlash)...])
        }
        return name
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
}
