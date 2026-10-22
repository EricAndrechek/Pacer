import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

/// "All time" view — lifetime totals, monthly trend, the activity
/// heatmap, and most expensive days. Reads from `DailyAggregate` (the
/// canonical roll-up; pre-summed, so no per-row cost calc here).
///
/// Order: range summary (with its cost breakdown) → 26-week heatmap →
/// monthly bar chart → top expensive days table.
///
/// A single time-range picker in the page header scopes the
/// range-aware cards (LifetimeSummary, TopDays). HeatmapCard and
/// MonthlyChartCard ignore it — they're convention-driven windows
/// (52 weeks / 12 months) where the fixed scope IS the card's
/// purpose. The single picker replaces the two independent pickers
/// the cards each carried previously, which let the two card scopes
/// drift apart (top "Last 90 days", bottom "Lifetime") in ways that
/// felt like one picker was controlling the other.
struct HistoryView: View {
    @State private var modalRoot: PacerModalDestination?
    /// Read here so a scope change re-runs the child initialisers — a
    /// `@Query` predicate is captured once at init.
    @State private var scope = UsageScope.shared

    @AppStorage("pacer.history.range", store: PacerSettings.store)
    private var rangeRaw: String = TimeRange.all.rawValue

    private var range: TimeRange { TimeRange(rawValue: rangeRaw) ?? .all }
    private var rangeBinding: Binding<TimeRange> {
        Binding(get: { range }, set: { rangeRaw = $0.rawValue })
    }

