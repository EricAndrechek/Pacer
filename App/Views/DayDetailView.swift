import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Detail sheet for a single calendar day. Reachable from the History
/// tab's heatmap (click a cell) and every chart that plots days.
///
/// Laid out like Project detail (round 5), card for card: the first card
/// (the shared `PacerSummaryCard`: what the day cost, its counts, its hours
/// as a strip, and the breakdown), By model, Models, the day's Projects, then
/// its Sessions. The shared cards are `DetailModalCards`; only the first
/// card's counts and hours are the day's own.
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
    private var hourlyRows: [HourlyRow] {
        scope.isAll
            ? globalHourly.map(\.hourlyRow)
            : scopedHourly.map(\.hourlyRow)
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
    /// The day's hours, for the first card's strip of the day: which hours
    /// had a turn and what each cost. At most 24 rows a model, by the indexed
    /// date.
    @Query private var globalHourly: [HourlyAggregate]
    @Query private var scopedHourly: [AccountHourlyAggregate]
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
        _globalHourly = Query(
            filter: #Predicate<HourlyAggregate> { $0.date == date }
        )
        _scopedHourly = Query(
            filter: #Predicate<AccountHourlyAggregate> {
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
        prettyDateInputFmt.date(from: ymd) ?? .distantPast
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private struct Cached {
        /// The whole day's cost by priced part (#225): the first card's big
        /// figure, its tokens, and its breakdown.
        var breakdown = CostBreakdown.zero
        /// The day's 24 hours for the first card's strip: which had a turn,
        /// each one's height its cost. With its span ("9 AM – 11 PM") and
        /// each hour's tooltip, built here rather than in `body`.
        var activity = PeriodActivity.hours(active: [], trend: [:])
        var span: String?
        var hourHelp: [String] = []
        /// By model's and Models' rows, which sort themselves.
        var modelRows: [DetailModalCards.ModelRow] = []
        /// The Projects table's rows, from the same `ProjectUsageTotals`
        /// fold the Projects list and Project detail use, so the three
        /// agree (#215).
        var projectRows: [PacerUsageRow<DetailPathExtra>] = []
    }

    @MainActor
    private func refreshCache() {
        let rows = aggregates
        // An hour counts when it had a turn: its samples, or its tokens for a
        // row written before the per-account rollup kept a sample count.
        var active: Set<Int> = []
        var costByHour: [Int: Double] = [:]
        for row in hourlyRows where row.sampleCount > 0 || row.tokens.all > 0 {
            active.insert(row.hour)
            costByHour[row.hour, default: 0] += row.totalCostUSD
        }
        let activity = PeriodActivity.hours(active: active, trend: costByHour)
        let year: Int = Calendar.current.component(.year, from: PacerClock.now)

        // Per-project rollup read straight from `ProjectDailyAggregate` —
        // one row per (projectPath, date), with totals already summed
        // and cost already applied at the user's current cost mode by
        // `ProjectAggregateRecomputer`. No per-sample iteration, no
        // pricing lookups on the body path.
        let projectRows = CollectionUsageRollup.perPathTotals(from: projectAggregatesForDay).map { path, totals in
            PacerUsageRow(
                id: path, label: pacerShortPath(path), subtitle: path,
                tokens: totals.tokens, costParts: totals.costParts, cost: totals.cost,
                extra: DetailPathExtra(sessions: totals.sessionCount))
        }

        cached = Cached(
            breakdown: CostBreakdown.sum(rows, \.costBreakdown),
            activity: activity,
            span: pacerActivitySpan(activity) { pacerHourLabel(Int($0) ?? 0) },
            hourHelp: pacerActivityCellHelp(activity, currentYear: year) { cell in
                Int(cell.first).flatMap { costByHour[$0] }.map(pacerCostExact)
            },
            modelRows: rows.map {
                DetailModalCards.modelRow(model: $0.model, tokens: $0.tokens, costParts: $0.cost,
                                          cost: $0.totalCostUSD)
            },
            projectRows: projectRows
        )
    }

    var body: some View {
        // Read here as well as inside `PacerModalContent`'s stored closure,
        // so a refresh redraws this view (#140; AGENTS.md, "SwiftUI state and
        // data flow").
        let cached = self.cached
        let sessions = sessionRows
        // The cached rows, or on the first frame (before `.onChange` has run)
        // the same rows built once here, so the card opens full.
        let sessionTable = sessionTableRows.isEmpty && !sessions.isEmpty
            ? PacerSessionsTable.rows(sessions) : sessionTableRows
        // The sorts are read inside the cards, which run in that stored
        // closure too; read here so a header click redraws at once.
        let modelShareSort = DetailModalCards.sort(stored: modelShareSortRaw, descending: modelShareSortDescending)
        let modelsSort = DetailModalCards.sort(stored: modelsSortRaw, descending: modelsSortDescending)
        let projectsSort = DetailModalCards.sort(stored: projectsSortRaw, descending: projectsSortDescending,
                                                 own: [DetailPathExtra.sessions])
        let sessionsSort = PacerSessionsTable.sort(stored: sessionsSortRaw, descending: sessionsSortDescending)
        let summary = summaryModel(cached, sessions: sessions.count)
        let empty = aggregates.isEmpty
        PacerModalContent(
            title: prettyDate,
            subtitle: date,
            minWidth: 580, idealWidth: 660,
            minHeight: 480, idealHeight: 620
        ) {
            PacerSummaryCard(model: summary) {
                if empty {
                    Text("no data")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            if !cached.modelRows.isEmpty {
                DetailModalCards.modelShareCard(
                    rows: cached.modelRows, sort: modelShareSort, subject: prettyDate,
                    onSort: { modelShareSortRaw = $0.column; modelShareSortDescending = $0.descending })
                DetailModalCards.modelsTableCard(
                    rows: cached.modelRows, tableId: "dayDetail.models", sort: modelsSort,
                    onSort: { modelsSortRaw = $0.column; modelsSortDescending = $0.descending })
            }
            if !cached.projectRows.isEmpty { projectsCard(sort: projectsSort) }
            if !sessions.isEmpty {
                DetailModalCards.sessionsCard(
                    rows: sessionTable, tableId: "dayDetail.sessions", showProject: true,
                    sort: sessionsSort,
                    onSort: { sessionsSortRaw = $0.column; sessionsSortDescending = $0.descending },
                    onOpen: { row in
                        push(.session(sessionId: row.id, projectDisplayName: row.extra.projectName))
                    })
            }
        }
        .onAppear { refreshCache() }
        // The session rows are live `@Query` results (scans, a scope switch
        // re-reading the other table); the table's rows follow them.
        .onChange(of: sessions, initial: true) { _, new in
            sessionTableRows = PacerSessionsTable.rows(new)
        }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
        // The scope is an input to the cache: without this, switching scope
        // with a day open left the first card, Models and Projects on the
        // old account while the live Sessions list moved to the new one
        // (#141).
        .onChange(of: scope.accountId) { _, _ in refreshCache() }
    }

    /// The first card: the day's cost, three counts, and its hours as a
    /// strip, each hour's height its cost (the modal has no other picture of
    /// the day's hours). Sessions come from the live session rows, the rest
    /// from the cache. Each count is printed here only; the cards below carry
    /// none in their headers.
    private func summaryModel(_ cached: Cached, sessions: Int) -> PacerSummaryModel {
        PacerSummaryModel(
            breakdown: cached.breakdown,
            stats: [
                PacerSummaryFact("sessions", "\(sessions)"),
                PacerSummaryFact("models", "\(cached.modelRows.count)"),
                PacerSummaryFact("projects", "\(cached.projectRows.count)"),
            ],
            activity: cached.activity,
            span: cached.span,
            trendCaption: "cost an hour",
            axis: pacerHourAxis(),
            cellHelp: cached.hourHelp)
    }

    /// Static formatters used by `prettyDate` and `startOfDay`. The
    /// previous version allocated both `DateFormatter` instances per call,
    /// and `prettyDate` is read from `body` so every state change in the
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

    /// By model's sort (which also turns its ring), and the Models and
    /// Projects tables' sorts: a `UsageColumn` raw value (or the Projects
    /// table's Sessions) and a direction. Models and Projects keep the keys
    /// their cards always had; a stored sort on a column that has gone
    /// (Models' old "share") falls back to cost (`DetailModalCards.sort`).
    @AppStorage("pacer.dayDetail.modelShareSort", store: PacerSettings.store)
    private var modelShareSortRaw: String = UsageColumn.cost.rawValue
    @AppStorage("pacer.dayDetail.modelShareSortDescending", store: PacerSettings.store)
    private var modelShareSortDescending: Bool = true

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

    /// The projects active on this day: the shared paths table, a row
    /// opening that project's detail.
    private func projectsCard(sort: PacerUsageSort) -> some View {
        DetailModalCards.pathsTableCard(
            "Projects",
            labelTitle: "Project",
            rows: cached.projectRows,
            tableId: "dayDetail.projects",
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

    @AppStorage("pacer.dayDetail.sessionsSort", store: PacerSettings.store)
    private var sessionsSortRaw: String = UsageColumn.cost.rawValue
    @AppStorage("pacer.dayDetail.sessionsSortDescending", store: PacerSettings.store)
    private var sessionsSortDescending: Bool = true

    /// The Sessions table's rows, rebuilt when the day's sessions change
    /// (a scan, a scope switch) rather than on every body pass.
    @State private var sessionTableRows: [PacerSessionsTable.Row] = []
}
