import SwiftUI
import SwiftData
import Charts
import PacerCore

/// Per-model breakdown — analogous to ProjectsView but keyed on model
/// name. Shows which models you actually use, how heavily, and over
/// what timeframe. Useful for "is sonnet doing the bulk of work or am
/// I always reaching for opus?" / "did I switch off haiku 3 months ago?"
struct ModelsView: View {
    @State private var range: ModelsRange = .ninetyDays

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ModelsContent(range: range)
                    .id(range)
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 600)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Models")
                .font(.largeTitle.weight(.semibold))
            Spacer()
            Picker("", selection: $range) {
                ForEach(ModelsRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        }
        .padding(.bottom, 4)
    }
}

enum ModelsRange: String, CaseIterable, Identifiable {
    case thirtyDays = "30d"
    case ninetyDays = "90d"
    case all        = "all"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .thirtyDays: return "Last 30 days"
        case .ninetyDays: return "Last 90 days"
        case .all:        return "All time"
        }
    }
    var days: Int? {
        switch self {
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        case .all:        return nil
        }
    }
}

private struct ModelsContent: View {
    /// `DailyAggregate` is the precomputed (date, model) rollup. With ≤
    /// a few hundred rows even on `all` ranges, grouping by model in
    /// the body is sub-10ms on the main thread — the worker hop
    /// previous versions used was unnecessary indirection per the
    /// "precomputed-aggregate views read directly" rule.
    @Query private var aggregates: [DailyAggregate]

    init(range: ModelsRange) {
        if let days = range.days {
            let cutoffString = TokenSample.formatDate(
                Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
            )
            _aggregates = Query(
                filter: #Predicate<DailyAggregate> { $0.date >= cutoffString },
                sort: \.date
            )
        } else {
            _aggregates = Query(sort: \DailyAggregate.date)
        }
    }

    private struct ModelRow: Identifiable {
        let model: String
        let displayName: String
        let cost: Double
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheReadTokens: Int64
        let totalTokens: Int64
        let activeDays: Int
        let firstSeen: String
        let lastSeen: String
        var id: String { model }
    }

    private struct DailyMix: Identifiable {
        let date: String
        let model: String
        let displayName: String
        let tokens: Int64
        var id: String { "\(date)|\(model)" }
    }

    /// Group precomputed daily rows by model. One pass over a few
    /// hundred rows max — cheap on every body re-eval, no caching
    /// needed.
    private var rows: [ModelRow] {
        struct Acc {
            var cost: Double = 0
            var input: Int64 = 0
            var output: Int64 = 0
            var cacheRead: Int64 = 0
            var dates: Set<String> = []
            var firstSeen: String = "9999-99-99"
            var lastSeen: String = "0000-00-00"
        }
        var byModel: [String: Acc] = [:]
        for r in aggregates {
            var a = byModel[r.model] ?? Acc()
            a.cost += r.totalCostUSD
            a.input += r.inputTokens
            a.output += r.outputTokens
            a.cacheRead += r.cacheReadTokens
            a.dates.insert(r.date)
            if r.date < a.firstSeen { a.firstSeen = r.date }
            if r.date > a.lastSeen { a.lastSeen = r.date }
            byModel[r.model] = a
        }
        return byModel.map { (model, a) in
            ModelRow(
                model: model,
                displayName: shortModel(model),
                cost: a.cost,
                inputTokens: a.input,
                outputTokens: a.output,
                cacheReadTokens: a.cacheRead,
                totalTokens: a.input + a.output + a.cacheRead,
                activeDays: a.dates.count,
                firstSeen: a.firstSeen,
                lastSeen: a.lastSeen
            )
        }.sorted { $0.cost > $1.cost }
    }

    private var dailyMix: [DailyMix] {
        aggregates.map {
            DailyMix(
                date: $0.date,
                model: $0.model,
                displayName: shortModel($0.model),
                tokens: $0.inputTokens + $0.outputTokens + $0.cacheReadTokens
            )
        }
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    shareCard
                    trendCard
                    listCard
                }
            }
        }
    }

    private var emptyState: some View {
        Text("No model activity in the selected range.")
            .foregroundStyle(.secondary)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Token share")
                .font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 24) {
                Chart(rows) { r in
                    SectorMark(
                        angle: .value("Tokens", r.totalTokens),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Model", r.displayName))
                    .cornerRadius(2)
                }
                .frame(width: 180, height: 180)
                .chartLegend(.hidden)
                VStack(alignment: .leading, spacing: 6) {
                    let total = rows.reduce(Int64(0)) { $0 + $1.totalTokens }
                    ForEach(rows.prefix(8)) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.displayName)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(formatTokens(row.totalTokens))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            if total > 0 {
                                Text("\(Int(Double(row.totalTokens) / Double(total) * 100))%")
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

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trend")
                .font(.title2.weight(.semibold))
            Chart(dailyMix) { d in
                BarMark(
                    x: .value("Date", d.date),
                    y: .value("Tokens", d.tokens)
                )
                .foregroundStyle(by: .value("Model", d.displayName))
            }
            .frame(height: 200)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatTokens(Int64(v)))
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

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("All models")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(rows.count) model\(rows.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Model").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Tokens").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
                Text("Days").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Text("Last seen").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
                Text("Cost").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
            Divider()
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayName)
                            .font(.system(.body, design: .monospaced))
                        Text(row.model)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(formatTokens(row.totalTokens))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 100, alignment: .trailing)
                    Text("\(row.activeDays)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(row.lastSeen)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .trailing)
                    Text(formatCost(row.cost))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