    var body: some View {
        // Read in this body and captured below, not read inside
        // `PageScaffold`'s stored content closure. See `ProjectsView.body`
        // (#140).
        let range = self.range, scopeAccountId = scope.accountId
        PageScaffold(
            "History",
            subtitle: "Totals, activity, and your most expensive days.",
            trailing: {
                Picker("Time range", selection: rangeBinding) {
                    ForEach(TimeRange.allCases) { r in
                        Text(r.shortLabel).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .pacerDenseControl()
                .labelsHidden()
            }
        ) {
            LifetimeSummaryCard(range: range)
            HeatmapCard(scopeAccountId: scopeAccountId) { dayKey in
                Log.write("Navigation", "open day \(dayKey)")
                modalRoot = .day(date: dayKey)
            }
            MonthlyChartCard(scopeAccountId: scopeAccountId)
            TopDaysCard(range: range) { dayKey in
                Log.write("Navigation", "open day \(dayKey)")
                modalRoot = .day(date: dayKey)
            }
        }
        .pacerModalNavigation(modalRoot, root: $modalRoot)
    }
}

// MARK: - Range-scoped summary

/// The range's summary — the shared `PacerSummaryCard`, as the detail
/// modals open on — re-scoped by the page-level range. Range comes from
/// `HistoryView`'s single `@AppStorage` so changing it affects this
/// card and `TopDaysCard` together.
///
/// Card vs Content split is the `.id(range)` trick: the outer Card
/// just owns the range parameter; the inner Content takes `range` as
/// an init argument and scopes its @Query accordingly. `.id(range)`
/// on the content forces SwiftData to re-create the @Query each time
/// the range changes — which is the only way to push the range
/// predicate into the fetch layer instead of filtering 700+ rows in
/// memory on every scan tick.
private struct LifetimeSummaryCard: View {
    @State private var scope = UsageScope.shared
    let range: TimeRange

    var body: some View {
        // The `.id()` value is prefixed per-card so it can't collide
        // with another `.id(range)` sibling in the same LazyVStack.
        // Without the prefix, SwiftUI's identity system treated this
        // card and TopDaysContent (which also re-init on range change)
        // as the same view and dropped one — the bottom of the page
        // was just empty space where TopDays should have rendered.
        LifetimeSummaryContent(range: range, scopeAccountId: scope.accountId)
            .id("lifetime-summary-\(range.rawValue)-\(scope.accountId ?? "all")")
    }
}

private struct LifetimeSummaryContent: View {
    let range: TimeRange
    /// The range's start and the account, as this copy was built with them:
    /// the Projects and Sessions counts fetch with these. Both are in the
    /// parent's `.id`, so a change builds a new copy rather than leaving
    /// this one counting the old range or account.
    private let since: Date?
    private let scopeAccountId: String?

    @Query private var globalAggregates: [DailyAggregate]
    @Query private var scopedAggregates: [AccountDailyAggregate]
    @State private var scope = UsageScope.shared
    @Environment(\.modelContext) private var modelContext
    /// Fires once per scan cycle: the counts' refresh trigger. They are
    /// fetched, not `@Query`-bound — see `ActivityCounts`.
    @Query(ScanMetaFetchDescriptor.scanCompletedProbe)
    private var scanMeta: [ClaudeCodeMeta]

    /// Projects and sessions in the range, from the project-day and session
    /// rollups (`RangeActivityCounts`). A `@Query` over either table would
    /// re-read every row in range on every store save; sessions are a SQL
    /// COUNT instead, and projects — which need the rows themselves — are
    /// read off the main actor, and only when the range's project-day count
    /// moved or attribution changed.
    private struct ActivityCounts: Equatable {
        var sessions: Int?
        var projects: Int?
        /// The project-day count the projects read last ran at.
        var projectDays: Int?
    }
    @State private var counts = ActivityCounts()
    /// One projects read at a time; a trigger during one asks for another
    /// after it, rather than starting a second detached read beside it.
    @State private var projectsLoading = false
    @State private var projectsRerun = false

    /// Every account, or one. Both queries are live, so switching is a
    /// re-read rather than a recompute.
    private var aggregates: [DailyRow] {
        scope.isAll
            ? globalAggregates.map(\.dailyRow)
            : scopedAggregates.map(\.dailyRow)
    }

    init(range: TimeRange, scopeAccountId: String? = nil) {
        self.range = range
        self.since = range.since
        self.scopeAccountId = scopeAccountId
        let acct = scopeAccountId ?? UsageScope.noAccountSentinel
        if let since = range.since {
            let cutoffString = TokenSample.formatDate(since)
            _globalAggregates = Query(
                filter: #Predicate<DailyAggregate> { $0.date >= cutoffString },
                sort: \DailyAggregate.date,
                order: .reverse
            )
            _scopedAggregates = Query(
                filter: #Predicate<AccountDailyAggregate> {
                    $0.date >= cutoffString && $0.accountId == acct
                },
                sort: \AccountDailyAggregate.date,
                order: .reverse
            )
        } else {
            // `.all` still needs every row — but we can't show
            // "lifetime since YYYY-MM-DD" without it. Acceptable
            // because (a) .all is opt-in, and (b) it's still cached
            // behind a scan-meta tick so the walk runs once per cycle.
            _globalAggregates = Query(
                sort: \DailyAggregate.date, order: .reverse
            )
            _scopedAggregates = Query(
                filter: #Predicate<AccountDailyAggregate> { $0.accountId == acct },
                sort: \AccountDailyAggregate.date, order: .reverse
            )
        }
    }

    /// What the card draws, derived from the range's rows (`refreshSummary`),
    /// not in `body`: the strip walks every day of the range.
    private struct Summary {
        var breakdown = CostBreakdown.zero
        var distinctDays = 0
        var distinctModels = 0
        var activity = PeriodActivity.empty
        var span: String?
        var axis: [PacerActivityStrip.AxisLabel] = []
        var cellHelp: [String] = []
    }
    @State private var cachedSummary: Summary?

    /// Changes whenever a row the summary is built from changes: a new day
    /// or model (count), a new turn (tokens, cost), a re-price (cost). The
    /// scope picks the table, and a scope or range change builds a new copy
    /// of this view (the parent's `.id`); the page is rebuilt at midnight, so
    /// "today" cannot move under it.
    private struct RowsFingerprint: Equatable {
        var count = 0
        var tokens: Int64 = 0
        var cost = 0.0
    }

    private var rowsFingerprint: RowsFingerprint {
        var f = RowsFingerprint()
        for row in aggregates {
            f.count += 1
            f.tokens += row.tokens.all
            f.cost += row.totalCostUSD
        }
        return f
    }

    /// The range's cost by part (#225), its days and models, and its strip:
    /// every day from the range's first (`TimeRange.since`, exactly the
    /// range's N days; over all time, the first active day) to today, each
    /// one's height what that day cost. The rows are the daily rollup the
    /// rest of the card is summed from, so the strip and the big figure are
    /// the same dollars.
    private static func derive(_ rows: [DailyRow], since: Date?) -> Summary {
        var s = Summary()
        var costByDay: [String: Double] = [:]
        var models = Set<String>()
        for row in rows {
            s.breakdown += row.costBreakdown
            costByDay[row.date, default: 0] += row.totalCostUSD
            models.insert(row.model)
        }
        let dates = Set<String>(costByDay.keys)
        s.distinctDays = dates.count
        s.distinctModels = models.count
        let today: String = PacerToday.shared.key
        guard let start = since.map(TokenSample.formatDate) ?? dates.min() else { return s }
        let end: String = max(today, dates.max() ?? today)
        let activity = PeriodActivity.days(active: dates, cost: costByDay, from: start, through: end)
        let year: Int = Calendar.current.component(.year, from: PacerClock.now)
        s.activity = activity
        s.span = pacerActivitySpan(activity) { pacerFactDay($0, currentYear: year) }
        s.axis = pacerDayAxis(activity, today: today, currentYear: year)
        s.cellHelp = pacerActivityCellHelp(activity, currentYear: year)
        return s
    }

    private func refreshSummary() {
        cachedSummary = Self.derive(aggregates, since: since)
    }

    /// "1,284"; "—" until the first read lands.
    private static func count(_ n: Int?) -> String {
        n.map { $0.formatted() } ?? "—"
    }

    private var cardTitle: String {
        switch range {
        case .sevenDays:  return "Last 7 days"
        case .thirtyDays: return "Last 30 days"
        case .ninetyDays: return "Last 90 days"
        case .oneYear:    return "Last 12 months"
        case .all:        return "Lifetime"
        }
    }

    var body: some View {
        // The cached summary, or on the first frame (before `.onAppear` has
        // run) the same summary built once here, so the card opens full
        // rather than flashing empty on every range switch.
        let summary = cachedSummary ?? Self.derive(aggregates, since: since)
        // Read here and handed down, not read inside `PacerCard`'s stored
        // closures, so a count landing redraws this view (#140).
        let counts = self.counts
        let fingerprint = rowsFingerprint
        Group {
            if summary.distinctDays == 0 {
                PacerCard(cardTitle) {
                    Text(range == .all
                         ? "No history yet — start using Claude Code and Pacer will catch up."
                         : "No activity in this range. Try widening the time window.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                // The shared summary card, as Day and Project detail open on.
                // The breakdown, a card of its own here until round 6, is in
                // it, as it is in theirs.
                PacerSummaryCard(cardTitle, model: PacerSummaryModel(
                    breakdown: summary.breakdown,
                    stats: [
                        PacerSummaryFact("sessions", Self.count(counts.sessions)),
                        PacerSummaryFact("projects", Self.count(counts.projects)),
                        PacerSummaryFact("models", "\(summary.distinctModels)"),
                    ],
                    activity: summary.activity,
                    span: summary.span,
                    axis: summary.axis,
                    cellHelp: summary.cellHelp))
            }
        }
        .onAppear {
            refreshSummary()
            refreshCounts(force: true)
        }
        .onChange(of: fingerprint) { _, _ in refreshSummary() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCounts(force: false) }
        // A merge can fold one project into another without changing how
        // many project-day rows there are, so it re-reads regardless.
        .onReceive(NotificationCenter.default.publisher(for: .pacerScanCycleDidComplete)) { note in
            guard let summary = note.object as? ScanCycleSummary,
                  summary.projectAttributionChanged else { return }
            refreshCounts(force: true)
        }
    }

    /// Sessions every time (one COUNT); projects when the range's
    /// project-day rows moved, or when `force`. A project new to the range
    /// always brings a project-day row with it.
    private func refreshCounts(force: Bool) {
        counts.sessions = RangeActivityCounts.sessions(
            modelContext, since: since, accountId: scopeAccountId)
        let days = RangeActivityCounts.projectDays(
            modelContext, since: since, accountId: scopeAccountId)
        guard force || days != counts.projectDays else { return }
        counts.projectDays = days
        loadProjects()
    }

    private func loadProjects() {
        guard !projectsLoading else {
            projectsRerun = true
            return
        }
        projectsLoading = true
        let container = modelContext.container
        let since = self.since, account = scopeAccountId
        Task {
            // Its own context, off the main actor: reading a lifetime of
            // project-day rows faults every one of them.
            let projects = await Task.detached(priority: .utility) {
                RangeActivityCounts.projects(ModelContext(container), since: since, accountId: account)
            }.value
            counts.projects = projects
            projectsLoading = false
            if projectsRerun {
                projectsRerun = false
                loadProjects()
            }
        }
    }
}

// MARK: - Monthly bar chart

private struct MonthlyChartCard: View {
    /// Scoped to the chart's 12-month display window — the unbounded
    /// query was loading every DailyAggregate row (730+ on a 2-year DB)
    /// just so `refreshMonthly()` could group, sort, and `.suffix(12)`.
    /// 13 months of leeway covers any partial first month inside the
    /// chart's leftmost bar.
    @Query private var globalAggregates: [DailyAggregate]
    @Query private var scopedAggregates: [AccountDailyAggregate]
    @State private var scope = UsageScope.shared
    @Query(ScanMetaFetchDescriptor.scanCompletedProbe)
    private var scanMeta: [ClaudeCodeMeta]

    private var aggregates: [DailyRow] {
        scope.isAll
            ? globalAggregates.map(\.dailyRow)
            : scopedAggregates.map(\.dailyRow)
    }

    init(scopeAccountId: String? = nil) {
        let cutoffString = TokenSample.formatDate(
            Calendar.current.date(byAdding: .month, value: -13, to: Date()) ?? .distantPast
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

    /// Each month's bar, with its breakdown and top models precomputed for
    /// the hover card, and the header's total.
    @State private var cachedMonthly: [PacerChartBucket] = []
    @State private var cachedTotal: Double = 0

    private var monthly: [PacerChartBucket] { cachedMonthly }

    /// Roll the days up into months, once per scan tick or scope switch
    /// rather than on every body render.
    private func refreshMonthly() {
        var builder = PacerChartBucketBuilder()
        for row in aggregates {
            guard let month = PacerChartBucket.monthKey(row.date) else { continue }
            builder.add(month, row.costBreakdown, model: row.model)
        }
        cachedMonthly = builder.buckets(last: 12)
        cachedTotal = cachedMonthly.reduce(0) { $0 + $1.total }
    }

    var body: some View {
        let total = cachedTotal
        let monthly = self.monthly
        PacerCard("Last 12 months", trailing: {
            // The hovered month's numbers are in the card floating over the
            // chart; this slot never swaps.
            if !monthly.isEmpty {
                Text("total \(pacerCost(total))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(pacerCostExact(total))
            }
        }) {
            if monthly.isEmpty {
                Text("No monthly history yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 200)
            } else {
                // Every month keeps its total on top, as before: a dozen
                // labels fit, and the month-to-month read is the point.
                PacerStackedPartChart(monthly, kind: .month, annotating: monthly.count)
                    .accessibilityLabel("Cost by month for the last 12 months")
            }
        }
        .onAppear { refreshMonthly() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshMonthly() }
        // The scope is a refresh trigger like any other. Without it the cache
        // holds the previous account's numbers until the *next scan cycle*
        // happens to fire — which on an idle machine is seven to ten seconds,
        // and looks exactly like a very slow render rather than a stale one.
        .onChange(of: scope.accountId) { _, _ in refreshMonthly() }
    }
}

// MARK: - Top days

// `TopDaysSort` and the ranking itself live in PacerCore (`DayRanking`), so
// the order "Tokens" produces is tested rather than re-derived here (#215).
// The days it picks are shown in the shared usage table, which sorts by the
// same column; `TopDaysSort` raw values are what the sort is stored as.

private struct TopDaysCard: View {
    @State private var scope = UsageScope.shared
    let range: TimeRange
    let onDayTap: (String) -> Void

    @AppStorage("pacer.history.topDaysSort", store: PacerSettings.store)
    private var sortRaw: String = TopDaysSort.cost.rawValue
    @AppStorage("pacer.history.topDaysSortDescending", store: PacerSettings.store)
    private var descending: Bool = true

    /// A sort stored under a retired column id ("writeShare") ranks by its
    /// successor.
    private var sort: TopDaysSort { TopDaysSort(stored: sortRaw) }

    var body: some View {
        // The `.id()` value is prefixed per-card so it can't collide
        // with LifetimeSummary's own `.id(range)` sibling. See the
        // matching comment on LifetimeSummaryCard for why.
        TopDaysContent(
            range: range,
            scopeAccountId: scope.accountId,
            sort: sort,
            descending: descending,
            onDayTap: onDayTap,
            onSort: { new in
                sortRaw = TopDaysSort(column: UsageColumn(rawValue: new.column) ?? .cost).rawValue
                descending = new.descending
            }
        )
        .id("top-days-\(range.rawValue)-\(scope.accountId ?? "all")")
    }
}

private struct TopDaysContent: View {
    let range: TimeRange
    let sort: TopDaysSort
    let descending: Bool
    let onDayTap: (String) -> Void
    let onSort: (PacerUsageSort) -> Void

    @Query private var globalAggregates: [DailyAggregate]
    @Query private var scopedAggregates: [AccountDailyAggregate]
    @State private var scope = UsageScope.shared

    /// Every account, or one. Both queries are live, so switching is a
    /// re-read rather than a recompute.
    private var aggregates: [DailyRow] {
        scope.isAll
            ? globalAggregates.map(\.dailyRow)
            : scopedAggregates.map(\.dailyRow)
    }

    init(
        range: TimeRange,
        scopeAccountId: String? = nil,
        sort: TopDaysSort,
        descending: Bool,
        onDayTap: @escaping (String) -> Void,
        onSort: @escaping (PacerUsageSort) -> Void
    ) {
        self.range = range
        self.sort = sort
        self.descending = descending
        self.onDayTap = onDayTap
        self.onSort = onSort
        let acct = scopeAccountId ?? UsageScope.noAccountSentinel
        if let since = range.since {
            let cutoffString = TokenSample.formatDate(since)
            _globalAggregates = Query(
                filter: #Predicate<DailyAggregate> { $0.date >= cutoffString },
                sort: \DailyAggregate.date,
                order: .reverse
            )
            _scopedAggregates = Query(
                filter: #Predicate<AccountDailyAggregate> {
                    $0.date >= cutoffString && $0.accountId == acct
                },
                sort: \AccountDailyAggregate.date,
                order: .reverse
            )
        } else {
            _globalAggregates = Query(
                sort: \DailyAggregate.date, order: .reverse
            )
            _scopedAggregates = Query(
                filter: #Predicate<AccountDailyAggregate> { $0.accountId == acct },
                sort: \AccountDailyAggregate.date, order: .reverse
            )
        }
    }

    /// Toggle to reveal the next 90 (showing top 100). The user flagged
    /// "showing top 10 silently" — now there's a chip in the header
    /// indicating "showing N of M" plus a Show more / Show less link.
    @State private var showAll: Bool = false

    private typealias DayRow = DayTotal

    /// Days inside the active range, sorted by the user's chosen
    /// field. Computed per body fire from the range-scoped `@Query` —
    /// the previous `@State`-cached design populated on `.onAppear`,
    /// which fires AFTER first body and made every `.id(range)` re-init
    /// flash an empty list. The walk is O(aggregates) over a scoped
    /// slice (≤ ~5k rows even on .all); HoverRow lives inside each row
    /// so the parent body doesn't re-fire on row hover.
    private var sortedRows: [DayRow] {
        DayRanking.ranked(aggregates, by: sort, descending: descending)
    }

    private var title: String {
        switch sort {
        case .cost:         return "Most expensive days"
        case .tokens:       return "Heaviest token days"
        case .date:         return descending ? "Most recent days" : "Earliest days"
        case .input:        return "Heaviest input days"
        case .output:       return "Heaviest output days"
        case .cacheRead:    return "Heaviest cache-read days"
        case .cacheWrite:   return "Heaviest cache-write days"
        case .cacheWrite5m: return "Heaviest 5m-write days"
        case .cacheWrite1h: return "Heaviest 1h-write days"
        case .hitRate:      return descending ? "Best-cached days" : "Least-cached days"
        case .outShare:     return descending ? "Most output-heavy days" : "Least output-heavy days"
        case .mix:          return descending ? "Most uncached days" : "Most cached days"
        }
    }

    var body: some View {
        let all = sortedRows
        let visible: [DayRow] = showAll
            ? Array(all.prefix(min(all.count, 100)))
            : Array(all.prefix(10))
        // Ranked here, over every day, and only then cut to 10 (or 100): the
        // table sorts what it is given by the same column, ties included
        // (`DayRanking`), so it shows these days in this order.
        let tableRows: [PacerUsageRow<PacerUsageNoExtra>] = visible.map { day in
            PacerUsageRow(id: day.date, label: prettyDate(day.date), sortLabel: day.date,
                          tokens: day.tokens, costParts: day.costParts, cost: day.cost)
        }
        let tableSort = PacerUsageSort(sort.column, descending: descending)
        let trailing = Text(all.isEmpty ? "" : "showing \(visible.count) of \(all.count)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        return Group {
            if all.isEmpty {
                PacerCard(title, trailing: { trailing }) {
                    Text("No data yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                // The table is the card: its title over the native header.
                // The rank number and the bar that used to lead each row
                // are gone: the table's order is the rank, and the bar drew
                // the number printed beside it a second time.
                PacerTableCard(title, trailing: { trailing }) {
                    PacerUsageTable(
                        rows: tableRows,
                        tableId: "topDays",
                        labelTitle: "Date",
                        sort: tableSort,
                        onSort: onSort,
                        onOpen: { row in onDayTap(row.id) },
                        rowMenu: { row in
                            Button("Open day") { onDayTap(row.id) }
                            Divider()
                            Button("Copy date") { pacerCopyToPasteboard(row.id) }
                            // Copy the exact dollars-and-cents — the row shows
                            // "$10.8k" but a copy-to-paste should be the precise value.
                            Button("Copy cost") { pacerCopyToPasteboard(pacerCostExact(row.cost)) }
                        })
                } footer: {
                    if all.count > 10 {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    showAll.toggle()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(showAll ? "Show top 10" : "Show top 100")
                                    Image(systemName: showAll ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    /// `2026-04-30` → `Thu Apr 30`. Compact + day-of-week so the user
    /// can spot patterns ("oh I always burn on Wednesdays"). The two
    /// `DateFormatter` instances are now static — previously this
    /// function allocated both per call, and the body calls it for
    /// every visible row on every render. With up to 100 visible rows under
    /// "Show top 100" plus context-menu re-evaluations, that was
    /// thousands of allocations per scroll.
    private static let prettyDateInFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
    private static let prettyDateOutFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        f.timeZone = .current
        return f
    }()

    private func prettyDate(_ ymd: String) -> String {
        guard let d = Self.prettyDateInFmt.date(from: ymd) else { return ymd }
        return Self.prettyDateOutFmt.string(from: d)
    }
}
