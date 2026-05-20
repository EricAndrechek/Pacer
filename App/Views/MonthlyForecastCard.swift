import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Month-to-date cost plus a simple "if you keep going at this rate"
/// projection. Sits below the per-model card on the dashboard so a
/// user who scans the page top-to-bottom gets: today (hero), this
/// hour (live), today's breakdown, today's hour-of-day timeline,
/// today's models — and then the wider trajectory.
///
/// Sources from `DailyAggregate`, the daily/per-model rollup. We
/// fetch a scope that comfortably covers the current month (and a
/// little of the previous, to dodge edge cases at the 1st-of-the-
/// month boundary) and hand the resulting `(date, cost)` dictionary
/// to `MonthlyForecast.compute`, which owns the math and the
/// minimum-data threshold.
struct MonthlyForecastCard: View {
    @Query private var aggregates: [DailyAggregate]
    @Query(MonthlyForecastCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    /// Cached projection refreshed on scan-meta tick. The in-body
    /// view code never iterates `aggregates`; it reads `cached`.
    @State private var cached: MonthlyForecast.Projection?

    init() {
        // Predicate is anchored at the first day of the current month —
        // anything older isn't read by `MonthlyForecast.compute` so
        // materializing it would just be waste. Previously we fetched
        // 60 days (~300 rows) every time any DailyAggregate row
        // changed; this drops materialization to ~current-month-so-far
        // × ~5 model rows/day (≤155 max, usually <80).
        let cal = Calendar.current
        let now = Date()
        let firstOfMonth: Date
        if let interval = cal.dateInterval(of: .month, for: now) {
            firstOfMonth = interval.start
        } else {
            firstOfMonth = now
        }
        let lowerStr = TokenSample.formatDate(firstOfMonth)
        _aggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date >= lowerStr }
        )
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private func refreshCache() {
        var byDate: [String: Double] = [:]
        for row in aggregates {
            byDate[row.date, default: 0] += row.totalCostUSD
        }
        cached = MonthlyForecast.compute(dailyCosts: byDate)
    }

    var body: some View {
        PacerCard("This month") {
            if let p = cached {
                content(p)
            } else {
                Text("Not enough data yet — a projection appears once Pacer has seen at least \(MonthlyForecast.minDaysWithData) active days this month.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    @ViewBuilder
    private func content(_ p: MonthlyForecast.Projection) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                count: 4
            ),
            alignment: .leading,
            spacing: 12
        ) {
            MetricTile(
                value: pacerCost(p.monthSoFar),
                label: "month so far",
                hint: monthLabel(p),
                tooltip: pacerCostExact(p.monthSoFar)
            )
            MetricTile(
                value: pacerCost(p.averageDailyCost),
                label: "avg per active day",
                hint: "\(p.daysWithData) day\(p.daysWithData == 1 ? "" : "s") with usage",
                tooltip: pacerCostExact(p.averageDailyCost)
            )
            MetricTile(
                value: pacerCost(p.projectedMonthTotal),
                label: "projected month",
                hint: trajectoryHint(p),
                tooltip: pacerCostExact(p.projectedMonthTotal)
            )
            MetricTile(
                value: "\(max(0, p.daysInMonth - p.dayOfMonth))",
                label: "days left",
                hint: "of \(p.daysInMonth) in month"
            )
        }
    }

    /// "May 2026" style label so the user sees which month the figure
    /// is for at a glance.
    private func monthLabel(_ p: MonthlyForecast.Projection) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: Date())
    }

    /// Compare the projection against month-so-far × (daysInMonth /
    /// dayOfMonth) — i.e. a pure linear forward-fill from the current
    /// run rate — and label the delta. "↑ 18% above pace" / "↓ 12% below
    /// pace". Only meaningful past the first few days; on day 1-2 the
    /// month-so-far rate is too noisy.
    private func trajectoryHint(_ p: MonthlyForecast.Projection) -> String? {
        guard p.dayOfMonth >= 3 else { return "if rate holds" }
        let purePace = p.monthSoFar / Double(p.dayOfMonth) * Double(p.daysInMonth)
        guard purePace > 0.01 else { return "if rate holds" }
        let ratio = p.projectedMonthTotal / purePace
        if ratio > 1.05 {
            return String(format: "↑ %.0f%% above pace", (ratio - 1) * 100)
        }
        if ratio < 0.95 {
            return String(format: "↓ %.0f%% below pace", (1 - ratio) * 100)
        }
        return "on pace"
    }
}
