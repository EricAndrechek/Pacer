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

    init() {
        // Fetch a 60-day predicate window that comfortably covers the
        // current month plus a few days either side. The
        // `MonthlyForecast` primitive filters internally to "starts
        // with current YYYY-MM-" so an over-fetch is correct and
        // simpler than tracking the month boundary in the predicate.
        // ~60 days × ~5 model rows/day = ≤300 rows materialized — well
        // under any concerning threshold.
        let now = Date()
        let cal = Calendar.current
        let lowerBound = cal.date(byAdding: .day, value: -60, to: now) ?? now
        let lowerStr = TokenSample.formatDate(lowerBound)
        _aggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date >= lowerStr }
        )
    }

    private var dailyCosts: [String: Double] {
        // Collapse per-model rows into a single (date → total) map.
        var byDate: [String: Double] = [:]
        for row in aggregates {
            byDate[row.date, default: 0] += row.totalCostUSD
        }
        return byDate
    }

    private var projection: MonthlyForecast.Projection? {
        MonthlyForecast.compute(dailyCosts: dailyCosts)
    }

    var body: some View {
        PacerCard("This month") {
            if let p = projection {
                content(p)
            } else {
                Text("Not enough data yet — a projection appears once Pacer has seen at least \(MonthlyForecast.minDaysWithData) active days this month.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
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
                hint: monthLabel(p)
            )
            MetricTile(
                value: pacerCost(p.averageDailyCost),
                label: "avg per active day",
                hint: "\(p.daysWithData) day\(p.daysWithData == 1 ? "" : "s") with usage"
            )
            MetricTile(
                value: pacerCost(p.projectedMonthTotal),
                label: "projected month",
                hint: trajectoryHint(p)
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
