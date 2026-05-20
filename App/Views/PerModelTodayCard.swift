import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

/// Today's per-model breakdown. Donut on the left shows the share of
/// total tokens by model; the table on the right lists each model with
/// input, output, cost, and percentage. Pulls from `DailyAggregate`
/// filtered to today — same source as `TodayDetailsCard` but kept as
/// its own card so the @Query stays scoped (a model-only view doesn't
/// need to invalidate when the total-cost number changes).
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
        let totalTokens = aggregates.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens
        }
        cached = aggregates
            .map { agg in
                let tokens = agg.inputTokens + agg.outputTokens
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

    /// Selected wedge in the donut. Bound via `chartAngleSelection`
    /// — Charts hands us the angle clicked/hovered, we map it back to
    /// a row by accumulating slice widths.
    @State private var hoveredAngle: Double?

    /// Pre-computed cumulative-angle table for hover lookups + total
    /// for the percent calculation. Refreshed when `cached` changes
    /// (which only happens on a scan tick), so per-pixel hover work
    /// is O(rows) over an already-built array — no `reduce` per move.
    @State private var hoverCumulative: [(row: ModelRow, max: Double)] = []
    @State private var hoverTotalTokens: Int64 = 0

    @MainActor
    private func refreshHoverIndex() {
        var running = 0.0
        var built: [(row: ModelRow, max: Double)] = []
        built.reserveCapacity(rows.count)
        var totalTokens: Int64 = 0
        for r in rows {
            let t = Int64(r.inputTokens + r.outputTokens)
            running += Double(t)
            totalTokens += t
            built.append((r, running))
        }
        hoverCumulative = built
        hoverTotalTokens = totalTokens
    }

    private var hoveredRow: ModelRow? {
        guard let angle = hoveredAngle, !hoverCumulative.isEmpty else { return nil }
        for entry in hoverCumulative where angle <= entry.max {
            return entry.row
        }
        return hoverCumulative.last?.row
    }

    var body: some View {
        PacerCard("Today by model", trailing: {
            // Hover-reveal of the selected wedge. Reads pre-computed
            // total from `hoverTotalTokens` instead of doing a fresh
            // `reduce` on every hover tick.
            if let r = hoveredRow {
                let total = hoverTotalTokens
                let myTotal = r.inputTokens + r.outputTokens
                let pct = total > 0 ? Int(Double(myTotal) / Double(total) * 100) : 0
                HStack(spacing: 8) {
                    Text(pacerShortModel(r.model))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(pct)%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }) {
            if rows.isEmpty {
                Text("No usage logged today yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    donut
                        .frame(width: 160, height: 160)
                    table
                }
            }
        }
        .onAppear {
            refreshCache()
            refreshHoverIndex()
        }
        .onChange(of: scanMeta.first?.value) { _, _ in
            refreshCache()
            refreshHoverIndex()
        }
    }

    private var donut: some View {
        Chart(rows) { row in
            SectorMark(
                angle: .value("Tokens", Double(row.inputTokens + row.outputTokens)),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value("Model", row.model))
            .cornerRadius(2)
            // Subtle highlight: opacity drops on non-hovered slices,
            // pinpointing the one under the cursor without changing
            // the chart's geometry.
            .opacity(hoveredRow.map { $0.id == row.id ? 1.0 : 0.45 } ?? 1.0)
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $hoveredAngle)
        .accessibilityLabel("Today's token share by model")
        .accessibilityValue(perModelShareSummary)
    }

    /// Summary string read aloud by VoiceOver in place of the donut.
    /// Spells out each model's share so a screen-reader user gets the
    /// same information sighted users get from the wedges + legend.
    private var perModelShareSummary: String {
        let total = hoverTotalTokens
        guard total > 0 else { return "no data yet" }
        return rows.prefix(5).map { row in
            let tokens = row.inputTokens + row.outputTokens
            let pct = Int(Double(tokens) / Double(total) * 100)
            return "\(pacerShortModel(row.model)) \(pct) percent"
        }.joined(separator: ", ")
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(swatchColor(for: row.model))
                        .frame(width: 8, height: 8)
                    Text(pacerShortModel(row.model))
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: 220, alignment: .leading)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("in \(pacerTokens(row.inputTokens))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 88, alignment: .trailing)
                    Text("out \(pacerTokens(row.outputTokens))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 88, alignment: .trailing)
                    Text(pacerCost(row.cost))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 76, alignment: .trailing)
                    Text("\(Int((row.share * 100).rounded()))%")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    /// Stable per-model color so the donut and table swatches line up
    /// across launches. Sum-of-unicode-scalars hash because Swift's
    /// `Hasher` is randomized per process.
    private func swatchColor(for model: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .red]
        let scalarSum = model.unicodeScalars.reduce(0) { $0 + UInt32($1.value) }
        let idx = Int(scalarSum % UInt32(palette.count))
        return palette[idx]
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
