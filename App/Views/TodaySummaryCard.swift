import SwiftUI
import SwiftData
import PacerCore

/// Today's totals, computed from `DailyAggregate` rows for the local
/// `YYYY-MM-DD`. Reads only — no work that touches the scan's write
/// path. Intentionally independent of the rate-limit OAuth poll: this
/// card surfaces what we know from JSONL, the gauges card surfaces
/// what we know from the OAuth endpoint.
struct TodaySummaryCard: View {
    /// Today-only aggregates from the precomputed (date, model) rollup.
    /// At most ~6 rows — direct iteration in body is sub-millisecond.
    @Query private var aggregates: [DailyAggregate]

    /// Last 7 calendar days (today + previous 6) for the "vs 7-day
    /// average" chip. ≤7 dates × 6 models ~= 42 rows max.
    @Query private var lastWeekAggregates: [DailyAggregate]

    init() {
        let todayString = TokenSample.formatDate(Date())
        let weekAgo = TokenSample.formatDate(
            Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
        )
        _aggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == todayString }
        )
        _lastWeekAggregates = Query(
            filter: #Predicate<DailyAggregate> {
                $0.date >= weekAgo && $0.date <= todayString
            }
        )
    }

    private struct WeekComparison {
        let todayCost: Double
        let priorAvgCost: Double
        let activeDays: Int
        var ratio: Double? {
            guard priorAvgCost > 0.01 else { return nil }
            return todayCost / priorAvgCost
        }
    }

    private var totals: Totals { Totals(rows: aggregates) }

    private var weekComparison: WeekComparison {
        let todayString = TokenSample.formatDate(Date())
        var todayCost: Double = 0
        var priorByDate: [String: Double] = [:]
        for row in lastWeekAggregates {
            if row.date == todayString {
                todayCost += row.totalCostUSD
            } else {
                priorByDate[row.date, default: 0] += row.totalCostUSD
            }
        }
        let activeDays = priorByDate.values.filter { $0 > 0.01 }.count
        let totalPrior = priorByDate.values.reduce(0, +)
        let avg = activeDays > 0 ? totalPrior / Double(activeDays) : 0
        return WeekComparison(todayCost: todayCost, priorAvgCost: avg, activeDays: activeDays)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(TokenSample.formatDate(Date()))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if totals.isEmpty {
                emptyState
            } else {
                metricRow
                HStack(spacing: 12) {
                    if totals.cacheHitRatio > 0 {
                        Text("Cache hit ratio: \(Int(totals.cacheHitRatio * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    weekTrendChip
                    Spacer()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var metricRow: some View {
        HStack(alignment: .top, spacing: 32) {
            metric(label: "cost",      value: formatCost(totals.totalCostUSD))
            metric(label: "input",     value: formatTokens(totals.inputTokens))
            metric(label: "output",    value: formatTokens(totals.outputTokens))
            metric(label: "cache read", value: formatTokens(totals.cacheReadTokens))
            metric(label: "models",    value: "\(totals.distinctModels)")
            Spacer()
        }
    }

    @ViewBuilder
    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        Text("No usage logged today yet. Pacer will write within seconds of any Claude Code activity.")
            .foregroundStyle(.secondary)
            .font(.system(.body, design: .monospaced))
    }

    @ViewBuilder
    private var weekTrendChip: some View {
        let cmp = weekComparison
        if let ratio = cmp.ratio {
            HStack(spacing: 3) {
                Image(systemName: trendIcon(ratio))
                    .font(.caption)
                Text(ratioText(ratio))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                Text("vs \(cmp.activeDays)-day avg")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(trendColor(ratio))
        } else if cmp.todayCost > 0 {
            Text("first day with cost in the last 7")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// "1.4×" / "0.6×" — keeps it concise and prefix-free.
    private func ratioText(_ ratio: Double) -> String {
        if ratio >= 10 { return String(format: "%.0f×", ratio) }
        return String(format: "%.1f×", ratio)
    }

    private func trendIcon(_ ratio: Double) -> String {
        switch ratio {
        case ..<0.8:  return "arrow.down.right"
        case ..<1.2:  return "equal"
        default:      return "arrow.up.right"
        }
    }

    private func trendColor(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.8:  return .green
        case ..<1.5:  return .secondary
        default:      return .orange
        }
    }

    // MARK: - Formatting

    private func formatCost(_ usd: Double) -> String {
        if usd >= 100 {
            return String(format: "$%.0f", usd)
        }
        return String(format: "$%.2f", usd)
    }

    /// Tokens are big; show K/M suffixes the same way ccusage's CLI
    /// does (and what users see in `/stats`). Keeps the card readable.
    private func formatTokens(_ count: Int64) -> String {
        let n = Double(count)
        switch n {
        case 1_000_000_000...:
            return String(format: "%.2fB", n / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.2fM", n / 1_000_000)
        case 10_000...:
            return String(format: "%.1fK", n / 1_000)
        case 1_000...:
            return String(format: "%.2fK", n / 1_000)
        default:
            return "\(count)"
        }
    }
}

/// Sums across the day's per-model aggregate rows. Pulled out so the
/// view body stays declarative — and so the same struct can power
/// per-day rows in the 30-day chart later (M6.3) without re-deriving.
private struct Totals {
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreation5mTokens: Int64
    let cacheCreation1hTokens: Int64
    let totalCostUSD: Double
    let distinctModels: Int

    init(rows: [DailyAggregate]) {
        self.inputTokens = rows.reduce(0) { $0 + $1.inputTokens }
        self.outputTokens = rows.reduce(0) { $0 + $1.outputTokens }
        self.cacheReadTokens = rows.reduce(0) { $0 + $1.cacheReadTokens }
        self.cacheCreation5mTokens = rows.reduce(0) { $0 + $1.cacheCreation5mTokens }
        self.cacheCreation1hTokens = rows.reduce(0) { $0 + $1.cacheCreation1hTokens }
        self.totalCostUSD = rows.reduce(0) { $0 + $1.totalCostUSD }
        self.distinctModels = Set(rows.map(\.model)).count
    }

    var isEmpty: Bool { inputTokens == 0 && outputTokens == 0 && cacheReadTokens == 0 }

    /// Cache reads / (cache reads + non-cache input). High ratios mean
    /// the prompt-caching is doing its job. Anthropic-rate cost
    /// calculation reduces with cache hits, so this is a useful
    /// "are we using caching well" gauge.
    var cacheHitRatio: Double {
        let denom = Double(cacheReadTokens + inputTokens)
        guard denom > 0 else { return 0 }
        return Double(cacheReadTokens) / denom
    }
}
