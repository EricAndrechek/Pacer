import SwiftUI
import SwiftData
import Charts
import PacerCore

/// Today's per-model breakdown. A donut chart on the left shows the
/// share of total tokens by model; a table on the right lists each
/// model with input, output, cost, and percentage. Pulls from
/// `DailyAggregate` filtered to today's local date — same source as
/// `TodaySummaryCard`, but kept as its own card so the @Query stays
/// scoped (a model-only view doesn't need to invalidate when the
/// total-cost number changes).
struct PerModelTodayCard: View {
    @Query private var aggregates: [DailyAggregate]
    @Query(PerModelTodayCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cached: [ModelRow] = []

    init() {
        let todayString = TokenSample.formatDate(Date())
        _aggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == todayString },
            sort: \.totalCostUSD,
            order: .reverse
        )
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private var rows: [ModelRow] { cached }

    private func refreshCache() {
        // Sort descending by tokens — the donut and the table read in
        // the same order, so the user can map row 1 to the largest
        // arc.
        let totalTokens = aggregates.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens
        }
        cached = aggregates
            .map { agg in
                let tokens = agg.inputTokens + agg.outputTokens + agg.cacheReadTokens
                let share = totalTokens > 0 ? Double(tokens) / Double(totalTokens) : 0
                return ModelRow(
                    model: agg.model,
                    inputTokens: agg.inputTokens,
                    outputTokens: agg.outputTokens,
                    cacheReadTokens: agg.cacheReadTokens,
                    cost: agg.totalCostUSD,
                    share: share
                )
            }
            .sorted { $0.cost > $1.cost }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today by model")
                .font(.title2.weight(.semibold))

            if rows.isEmpty {
                Text("No usage logged today yet.")
                    .foregroundStyle(.secondary)
                    .font(.system(.caption, design: .monospaced))
            } else {
                HStack(alignment: .top, spacing: 24) {
                    donut
                        .frame(width: 160, height: 160)
                    table
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    private var donut: some View {
        Chart(rows) { row in
            SectorMark(
                angle: .value("Tokens", Double(row.inputTokens + row.outputTokens + row.cacheReadTokens)),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value("Model", row.model))
            .cornerRadius(2)
        }
        .chartLegend(.hidden)
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Circle()
                        .fill(swatchColor(for: row.model))
                        .frame(width: 8, height: 8)
                    Text(shortModel(row.model))
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 220, alignment: .leading)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("in \(formatTokens(row.inputTokens))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Text("out \(formatTokens(row.outputTokens))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Text(formatCost(row.cost))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .frame(width: 80, alignment: .trailing)
                    Text("\(Int((row.share * 100).rounded()))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Map model name → a stable color. We don't fight Charts'
    /// auto-assigned colors for the donut, but the table swatches
    /// should approximate them so the visual link is clear.
    ///
    /// Uses a sum-of-unicode-scalars hash rather than `Hasher` because
    /// `Hasher` is randomized per process — the same model would get
    /// different colors across app launches, defeating the "stable"
    /// promise.
    private func swatchColor(for model: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .red]
        let scalarSum = model.unicodeScalars.reduce(0) { $0 + UInt32($1.value) }
        let idx = Int(scalarSum % UInt32(palette.count))
        return palette[idx]
    }

    /// `claude-opus-4-7` is fine; `anthropic/claude-3-5-sonnet-20241022`
    /// gets shortened. Chop at the last `/` so provider prefixes don't
    /// dominate the column.
    private func shortModel(_ name: String) -> String {
        if let lastSlash = name.lastIndex(of: "/") {
            return String(name[name.index(after: lastSlash)...])
        }
        return name
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 100 { return String(format: "$%.0f", usd) }
        if usd >= 10  { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }

    private func formatTokens(_ count: Int64) -> String {
        let n = Double(count)
        switch n {
        case 1_000_000_000...:
            return String(format: "%.2fB", n / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", n / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", n / 1_000)
        default:
            return "\(count)"
        }
    }
}

private struct ModelRow: Identifiable {
    var id: String { model }
    let model: String
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cost: Double
    let share: Double
}
