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
/// precomputed by the in-process scan's recomputers, so the view
/// never iterates raw `TokenSample`s. The same range picker as the
/// parent list is honored by the caller via `since`.
struct ProjectDetailView: View {
    let projectPath: String
    let displayName: String
    let since: Date?

    @Environment(\.dismiss) private var dismiss
    /// Pre-computed `(project, date)` rollup filtered to this project
    /// and (optionally) range. Totals, daily series, and per-model
    /// breakdown come from this — instant; no sample iteration.
    @Query private var aggregates: [ProjectDailyAggregate]
    /// Pre-computed per-session rollup, filtered to this project and
    /// range. SessionInfoRecomputer keeps these rows current alongside
    /// the daily/project aggregates so the sessions list renders
    /// instantly from a small precomputed set instead of iterating
    /// raw TokenSamples on every open.
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

    /// Sum across the project's rollup rows. One pass, ≤90 rows per
    /// 90-day range — sub-millisecond on the main thread.
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

    /// Decode and union per-day per-model JSON across the project's
    /// rollup rows. JSON decode happens N times (N = days in range)
    /// but each blob is tiny — <1KB. Total work ≪ iterating samples.
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
            VStack(alignment: .leading, spacing: 16) {
                header
                summaryCard
                if !dailySeries.isEmpty {
                    dailyChartCard
                }
                if !modelSlices.isEmpty {
                    modelsCard
                }
                if !sessionRows.isEmpty {
                    sessionsCard
                }
            }
            .padding(24)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, idealHeight: 700)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.title.weight(.semibold))
                Text(projectPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var summaryCard: some View {
        let t = totals
        return VStack(alignment: .leading, spacing: 10) {
            Text("Summary").font(.headline)
            HStack(alignment: .top, spacing: 32) {
                metric("cost", formatCost(t.cost))
                metric("input", formatTokens(t.input))
                metric("output", formatTokens(t.output))
                metric("cache read", formatTokens(t.cacheRead))
                metric("active days", "\(aggregates.count)")
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var dailyChartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily activity").font(.headline)
            Chart(dailySeries) { d in
                BarMark(
                    x: .value("Date", d.date),
                    y: .value("Cost", d.cost)
                )
                .foregroundStyle(.tint)
            }
            .frame(height: 160)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(compactDollar(v))
                                .font(.system(size: 9, design: .monospaced))
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
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
                Chart(modelSlices) { m in
                    SectorMark(
                        angle: .value("tokens", m.tokens),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Model", shortModel(m.model)))
                    .cornerRadius(2)
                }
                .frame(width: 160, height: 160)
                .chartLegend(.hidden)
                VStack(alignment: .leading, spacing: 6) {
                    let total = modelSlices.reduce(Int64(0)) { $0 + $1.tokens }
                    ForEach(modelSlices) { m in
                        HStack(alignment: .firstTextBaseline) {
                            Text(shortModel(m.model))
                                .font(.system(.body, design: .monospaced))
                            Spacer(minLength: 8)
                            Text(formatTokens(m.tokens))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if total > 0 {
                                Text("\(Int(Double(m.tokens) / Double(total) * 100))%")
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

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions").font(.headline)
                Spacer()
                Text("\(sessionRows.count) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(sessionRows.prefix(20)), id: \.sessionId) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(String(row.sessionId.prefix(8)))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 80, alignment: .leading)
                    Text(shortModel(row.topModel))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                    Spacer(minLength: 8)
                    Text(formatTokens(row.totalTokens))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 80, alignment: .trailing)
                    Text(formatCost(row.cumulativeCostUSD))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .frame(width: 70, alignment: .trailing)
                    Text(relative(row.lastSeenAt))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 90, alignment: .trailing)
                }
            }
            if sessionRows.count > 20 {
                Text("…and \(sessionRows.count - 20) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 1_000 { return String(format: "$%.0f", usd) }
        if usd >= 100   { return String(format: "$%.0f", usd) }
        if usd >= 10    { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }

    private func compactDollar(_ usd: Double) -> String {
        if usd >= 100 { return String(format: "$%.0f", usd) }
        if usd >= 10  { return String(format: "$%.0f", usd) }
        return String(format: "$%.1f", usd)
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

    private func shortModel(_ name: String) -> String {
        if let lastSlash = name.lastIndex(of: "/") {
            return String(name[name.index(after: lastSlash)...])
        }
        return name
    }
}
