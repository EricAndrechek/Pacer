import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

/// Detail sheet for a single calendar day. Reachable from the History
/// tab's heatmap (click a cell). Shows cost / tokens summary, the
/// per-model donut breakdown for that day, and the projects active
/// that day.
struct DayDetailView: View {
    let date: String  // YYYY-MM-DD

    @Environment(\.pacerModalPush) private var push
    @Query private var globalAggregates: [DailyAggregate]
    @Query private var scopedAggregates: [AccountDailyAggregate]
    @State private var scope = UsageScope.shared

    /// Every account, or one — drilling into a day should show the same
    /// scope the chart you clicked was showing.
    private var aggregates: [DailyRow] {
        scope.isAll
            ? globalAggregates.map(\.dailyRow)
            : scopedAggregates.map(\.dailyRow)
    }
    private var projectAggregatesForDay: [any ProjectDailyReadable] {
        scope.isAll ? globalProjectsForDay : scopedProjectsForDay
    }
    private var sessionRows: [SessionRow] {
        scope.isAll
            ? globalSessionRows.map(\.sessionRow)
            : scopedSessionRows.map(\.sessionRow)
    }
    /// Per-project rollup for this day. `ProjectDailyAggregate` is keyed
    /// `(projectPath, date)` and already carries the per-bucket sums the
    /// Projects card needs — we used to materialize every TokenSample
    /// for the day and call `effectiveCostUSD` on each row, which on a
    /// busy day (~3000 samples) dominated the modal's body cost every
    /// scan tick. The rollup is maintained by `ProjectAggregateRecomputer`
    /// with the same cost mode the recomputers everywhere use, so the
    /// numbers stay consistent with Projects / ProjectDetail.
    @Query private var globalProjectsForDay: [ProjectDailyAggregate]
    @Query private var scopedProjectsForDay: [AccountProjectDailyAggregate]
    @Query private var globalSessionRows: [SessionInfo]
    @Query private var scopedSessionRows: [AccountSessionInfo]
    @Query(DayDetailView.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]

    @State private var cached = Cached()

