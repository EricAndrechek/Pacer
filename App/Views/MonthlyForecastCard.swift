import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Month-to-date cost plus the engine's month-end projection. Sits below
/// the per-model card on the dashboard so a user who scans the page
/// top-to-bottom gets: today (hero), this hour (live), today's breakdown,
/// today's hour-of-day timeline, today's models — and then the wider
/// trajectory.
///
/// Display facts (month so far, per-active-day average, days left) come
/// from the current month's `DailyAggregate` rollup; the projection itself
/// comes from the intelligence engine (`.projectedCost(.thisMonth)`), which
/// owns the model, its eligibility gating, and the calibrated range shown
/// in the tooltip.
struct MonthlyForecastCard: View {
    @Query private var aggregates: [DailyAggregate]
    @Query(MonthlyForecastCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    /// The shared intelligence engine — owns the month-end projection (the
    /// daily-series→sum model with its eligibility gate and calibrated band).
    /// This card keeps only the display facts (month so far, per-day average,
    /// days left), computed from the current month's rollup.
    @Environment(\.usageEngine) private var engine

    /// Display facts cached off the scan tick; the projection itself is
    /// refreshed when the engine refits.
    @State private var cached = MonthFacts()
    @State private var projection: Estimate?

    struct MonthFacts: Equatable {
        var monthSoFar: Double = 0
        var averageDailyCost: Double = 0
        var daysWithData: Int = 0
        var daysInMonth: Int = 30
        var dayOfMonth: Int = 1
        var hasAnyData: Bool = false
    }

    init() {
        // Predicate is anchored at the first day of the current month —
        // this card only displays current-month facts; history lives in
        // the engine.
        let cal = Calendar.current
        let now = Date()
        let firstOfMonth = cal.dateInterval(of: .month, for: now)?.start ?? now
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

    private func refreshFacts() {
        let cal = Calendar.current
        let now = Date()
        var byDate: [String: Double] = [:]
        for row in aggregates {
            byDate[row.date, default: 0] += row.totalCostUSD
        }
        var next = MonthFacts()
        next.monthSoFar = byDate.values.reduce(0, +)
        let active = byDate.values.filter { $0 > 0 }
        next.daysWithData = active.count
        next.averageDailyCost = active.isEmpty ? 0 : active.reduce(0, +) / Double(active.count)
        next.daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        next.dayOfMonth = cal.component(.day, from: now)
        next.hasAnyData = !active.isEmpty
        cached = next
    }

    private func refreshProjection() async {
        guard let engine else { return }
        projection = await engine.ask(.projectedCost(.thisMonth))
    }

    var body: some View {
        PacerCard("This month") {
            if cached.hasAnyData {
                VStack(alignment: .leading, spacing: 12) {
                    content
                    monthRangeBar
                }
            } else {
                Text("Not enough data yet — a projection appears once Pacer has seen some usage this month.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { refreshFacts() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshFacts() }
        .task { await refreshProjection() }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshProjection() }
        }
    }

    @ViewBuilder
    private var content: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                count: 4
            ),
            alignment: .leading,
            spacing: 12
        ) {
            MetricTile(
                value: pacerCost(cached.monthSoFar),
                label: "month so far",
                hint: monthLabel,
                tooltip: pacerCostExact(cached.monthSoFar)
            )
            MetricTile(
                value: pacerCost(cached.averageDailyCost),
                label: "avg per active day",
                hint: "\(cached.daysWithData) day\(cached.daysWithData == 1 ? "" : "s") with usage",
                tooltip: pacerCostExact(cached.averageDailyCost)
            )
            // The range itself lives on the labeled bar below; the tile's
            // hint keeps the differently-informative pace comparison.
            MetricTile(
                value: projectedValueText,
                label: "projected month",
                hint: trajectoryHint,
                tooltip: projectedTooltip
            )
            MetricTile(
                value: "\(max(0, cached.daysInMonth - cached.dayOfMonth))",
                label: "days left",
                hint: "of \(cached.daysInMonth) in month"
            )
        }
    }

    private var projectedValueText: String {
        guard let p = projection, !p.isInsufficient else { return "—" }
        return pacerCost(p.value)
    }

    /// The month projection in context: track spans zero → just past the
    /// band; tick = spent so far (how much of the projection is already
    /// banked); segment = the calibrated 80% range; marker = the projection.
    @ViewBuilder private var monthRangeBar: some View {
        if let p = projection, !p.isInsufficient, let band = p.interval80,
           p.value >= cached.monthSoFar * 0.98 {
            let hi = max(band.upperBound * 1.05, p.value * 1.15)
            let shown = IntelligenceFormatting.outward(band)
            RangeBar(domain: 0...max(hi, 1),
                     range: shown,
                     point: p.value,
                     reference: cached.monthSoFar,
                     lowerLabel: pacerCost(shown.lowerBound),
                     upperLabel: pacerCost(shown.upperBound))
                .help("Month's likely range (80%), dot = projection · tick = spent so far (\(pacerCost(cached.monthSoFar)))")
        }
    }

    private var projectedTooltip: String? {
        guard let p = projection, !p.isInsufficient else { return nil }
        var parts = [pacerCostExact(p.value)]
        if let pace = trajectoryHint { parts.append(pace) }
        return parts.joined(separator: " · ")
    }

    /// "May 2026" style label so the user sees which month the figure
    /// is for at a glance.
    private var monthLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: Date())
    }

    /// Compare the engine's projection against month-so-far × (daysInMonth /
    /// dayOfMonth) — i.e. a pure linear forward-fill from the current
    /// run rate — and label the delta. "↑ 18% above pace" / "↓ 12% below
    /// pace". Only meaningful past the first few days; on day 1-2 the
    /// month-so-far rate is too noisy.
    private var trajectoryHint: String? {
        guard let p = projection, !p.isInsufficient else { return nil }
        guard cached.dayOfMonth >= 3 else { return "if rate holds" }
        let purePace = cached.monthSoFar / Double(cached.dayOfMonth) * Double(cached.daysInMonth)
        guard purePace > 0.01 else { return "if rate holds" }
        let ratio = p.value / purePace
        if ratio > 1.05 {
            return String(format: "↑ %.0f%% above pace", (ratio - 1) * 100)
        }
        if ratio < 0.95 {
            return String(format: "↓ %.0f%% below pace", (1 - ratio) * 100)
        }
        return "on pace"
    }
}
