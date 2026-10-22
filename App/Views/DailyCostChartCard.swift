import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// The dashboard's longer view: the last 30 days as a chart, then this month
/// so far and where it is heading. One card, where there were two ("Last 30
/// days" and "This month") reading the same daily rows.
///
/// The chart is the shared `PacerStackedPartChart`: each bar stacked by
/// priced part (#225), coloured by part only, with a hover card over the
/// chart that gives the day's cost, tokens, breakdown and top models. One
/// encoding per chart: the split by model lives on the Models tab. Click a
/// bar to drill into the per-day modal (same view the History tab's heatmap
/// opens).
///
/// The month section is what "This week" is for its seven days — cost,
/// tokens, active days and the shared breakdown — plus the engine's
/// month-end projection. Every number in it is the month's own; on a day
/// when the month's active days are exactly today's or this week's, its
/// totals would repeat the Now strip or "This week", so it shows only the
/// projection and keeps them in that tile's tooltip (`PeriodWindows`).
struct DailyCostChartCard: View {
    /// Optional callback fired when the user clicks a bar. Wiring is
    /// at the parent (DashboardView), so each surface can decide whether to
    /// open the day modal locally or stay quiet.
    let onDayTap: ((String) -> Void)?

    init(scopeAccountId: String? = nil, onDayTap: ((String) -> Void)? = nil) {
        self.onDayTap = onDayTap
        // Scope the @Query to the chart's display window. Card renders
        // exactly 30 days; the prior unbounded query materialized every
        // DailyAggregate row (730+ on a 2-year DB) just so refreshDerived
        // could `.suffix(30)` after grouping. With the predicate the
        // fetch is 30 × N_models rows (~150 typical), using the
        // existing `(date)` index for a range scan.
        //
        // It also holds the whole month: a month's first day is at most 30
        // days back (the 31st's first is exactly 30), so the month section
        // reads the same rows and needs no query of its own.
        let cutoffString = TokenSample.formatDate(
            Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        )
        _globalAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date >= cutoffString },
            sort: \DailyAggregate.date,
            order: .reverse
        )
        let acct = scopeAccountId ?? UsageScope.noAccountSentinel
        _scopedAggregates = Query(
            filter: #Predicate<AccountDailyAggregate> {
                $0.date >= cutoffString && $0.accountId == acct
            },
            sort: \AccountDailyAggregate.date,
            order: .reverse
        )
    }

    @Query private var globalAggregates: [DailyAggregate]
    /// The same rollup sliced to one account. Which of the two is
    /// rendered is the scope switch; the card's layout does not change.
    @Query private var scopedAggregates: [AccountDailyAggregate]
    @State private var scope = UsageScope.shared

    /// What the card renders: every account, or one. Both queries are
    /// live, so switching is a re-read rather than a recompute.
    private var aggregates: [DailyRow] {
        scope.isAll
            ? globalAggregates.map(\.dailyRow)
            : scopedAggregates.map(\.dailyRow)
    }
    /// Singleton-row probe — fires once per scan cycle. Drives the
    /// `Derived` cache refresh so the bucketing runs at most once per
    /// cycle instead of on every body render.
    @Query(ScanMetaFetchDescriptor.scanCompletedProbe)
    private var scanMeta: [ClaudeCodeMeta]

    @Environment(\.usageEngines) private var engines

    @State private var cachedDerived = Derived()
    /// The engine's month-end cost for this card's scope; `nil` until it
    /// answers.
    @State private var projection: Estimate?

    /// The bars, the header's total and the month. Each bucket carries its
    /// breakdown and top models, built here, so hovering a bar reads
    /// precomputed numbers and never re-sums the rows.
    ///
    /// The clock is an input (the month, its days left, which days are
    /// "this week"), read at each refresh. A new day rebuilds the whole page
    /// (`ContentView`'s `.id(dayKey)`), so the month rolls over with it.
    private struct Derived {
        var buckets: [PacerChartBucket] = []
        var totalCost: Double = 0
        /// The 30-day total would print a number another card already does:
        /// the month's (every active day is this month's), or today's or
        /// this week's.
        var totalRepeats = false
        var month = MonthTotals()
    }

    struct MonthTotals: Equatable {
        var breakdown = CostBreakdown.zero
        var activeDays = 0
        var daysLeft = 0
        /// "October"
        var name = ""
        /// Its cost, tokens and breakdown are today's or this week's.
        var repeatsShorterWindow = false

        var cost: Double { breakdown.total }
        var tokens: Int64 { breakdown.tokens.all }
        var hasData: Bool { activeDays > 0 }
        var averageActiveDayCost: Double { activeDays > 0 ? cost / Double(activeDays) : 0 }
    }

    private func refreshDerived() {
        let now = Date()
        let cal = Calendar.current
        let windows = PeriodWindows(now: now, calendar: cal)
        var builder = PacerChartBucketBuilder()
        var month = MonthTotals()
        var active = Set<String>()
        for row in aggregates {
            builder.add(row.date, row.costBreakdown, model: row.model)
            active.insert(row.date)
            if row.date >= windows.monthStart && row.date <= windows.today {
                month.breakdown += row.costBreakdown
            }
        }
        let buckets = builder.buckets(last: 30)
        let monthDays = windows.month(active)
        month.activeDays = monthDays.count
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        month.daysLeft = max(0, daysInMonth - cal.component(.day, from: now))
        month.name = Self.monthName.string(from: now)
        month.repeatsShorterWindow = windows.repeatsTodayOrWeek(monthDays, in: active)
        // The chart's days, not every row fetched: the header total is the
        // last 30 bars' sum.
        let chartDays = Set(buckets.map(\.id)).intersection(active)
        cachedDerived = Derived(
            buckets: buckets,
            totalCost: buckets.reduce(0) { $0 + $1.total },
            totalRepeats: chartDays == monthDays || windows.repeatsTodayOrWeek(chartDays, in: active),
            month: month
        )
    }

    private func refreshProjection() async {
        // This card's scope, so the month-end projection is the account the
        // rest of the card is counting.
        let account = scope.accountId
        guard let engine = engines?.engine(forAccount: account) else { return }
        let answer = await askEngine { await engine.ask(.projectedCost(.thisMonth)) }
        // An ask queues behind a refit and can take seconds. One for a scope
        // the user has since left must not land over the new scope's answer.
        guard account == scope.accountId else { return }
        projection = answer
    }

    var body: some View {
        // Read here as well as inside `PacerCard`'s stored closures (#140).
        let d = cachedDerived
        let projection = self.projection
        PacerCard("Last 30 days", trailing: {
            // The hovered day's numbers are in the card floating over the
            // chart, so this slot no longer swaps on hover and the header
            // never moves.
            if d.totalCost > 0 && !d.totalRepeats {
                Text("total \(pacerCost(d.totalCost))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(pacerCostExact(d.totalCost))
            }
        }) {
            if d.buckets.isEmpty {
                Text("No usage in the last 30 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 220)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    PacerStackedPartChart(d.buckets, kind: .day, onTap: onDayTap)
                        .accessibilityLabel("Daily cost by part over the last 30 days")
                        .accessibilityHint(onDayTap != nil ? "Click a bar to drill into that day" : "")
                    Divider()
                    monthSection(d.month, projection: projection)
                }
            }
        }
        .onAppear { refreshDerived() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshDerived() }
        // The scope is a refresh trigger like any other. Without it the cache
        // holds the previous account's numbers until the *next scan cycle*
        // happens to fire — which on an idle machine is seven to ten seconds,
        // and looks exactly like a very slow render rather than a stale one.
        .onChange(of: scope.accountId) { _, _ in refreshDerived() }
        // Keyed on the scope for the same reason: the month-end projection
        // is that account's engine's, and kept the old one's until a refit.
        .task(id: scope.accountId) {
            self.projection = nil
            await refreshProjection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshProjection() }
        }
    }

    // MARK: - This month

    @ViewBuilder
    private func monthSection(_ month: MonthTotals, projection: Estimate?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("This month")
                    .font(.headline)
                Spacer(minLength: 8)
                Text("\(month.name) · \(month.daysLeft) day\(month.daysLeft == 1 ? "" : "s") left")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !month.hasData {
                Text("No usage this month yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                            count: 4
                        ),
                        alignment: .leading,
                        spacing: 12
                    ) {
                        if !month.repeatsShorterWindow {
                            MetricTile(
                                value: pacerCost(month.cost),
                                label: "cost",
                                tooltip: pacerCostExact(month.cost)
                            )
                            MetricTile(
                                value: pacerTokens(month.tokens),
                                label: "tokens",
                                tooltip: pacerTokensExact(month.tokens)
                            )
                            MetricTile(
                                value: "\(month.activeDays)",
                                label: "active days",
                                hint: "avg \(pacerCost(month.averageActiveDayCost)) each",
                                tooltip: "\(pacerCostExact(month.averageActiveDayCost)) per active day"
                            )
                        }
                        // Always drawn, "—" until the engine answers: a tile
                        // that appeared seconds after the card would grow it.
                        MetricTile(
                            value: projectionValue(projection, month: month),
                            label: "by month end",
                            tooltip: projectionHelp(projection, month: month)
                        )
                    }
                    if !month.repeatsShorterWindow, PacerCostBreakdownView.hasContent(month.breakdown) {
                        PacerCostBreakdownView(month.breakdown)
                    }
                }
            }
        }
    }

    /// "≈$3.4k", a point value; never below what the month has already
    /// spent. "—" until there is an answer worth showing.
    private func projectionValue(_ p: Estimate?, month: MonthTotals) -> String {
        guard let p, !p.isInsufficient else { return "—" }
        return "≈\(IntelligenceFormatting.approxCost(max(p.value, month.cost)))"
    }

    /// The exact projection, its calibrated range and how it compares with
    /// the month's pace so far. When the month section is down to this one
    /// tile, the month-to-date figures it left off ride here too.
    private func projectionHelp(_ p: Estimate?, month: MonthTotals) -> String {
        var parts: [String] = []
        if let p, !p.isInsufficient {
            parts.append(pacerCostExact(max(p.value, month.cost)))
            if let band = p.interval80 {
                parts.append(IntelligenceFormatting.anchors(band))
            }
            if let hint = paceHint(p, month: month) { parts.append(hint) }
        } else {
            parts.append("Not enough of this month yet to project")
        }
        if month.repeatsShorterWindow {
            parts.append("so far \(pacerCostExact(month.cost)) · \(pacerTokensExact(month.tokens)) tokens")
        }
        return parts.joined(separator: " · ")
    }

    /// "↑ 18% above pace" — the engine's projection vs a pure linear
    /// forward-fill of the current run rate. Only meaningful past the
    /// first few days.
    private func paceHint(_ p: Estimate, month: MonthTotals) -> String? {
        let cal = Calendar.current
        let now = Date()
        let dayOfMonth = cal.component(.day, from: now)
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        guard dayOfMonth >= 3 else { return "if rate holds" }
        let purePace = month.cost / Double(dayOfMonth) * Double(daysInMonth)
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

    /// Built once: the month section used to allocate a formatter on every
    /// body pass.
    private static let monthName: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM")
        return f
    }()
}