    init(date: String, scopeAccountId: String? = nil) {
        self.date = date
        let acct = scopeAccountId ?? UsageScope.noAccountSentinel
        _globalAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == date }
        )
        _scopedAggregates = Query(
            filter: #Predicate<AccountDailyAggregate> {
                $0.date == date && $0.accountId == acct
            }
        )
        _globalProjectsForDay = Query(
            filter: #Predicate<ProjectDailyAggregate> { $0.date == date }
        )
        _scopedProjectsForDay = Query(
            filter: #Predicate<AccountProjectDailyAggregate> {
                $0.date == date && $0.accountId == acct
            }
        )
        // Sessions that touched this day: overlap on [dayStart, dayEnd].
        // A session spanning multiple days shows up on every day it was
        // active. Filter via lastSeenAt ≥ dayStart AND firstSeenAt < dayEnd.
        let dayStart = Self.startOfDay(for: date)
        let dayEnd = dayStart.addingTimeInterval(86400)
        _globalSessionRows = Query(
            filter: #Predicate<SessionInfo> {
                $0.lastSeenAt >= dayStart && $0.firstSeenAt < dayEnd
            },
            sort: \.lastSeenAt,
            order: .reverse
        )
        _scopedSessionRows = Query(
            filter: #Predicate<AccountSessionInfo> {
                $0.accountId == acct
                && $0.lastSeenAt >= dayStart && $0.firstSeenAt < dayEnd
            },
            sort: \AccountSessionInfo.lastSeenAt,
            order: .reverse
        )
    }

    /// Local-midnight Date for a YYYY-MM-DD key. Falls back to
    /// distantPast on parse failure so a malformed date key just
    /// surfaces an empty sessions list rather than crashing.
    private static func startOfDay(for ymd: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd) ?? .distantPast
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private struct Totals {
        var cost: Double = 0
        var tokens = TokenBreakdown.zero
    }

    private struct ProjectRow: Identifiable {
        let path: String
        let displayName: String
        let cost: Double
        /// From the same `ProjectUsageTotals` fold the Projects list and
        /// Project detail use, so the three agree (#215).
        let tokens: TokenBreakdown
        var id: String { path }
    }

    private struct Cached {
        var totals = Totals()
        /// The whole day's cost by priced part (#225), and each model's,
        /// largest model first.
        var breakdown = CostBreakdown.zero
        var modelBreakdowns: [ModelBreakdown] = []
        var projectRows: [ProjectRow] = []
        /// The Models and Projects cards' rows for the shared usage table,
        /// which sorts them itself.
        var modelTableRows: [PacerUsageRow<DayModelShare>] = []
        var projectTableRows: [PacerUsageRow<PacerUsageNoExtra>] = []
    }

    private struct ModelBreakdown: Identifiable {
        let model: String
        let breakdown: CostBreakdown
        var id: String { model }
    }

    private var totals: Totals { cached.totals }
    private var projectRows: [ProjectRow] { cached.projectRows }

    @MainActor
    private func refreshCache() {
        var t = Totals()
        for r in aggregates {
            t.cost += r.totalCostUSD
            t.tokens += r.tokens
        }

        // Per-project rollup read straight from `ProjectDailyAggregate` —
        // one row per (projectPath, date), with totals already summed
        // and cost already applied at the user's current cost mode by
        // `ProjectAggregateRecomputer`. No per-sample iteration, no
        // pricing lookups on the body path.
        let rows = CollectionUsageRollup.perPathTotals(from: projectAggregatesForDay).map { path, totals in
            ProjectRow(
                path: path,
                displayName: pacerShortPath(path),
                cost: totals.cost,
                tokens: totals.tokens
            )
        }.sorted { lhs, rhs in
            // Stable sort: by cost desc, with displayName as a
            // deterministic tiebreaker so $0 rows don't shuffle on
            // every scan tick.
            if lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        let sortedByCost = aggregates.sorted { $0.totalCostUSD > $1.totalCostUSD }
        let breakdown = CostBreakdown.sum(aggregates, \.costBreakdown)
        let modelBreakdowns = sortedByCost.map {
            ModelBreakdown(model: $0.model, breakdown: $0.costBreakdown)
        }

        // The two tables' rows, built once per refresh. The table sorts
        // them by the user's column, so a sort change re-sorts these rows
        // and does not refresh the cache.
        let dayCost = t.cost
        let modelTableRows = aggregates.map { agg in
            PacerUsageRow(
                id: agg.model,
                label: pacerModelDisplayName(agg.model),
                color: pacerModelColor(agg.model),
                tokens: agg.tokens,
                cost: agg.totalCostUSD,
                extra: DayModelShare(share: dayCost > 0 ? agg.totalCostUSD / dayCost : 0))
        }
        let projectTableRows = rows.map { row in
            PacerUsageRow(id: row.path, label: row.displayName, subtitle: row.path,
                          tokens: row.tokens, cost: row.cost)
        }
        cached = Cached(
            totals: t,
            breakdown: breakdown,
            modelBreakdowns: modelBreakdowns,
            projectRows: rows,
            modelTableRows: modelTableRows,
            projectTableRows: projectTableRows
        )
    }

    var body: some View {
        // Read here as well as inside `PacerModalContent`'s stored closure,
        // so a refresh redraws this view (#140; AGENTS.md, "SwiftUI state and
        // data flow"). The Sessions sort reaches its table only as bindings.
        let _ = cached
        let _ = (sessionsSortRaw, sessionsSortDescending)
        // The Models and Projects sorts are read inside the cards, which run
        // in that stored closure too; read here so a header click redraws.
        let _ = (modelsSortRaw, modelsSortDescending, projectsSortRaw, projectsSortDescending)
        PacerModalContent(
            title: prettyDate,
            subtitle: date,
            minWidth: 580, idealWidth: 660,
            minHeight: 480, idealHeight: 620
        ) {
            summaryCard
            if PacerCostBreakdownView.hasContent(cached.breakdown) { breakdownCard }
            if !aggregates.isEmpty { modelsCard }
            if !projectRows.isEmpty { projectsCard }
            if !sessionRows.isEmpty { sessionsCard }
        }
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
        // The scope is an input to the cache: without this, switching scope
        // with a day open left Summary, Models and Projects on the old
        // account while the live Sessions list moved to the new one (#141).
        .onChange(of: scope.accountId) { _, _ in refreshCache() }
    }

    /// Static formatters used by `prettyDate`. The previous version
    /// allocated both `DateFormatter` instances per call, and
    /// `prettyDate` is read from `body` so every state change in the
    /// modal (chart hover, sort change) re-allocated them.
    private static let prettyDateInputFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
    private static let prettyDateOutputFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeZone = .current
        return f
    }()

    /// `2026-04-30` → `Thursday, April 30, 2026`. Falls back to the raw
    /// key on parse failure.
    private var prettyDate: String {
        guard let d = Self.prettyDateInputFmt.date(from: date) else { return date }
        return Self.prettyDateOutputFmt.string(from: d)
    }

    private var summaryCard: some View {
        let t = totals
        return PacerCard("Summary", trailing: {
            if aggregates.isEmpty {
                Text("no data")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }) {
            VStack(alignment: .leading, spacing: 16) {
                // Cost, then every token (#215). The per-part token tiles that
                // sat here are in the Cost breakdown card's legend now, beside
                // their dollars; printing them twice breaks the page's rule.
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                        count: 4
                    ),
                    alignment: .leading,
                    spacing: 12
                ) {
                    MetricTile(
                        value: pacerCost(t.cost), label: "cost", size: .hero,
                        tooltip: pacerCostExact(t.cost)
                    )
                    MetricTile(
                        value: pacerTokens(t.tokens.all), label: "tokens",
                        tooltip: pacerTokensExact(t.tokens.all)
                    )
                }
            }
        }
    }

    /// Which of the five priced parts made up the day (#225), and the cache
    /// hit rate the Summary used to carry. The shared `PacerCostBreakdownView`
    /// draws it, so a day reads the same parts, colours and hit-rate
    /// definition as a project or the Models tab. A day with more than one
    /// model also gets one bar per model; their costs are in the Models card,
    /// so here a model's line is its mix and its own hit rate.
    private var breakdownCard: some View {
        PacerCard("Cost breakdown") {
            VStack(alignment: .leading, spacing: 14) {
                PacerCostBreakdownView(cached.breakdown)
                if cached.modelBreakdowns.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Eyebrow(text: "By model", color: .secondary)
                            Spacer()
                            Eyebrow(text: "Cache hits", color: .secondary)
                        }
                        ForEach(cached.modelBreakdowns) { m in
                            PacerCostBreakdownRow(
                                label: pacerModelDisplayName(m.model),
                                breakdown: m.breakdown
                            ) {
                                Text(m.breakdown.cacheHitRatio.map(pacerCacheHitText) ?? "–")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The Models and Projects tables' sorts: a `UsageColumn` raw value and
    /// a direction, under the keys the old per-card sorts used ("name",
    /// "tokens" and "cost" are column ids too, so a stored sort carries over).
    @AppStorage("pacer.dayDetail.modelsSort", store: PacerSettings.store)
    private var modelsSortRaw: String = UsageColumn.cost.rawValue
    @AppStorage("pacer.dayDetail.modelsSortDescending", store: PacerSettings.store)
    private var modelsSortDescending: Bool = true

    @AppStorage("pacer.dayDetail.projectsSort", store: PacerSettings.store)
    private var projectsSortRaw: String = UsageColumn.cost.rawValue
    @AppStorage("pacer.dayDetail.projectsSortDescending", store: PacerSettings.store)
    private var projectsSortDescending: Bool = true

    /// Tap handler on a day-detail project row: push the project's
    /// detail view onto the parent modal's NavigationStack so the
    /// native back button returns to this day modal. Skip the
    /// synthetic "(unknown)" path — there's no project to open.
    private func openProject(path: String, displayName: String) {
        guard path != ProjectDailyAggregate.unknownProjectPath else { return }
        // day detail has no time-range scope, so push with since: nil
        // → opens the project's all-time detail
        push(.project(path: path, displayName: displayName, since: nil))
    }

    /// Every model the day used, in the shared usage table, with each
    /// model's share of the day's cost. The donut that sat beside the list
    /// drew that same share; beside seven columns it left the table too
    /// narrow for a modal, so the share is a column now, and the Cost
    /// breakdown card above draws each model's mix.
    private var modelsCard: some View {
        let sort = PacerUsageSort(column: modelsSortRaw, descending: modelsSortDescending)
        return PacerCard("Models") {
            PacerUsageTable(
                rows: cached.modelTableRows,
                tableId: "dayDetail.models",
                labelTitle: "Model",
                sort: sort,
                onSort: { modelsSortRaw = $0.column; modelsSortDescending = $0.descending }
            ) {
                PacerUsageColumns.extra(DayModelShare.column, title: "Share",
                                        of: DayModelShare.self,
                                        minWidth: 40, idealWidth: 48) { row in
                    Text("\(Int((row.extra.share * 100).rounded()))%")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .help("Share of the day's cost")
                }
            }
        }
    }

    private var projectsCard: some View {
        let sort = PacerUsageSort(column: projectsSortRaw, descending: projectsSortDescending)
        return PacerCard("Projects", trailing: {
            Text("\(projectRows.count) project\(projectRows.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }) {
            PacerUsageTable(
                rows: cached.projectTableRows,
                tableId: "dayDetail.projects",
                labelTitle: "Project",
                sort: sort,
                onSort: { projectsSortRaw = $0.column; projectsSortDescending = $0.descending },
                onOpen: { row in openProject(path: row.id, displayName: row.label) },
                rowMenu: { row in
                    if row.id != ProjectDailyAggregate.unknownProjectPath {
                        Button("Open project") { openProject(path: row.id, displayName: row.label) }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: row.id)]
                            )
                        }
                        Divider()
                    }
                    Button("Copy path") { pacerCopyToPasteboard(row.id) }
                    // Copy the exact dollars-and-cents; the visible
                    // label is compact but the clipboard should be
                    // precise so a paste into a spreadsheet works.
                    Button("Copy cost") { pacerCopyToPasteboard(pacerCostExact(row.cost)) }
                })
        }
    }

    @AppStorage("pacer.dayDetail.sessionsSort", store: PacerSettings.store)
    private var sessionsSortRaw: String = SessionsTableSort.cost.rawValue
    @AppStorage("pacer.dayDetail.sessionsSortDescending", store: PacerSettings.store)
    private var sessionsSortDescending: Bool = true

    private var sessionsSort: SessionsTableSort {
        SessionsTableSort(rawValue: sessionsSortRaw) ?? .cost
    }
    private var sessionsSortBinding: Binding<SessionsTableSort> {
        Binding(get: { sessionsSort }, set: { sessionsSortRaw = $0.rawValue })
    }

    /// Sessions active on this day — same shared SessionsTable that
    /// the project modal uses, with the "Project" column enabled
    /// because a day spans many projects. All rows reachable via the
    /// table's inner scroll once the count exceeds the inline
    /// threshold; no more "+N more" dead-end.
    private var sessionsCard: some View {
        PacerCard("Sessions", trailing: {
            Text("\(sessionRows.count) on this day")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }) {
            SessionsTable(
                rows: sessionRows,
                showProjectColumn: true,
                sort: sessionsSortBinding,
                sortDescending: $sessionsSortDescending,
                onSessionTap: { session in
                    push(.session(
                        sessionId: session.sessionId,
                        projectDisplayName: pacerShortPath(session.projectPath)
                    ))
                }
            )
        }
    }
}

/// A model's share of the day's cost, the Day detail Models table's own
/// column.
struct DayModelShare: PacerUsageExtra {
    static let column = "share"
    let share: Double

    func sortKey(forColumn id: String) -> PacerUsageSortKey? {
        id == Self.column ? .number(share) : nil
    }
}
