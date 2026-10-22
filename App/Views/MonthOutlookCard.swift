import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// "This month": month-to-date spend with the engine's month-end projection,
/// the labelled spent → projected bar, the month's tokens and active days,
/// and the shared breakdown. Drawn by `PacerMonthSummary`, which takes a
/// plain value, so the render suite draws the real card.
///
/// Its own card under "Last 30 days" again. For a round the two were one
/// card, reading the same rows; but they are different periods, and the
/// owner chose two cards.
struct MonthOutlookCard: View {
    init(scopeAccountId: String? = nil) {
        // From the 1st of the month, captured here: ContentView's
        // `.id(dayKey)` rebuilds the page at midnight, so a new month gets a
        // new lower bound. Until it does, `refreshDerived` keeps only the
        // current month's rows, so the card is right either way. ≤ 31 days ×
        // N models, on the `(date)` index.
        let now = Date()
        let firstOfMonth = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        let lower = TokenSample.formatDate(firstOfMonth)
        _globalAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date >= lower }
        )
        // Taken as a parameter rather than read from `UsageScope` here, so a
        // scope change re-runs this initialiser: a `@Query` predicate is
        // captured once at init.
        let acct = scopeAccountId ?? UsageScope.noAccountSentinel
        _scopedAggregates = Query(
            filter: #Predicate<AccountDailyAggregate> {
                $0.date >= lower && $0.accountId == acct
            }
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
    /// Singleton-row probe — fires once per scan cycle, the "data changed"
    /// signal the cached totals refresh on.
    @Query(ScanMetaFetchDescriptor.scanCompletedProbe)
    private var scanMeta: [ClaudeCodeMeta]

    @Environment(\.usageEngines) private var engines

    @State private var cached = MonthTotals()
    /// The engine's month-end cost for this card's scope; `nil` until it
    /// answers.
    @State private var projection: Estimate?

    /// The month so far, summed once per refresh rather than on every body
    /// pass.
    ///
    /// The clock is an input (the month, its days left, the day of the month
    /// the pace hint divides by), read at each refresh and nowhere else. The
    /// refresh is keyed on the day (`PacerToday`), so the month rolls over at
    /// midnight even before `ContentView`'s `.id(dayKey)` rebuilds the page.
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
        var month = MonthTotals()
        var monthDays = Set<String>()
        for row in aggregates where row.date >= monthStart && row.date <= today {
            month.breakdown += row.costBreakdown
            monthDays.insert(row.date)
        }
        month.activeDays = monthDays.count
        month.dayOfMonth = cal.component(.day, from: now)
        month.daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        month.name = Self.monthName.string(from: now)
        cached = month
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
        // Read here, not only inside `PacerCard`'s stored closures (#140).
        let month = cached
        let projection = self.projection
        // Read in body so a new day is a tracked input (see `MonthTotals`).
        let day = PacerToday.shared.key
        PacerMonthSummary(monthModel(month, projection: projection))
            .onAppear { refreshDerived() }
            .onChange(of: scanMeta.first?.value) { _, _ in refreshDerived() }
            // The clock: the month, its days left and the pace hint's day.
            .onChange(of: day) { _, _ in refreshDerived() }
            // The scope is an input to the cache like the data is: without
            // this the card kept the previous account after a switch until a
            // scan ingested something, which on an idle machine may be never
            // (#141).
            .onChange(of: scope.accountId) { _, _ in refreshDerived() }
            // Keyed on the scope for the same reason: the month-end projection
            // is that account's engine's, and kept the old one's until a
            // refit. And on the day: a new month is a new question.
            .task(id: ProjectionKey(account: scope.accountId, day: day)) {
                self.projection = nil
                await refreshProjection()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
                Task { await refreshProjection() }
            }
    }

    /// What the projection task is keyed on.
    private struct ProjectionKey: Equatable {
        let account: String?
        let day: String
    }

    /// The card's plain value: the cached totals and the engine's answer,
    /// formatted. O(1), so it is built in `body`.
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

    /// Built once: the card used to allocate a formatter on every body pass.
    private static let monthName: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM")
        return f
    }()
}
