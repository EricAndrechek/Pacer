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
/// Under the chart, the month so far (`PacerMonthSummary`): cost, tokens,
/// active days and the engine's month-end projection, the spent → projected
/// bar, and the shared breakdown. It opens with an eyebrow, not a second
/// title, so this is one card with one title. Every tile is drawn every day,
/// the 1st included, when the month's numbers are today's: the owner chose
/// a card that looks the same every day over hiding a repeat.
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
    /// The clock is an input (the month, its days left, the day of the month
    /// the pace hint divides by), read at each refresh and nowhere else. The
    /// refresh is keyed on the day (`PacerToday`), so the month rolls over at
    /// midnight even before `ContentView`'s `.id(dayKey)` rebuilds the page.
    private struct Derived {
        var buckets: [PacerChartBucket] = []
        var totalCost: Double = 0
        var month = MonthTotals()
    }

    struct MonthTotals: Equatable {
        var breakdown = CostBreakdown.zero
        var activeDays = 0
        var dayOfMonth = 1
        var daysInMonth = 30
        /// "October"
        var name = ""

        var cost: Double { breakdown.total }
        var daysLeft: Int { max(0, daysInMonth - dayOfMonth) }
    }

    private func refreshDerived() {
        let now = Date()
        let cal = Calendar.current
        let today = TokenSample.formatDate(now)
        let monthStart = TokenSample.formatDate(cal.dateInterval(of: .month, for: now)?.start ?? now)
        var builder = PacerChartBucketBuilder()
        var month = MonthTotals()
        var monthDays = Set<String>()
        for row in aggregates {
            builder.add(row.date, row.costBreakdown, model: row.model)
            if row.date >= monthStart && row.date <= today {
                month.breakdown += row.costBreakdown
                monthDays.insert(row.date)
            }
        }
        let buckets = builder.buckets(last: 30)
        month.activeDays = monthDays.count
        month.dayOfMonth = cal.component(.day, from: now)
        month.daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        month.name = Self.monthName.string(from: now)
        cachedDerived = Derived(
            buckets: buckets,
            // The chart's days, not every row fetched: the header total is
            // the last 30 bars' sum.
            totalCost: buckets.reduce(0) { $0 + $1.total },
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
        // Read in body so a new day is a tracked input (see `Derived`).
        let day = PacerToday.shared.key
        PacerCard("Last 30 days", trailing: {
            // The hovered day's numbers are in the card floating over the
            // chart, so this slot no longer swaps on hover and the header
            // never moves.
            if d.totalCost > 0 {
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
                    PacerMonthSummary(monthModel(d.month, projection: projection))
                }
            }
        }
        .onAppear { refreshDerived() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshDerived() }
        // The clock: the month, its days left and the pace hint's day.
        .onChange(of: day) { _, _ in refreshDerived() }
        // The scope is a refresh trigger like any other. Without it the cache
        // holds the previous account's numbers until the *next scan cycle*
        // happens to fire — which on an idle machine is seven to ten seconds,
        // and looks exactly like a very slow render rather than a stale one.
        .onChange(of: scope.accountId) { _, _ in refreshDerived() }
        // Keyed on the scope for the same reason: the month-end projection
        // is that account's engine's, and kept the old one's until a refit.
        // And on the day: a new month is a new question.
        .task(id: ProjectionKey(account: scope.accountId, day: day)) {
            self.projection = nil
            await refreshProjection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshProjection() }
        }
    }

    // MARK: - This month

    /// What the projection task is keyed on.
    private struct ProjectionKey: Equatable {
        let account: String?
        let day: String
    }

    /// The month section's plain value: the cached totals and the engine's
    /// answer, formatted. O(1), so it is built in `body`.
    private func monthModel(_ month: MonthTotals, projection p: Estimate?) -> PacerMonthSummary.Model {
        let state: PacerMonthSummary.Projection
        if let p, !p.isInsufficient {
            // A point value, never below what the month has already spent.
            let usd = max(p.value, month.cost)
            state = .estimate(
                usd: usd,
                label: "≈\(IntelligenceFormatting.approxCost(usd))",
                help: projectionHelp(p, usd: usd, month: month))
        } else if p != nil {
            state = .unavailable(help: "Not enough of this month yet to project")
        } else {
            state = .pending
        }
        return PacerMonthSummary.Model(
            name: month.name,
            daysLeft: month.daysLeft,
            breakdown: month.breakdown,
            activeDays: month.activeDays,
            projection: state)
    }

    /// The exact projection, its calibrated range and how it compares with
    /// the month's pace so far.
    private func projectionHelp(_ p: Estimate, usd: Double, month: MonthTotals) -> String {
        var parts: [String] = [pacerCostExact(usd)]
        if let band = p.interval80 {
            parts.append(IntelligenceFormatting.anchors(band))
        }
        if let hint = paceHint(p, month: month) { parts.append(hint) }
        return parts.joined(separator: " · ")
    }

    /// "↑ 18% above pace" — the engine's projection vs a pure linear
    /// forward-fill of the current run rate. Only meaningful past the
    /// first few days. The day of the month is the cached one, so no clock
    /// is read here.
    private func paceHint(_ p: Estimate, month: MonthTotals) -> String? {
        guard month.dayOfMonth >= 3 else { return "if rate holds" }
        let purePace = month.cost / Double(month.dayOfMonth) * Double(month.daysInMonth)
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
