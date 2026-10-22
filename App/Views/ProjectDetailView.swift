import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Drill-down for a single project. Presented as a sheet from
/// `ProjectsView` (and from a Day detail's projects).
///
/// Laid out like Day detail (round 5), card for card: the first card (the
/// shared `PacerSummaryCard`: what the project cost over the range, its
/// counts and git status, its days as a strip, and the breakdown), the daily
/// chart, By model, Models, Subprojects, Sessions,
/// then the project's own Budget. The shared cards are `DetailModalCards`.
///
/// Reads `ProjectDailyAggregate` and `SessionInfo` — both precomputed by the
/// in-process scan's recomputers. The one exception is the raw-sample load
/// behind Subprojects and the Models table (`loadDetail`): modal-only, off
/// the main actor, and bounded by this project's path, the range and the
/// account.
struct ProjectDetailView: View {
    let projectPath: String
    let displayName: String
    let since: Date?

    @Environment(\.pacerModalPush) private var push
    @Environment(\.modelContext) private var modelContext
    @Query private var globalAggregates: [ProjectDailyAggregate]
    @Query private var scopedAggregates: [AccountProjectDailyAggregate]
    @State private var scope = UsageScope.shared

    /// Every account, or one — a project's detail should show the same scope
    /// the Projects list you came from was showing.
    private var aggregates: [any ProjectDailyReadable] {
        scope.isAll ? globalAggregates : scopedAggregates
    }
    private var sessionRows: [SessionRow] {
        scope.isAll
            ? globalSessionRows.map(\.sessionRow)
            : scopedSessionRows.map(\.sessionRow)
    }
    @Query private var globalSessionRows: [SessionInfo]
    @Query private var scopedSessionRows: [AccountSessionInfo]
    /// Probe row for this project, if any. Drives the git chip in the first
    /// card's title row. Scoped via `init` so SwiftData only fetches the one
    /// row we care about (path-keyed unique).
    @Query private var probesForThisProject: [ProjectPathProbe]
    /// Every project path Pacer has seen, bar `(unknown)` — drives the
    /// "Merge this into…" submenu and the bulk-merge sheet. Fetched on
    /// appear and when project attribution changes, not as a `@Query`: that
    /// re-read every project-day row on each store save while the modal
    /// was open, and the menu rebuilt its list from it on every render.
    @State private var knownProjectPathsForBulkMerge: [String] = []

    /// Pending source→canonical pair waiting on the user's confirm
    /// click after picking a target from the "Merge this into…"
    /// submenu. Lighter than opening a full alias editor — both
    /// sides are already known.
    @State private var pendingMergeTarget: String?
    /// Drives the bulk-merge sheet ("Merge other projects into
    /// this…"). Preseeds this project as the canonical.
    @State private var bulkMergeDraft: BulkMergeDraft?
    @State private var mergeError: String?

    /// What the rollup-backed cards draw, derived in one pass over the
    /// project's rows (`refreshDerived`) rather than on every body pass: a
    /// chart hover, a sort click or any other state change re-runs the body.
    @State private var cachedDerived = Derived()
    /// What the raw-sample load gives (`refreshDetail`): the Subprojects
    /// rows, and the Models rows with every token part, which the rollup does
    /// not keep per model. Empty until the first load lands.
    @State private var cachedDetail = Detail()
    /// One raw-sample load at a time; a trigger that lands while one is
    /// running sets `detailRerun` and gets one more load afterwards.
    /// Cancelling is not an option: the load is a detached task, which is not
    /// cancelled with its parent, so "cancel and restart" left every
    /// superseded fetch running — overlapping raw-sample reads on a busy
    /// project, all competing with the scan for the store.
    @State private var detailLoading = false
    @State private var detailRerun = false
    @State private var detailClosed = false
    /// Cost mode. Reactive @AppStorage so the raw-sample cards re-price
    /// immediately when the user toggles modes in Settings (same pattern
    /// NowStrip uses).
    @AppStorage(PacerSettings.Key.costMode, store: PacerSettings.store)
    private var costModeRaw: String = CostMode.auto.rawValue

    /// Budget row for this project — at most one, by `@Attribute(.unique)`
    /// on `ProjectBudget.projectPath`. fetchLimit isn't necessary
    /// because the predicate is path-keyed unique.
    @Query private var budgetRows: [ProjectBudget]

    /// The account the modal is scoped to, when it is — the raw-sample load
    /// filters by it like every other card here.
    private let scopeAccountId: String?

    init(
        projectPath: String, displayName: String, since: Date?,
        scopeAccountId: String? = nil
    ) {
        self.projectPath = projectPath
        self.displayName = displayName
        self.since = since
        self.scopeAccountId = scopeAccountId
        let path = projectPath
        let acct = scopeAccountId ?? UsageScope.noAccountSentinel
        _budgetRows = Query(
            filter: #Predicate<ProjectBudget> { $0.projectPath == path }
        )
        if let cutoffDate = since {
            let cutoffString = TokenSample.formatDate(cutoffDate)
            _globalAggregates = Query(
                filter: #Predicate<ProjectDailyAggregate> {
                    $0.projectPath == path && $0.date >= cutoffString
                },
                sort: \.date
            )
            _scopedAggregates = Query(
                filter: #Predicate<AccountProjectDailyAggregate> {
                    $0.accountId == acct && $0.projectPath == path
                    && $0.date >= cutoffString
                },
                sort: \AccountProjectDailyAggregate.date
            )
            _globalSessionRows = Query(
                filter: #Predicate<SessionInfo> {
                    $0.projectPath == path && $0.lastSeenAt >= cutoffDate
                },
                sort: \.lastSeenAt,
                order: .reverse
            )
            _scopedSessionRows = Query(
                filter: #Predicate<AccountSessionInfo> {
                    $0.accountId == acct && $0.projectPath == path
                    && $0.lastSeenAt >= cutoffDate
                },
                sort: \AccountSessionInfo.lastSeenAt,
                order: .reverse
            )
        } else {
            _globalAggregates = Query(
                filter: #Predicate<ProjectDailyAggregate> { $0.projectPath == path },
                sort: \.date
            )
            _scopedAggregates = Query(
                filter: #Predicate<AccountProjectDailyAggregate> {
                    $0.accountId == acct && $0.projectPath == path
                },
                sort: \AccountProjectDailyAggregate.date
            )
            _globalSessionRows = Query(
                filter: #Predicate<SessionInfo> { $0.projectPath == path },
                sort: \.lastSeenAt,
                order: .reverse
            )
            _scopedSessionRows = Query(
                filter: #Predicate<AccountSessionInfo> {
                    $0.accountId == acct && $0.projectPath == path
                },
                sort: \AccountSessionInfo.lastSeenAt,
                order: .reverse
            )
        }
        // Probe row scoped to this project. Predicate filter keeps
        // SwiftData from materializing the whole probe table on
        // every save — we just need the one row.
        _probesForThisProject = Query(
            filter: #Predicate<ProjectPathProbe> { $0.path == path }
        )
    }

    /// The rollup-backed cards' values.
    private struct Derived {
        /// The project's cost by priced part over the range (#225): the
        /// first card's big figure, its tokens and its breakdown.
        var breakdown = CostBreakdown.zero
        /// Days with a row, and the first and last of them (`yyyy-MM-dd`).
        var activeDays = 0
        var firstDay: String?
        var lastDay: String?
        /// The daily chart's bars, each with its breakdown and top models
        /// precomputed for the hover card, so a hover decodes nothing.
        var dailySeries: [PacerChartBucket] = []
        /// Each model's five token parts and cost by part over the range,
        /// summed from the rollup's per-model split (`modelBreakdowns`): By
        /// model and the Models table, drawn with the rest of the modal.
        var modelRows: [DetailModalCards.ModelRow] = []
    }

    /// The first card's strip: the range's days, each one's height the
    /// sessions active that day, with its span and tooltips. Rebuilt when the
    /// rows (`refreshDerived`) or the sessions change, never in `body`.
    private struct ActivitySummary {
        var activity = PeriodActivity.empty
        var span: String?
        var axis: [PacerActivityStrip.AxisLabel] = []
        var cellHelp: [String] = []
    }
    @State private var cachedActivity = ActivitySummary()
    /// Sessions active on each day, from the live session rows: the strip's
    /// heights, counted the way Day detail counts a day's sessions.
    @State private var cachedSessionsByDay: [String: Int] = [:]

    /// The raw-sample load's values, as rows: only Subprojects needs the
    /// samples, for the cwd each ran in.
    private struct Detail {
        var subprojects: [PacerUsageRow<DetailPathExtra>] = []
    }

    /// The models By model and the Models table draw.
    private var modelRows: [DetailModalCards.ModelRow] { cachedDerived.modelRows }

    /// Single derivation pass over `aggregates`: the breakdown, the facts,
    /// the daily series and each model's totals.
    private func refreshDerived() {
        let rows = aggregates
        var d = Derived()
        var byModel: [String: CostBreakdown] = [:]
        var days = PacerChartBucketBuilder()
        for r in rows {
            d.breakdown += r.costBreakdown
            // Decoded once per row; its models sum to the row, so the day's
            // bar is the sum of its models' parts.
            for (model, b) in r.modelBreakdowns {
                days.add(r.date, b, model: model)
                byModel[model, default: .zero] += b
            }
        }
        // The builder orders by date rather than leaning on the
        // `@Query(sort:)` staying put — the band-date chart that plots this
        // needs a chronological x-domain (same invariant as the Models trend).
        d.dailySeries = days.buckets()
        d.activeDays = d.dailySeries.count
        d.firstDay = d.dailySeries.first?.id
        d.lastDay = d.dailySeries.last?.id
        d.modelRows = byModel.map { model, b in
            DetailModalCards.modelRow(model: model, tokens: b.tokens, costParts: b.cost, cost: b.total)
        }
        cachedDerived = d
        refreshActivity()
    }

    /// The strip from the cached days and sessions. The period runs from the
    /// range's first day (or, over all time, the project's first active day)
    /// to today; the modal is closed at midnight (`ContentView`'s
    /// `.id(dayKey)`), so today cannot turn under an open one.
    private func refreshActivity() {
        let d = cachedDerived
        let today: String = PacerToday.shared.key
        guard let start = since.map(TokenSample.formatDate) ?? d.firstDay else {
            cachedActivity = ActivitySummary()
            return
        }
        let sessions = cachedSessionsByDay
        let end: String = max(today, d.lastDay ?? today)
        let activity = PeriodActivity.days(
            active: Set(d.dailySeries.map(\.id)), trend: sessions.mapValues(Double.init),
            from: start, through: end)
        let year: Int = Calendar.current.component(.year, from: PacerClock.now)
        cachedActivity = ActivitySummary(
            activity: activity,
            span: pacerActivitySpan(activity) { pacerFactDay($0, currentYear: year) },
            axis: pacerDayAxis(activity, today: today, currentYear: year),
            cellHelp: pacerActivityCellHelp(activity, currentYear: year) { cell in
                sessions[cell.first].map { "\($0) session\($0 == 1 ? "" : "s")" }
            })
    }

    /// Sessions active on each day of the range, from the session rows.
    private func refreshSessionsByDay(_ rows: [SessionRow]) {
        let spans: [(first: Date, last: Date)] = rows.map { ($0.firstSeenAt, $0.lastSeenAt) }
        cachedSessionsByDay = RangeActivityCounts.sessionsByDay(
            spans, from: RangeActivityCounts.dayStart(since))
        refreshActivity()
    }

    /// Changes whenever a row `refreshDerived` reads changes: a new day
    /// (count), a new turn in today's row (tokens, cost), or a re-priced or
    /// re-attributed row. The derived cards used to refresh on `count` alone,
    /// so the header, daily chart and model donut stayed on the modal's
    /// opening numbers for the rest of the day while Subprojects, refreshed
    /// every scan, moved on beside them (#145).
    ///
    /// Keyed on the rows rather than the scan notification because the rows
    /// are what `refreshDerived` reads: this fires when they change,
    /// whenever the query picks the change up.
    private struct AggregatesFingerprint: Equatable {
        var count = 0
        var tokens: Int64 = 0
        var cost = 0.0

        /// The same rows and tokens at a new cost: a re-price, which the
        /// raw-sample load must follow too (no sample changed, so no scan
        /// notification says so).
        func isRepricing(of old: AggregatesFingerprint) -> Bool {
            count == old.count && tokens == old.tokens && cost != old.cost
        }
    }

    private var aggregatesFingerprint: AggregatesFingerprint {
        var f = AggregatesFingerprint()
        for r in aggregates {
            f.count += 1
            f.tokens += r.tokens.all
            f.cost += r.totalCostUSD
        }
        return f
    }

    /// Loads this project's raw samples for the two cards the rollups cannot
    /// fill: Subprojects (by each sample's original cwd) and the Models table
    /// (every token part per model; the rollup keeps only cost and uncached
    /// tokens per model). Cost goes through `CostCalculator.sampleCost`, the
    /// function the rollups are written with, so a model's cost here is the
    /// cost By model and the first card add up.
    ///
    /// Why a manual fetch instead of `@Query`: a `@Query` for samples
    /// was the cause of a freeze-the-whole-modal bug. SwiftData's
    /// @Query for TokenSample re-fetched and decoded the full result
    /// set on every body access (`samples.getter` was 67% of
    /// main-thread time in a `sample` trace), and the modal's body
    /// re-evaluates on every scan-cycle save (~2s) via the other
    /// @Query bindings. A manual fetch driven by `.onAppear`, the scope,
    /// the cost-mode setting, a re-price and the `pacerScanCycleDidComplete`
    /// notification gives the same live-update behavior with zero
    /// per-render cost.
    ///
    /// Off the main actor, in its own `ModelContext`. This is the one read
    /// in the app that materializes raw samples, and a busy project over
    /// 90 days is tens of thousands of them: done on the main context it
    /// was the largest main-thread cost in a `sample` of the live app, run
    /// once as the modal opened (the click that "does nothing" for a
    /// second, then lands with every queued click behind it) and again on
    /// every scan cycle while the modal stayed open.
    private func refreshDetail() {
        guard !detailClosed else { return }
        guard !detailLoading else {
            detailRerun = true
            return
        }
        detailLoading = true
        let container = modelContext.container
        let path = projectPath
        let since = since
        // The live scope, not the `scopeAccountId` this copy of the view was
        // built with: a re-run queued behind an in-flight load re-enters
        // through the copy the load's `Task` captured, so a switch made
        // during the load re-ran it for the old account.
        let account = scope.accountId
        let mode = CostMode(rawValue: costModeRaw) ?? .auto
        Task {
            let load = await Task.detached(priority: .userInitiated) {
                Self.loadDetail(container: container, projectPath: path,
                                since: since, accountId: account, mode: mode)
            }.value
            detailLoading = false
            guard !detailClosed else { return }
            cachedDetail = Self.rows(load)
            if detailRerun {
                detailRerun = false
                refreshDetail()
            }
        }
    }

    /// What `loadDetail` sums, as plain values: it runs off the main actor.
    struct DetailLoad: Sendable {
        struct Path: Sendable {
            /// Where in the repo the work ran, worktrees folded in
            /// (`ProjectPathCanonicalizer.subproject`), e.g. `packages/api`.
            /// Empty for the repo root. The bucket and the row's id.
            let subpath: String
            /// Worktrees (other checkouts) that contributed to this subpath.
            let worktrees: Int
            let tokens: TokenBreakdown
            let costParts: CostComponents
            let sessions: Int
        }

        var paths: [Path] = []
    }

    private nonisolated static func loadDetail(
        container: ModelContainer, projectPath: String, since: Date?,
        accountId: String?, mode: CostMode
    ) -> DetailLoad {
        struct Acc {
            var tokens = TokenBreakdown.zero
            var cost = CostComponents.zero
            var sessions: Set<String> = []
            var worktrees: Set<String> = []
        }
        let context = ModelContext(container)
        let path = projectPath
        var sampleDesc: FetchDescriptor<TokenSample>
        // No cutoff means every date; `""` sorts before any "yyyy-MM-dd".
        let cutoffString = since.map(TokenSample.formatDate) ?? ""
        if let acct = accountId {
            sampleDesc = FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> {
                    $0.projectPath == path && $0.date >= cutoffString
                        && $0.accountId == acct
                }
            )
        } else {
            sampleDesc = FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> {
                    $0.projectPath == path && $0.date >= cutoffString
                }
            )
        }
        sampleDesc.propertiesToFetch = [
            \.projectPath,
            \.originalProjectPath,
            \.model,
            \.inputTokens,
            \.outputTokens,
            \.cacheReadTokens,
            \.cacheCreation5mTokens,
            \.cacheCreation1hTokens,
            \.sourceCostUSD,
            \.sessionId,
            // Priced at the rate in effect when each turn was made, for its
            // speed and residency, as the rollups price it.
            \.sampledAt,
            \.speed,
            \.inferenceGeo,
        ]
        let samples = (try? context.fetch(sampleDesc)) ?? []
        // What `TokenSample.effectiveCostUSD(mode:)` computes, which is
        // main-actor only; the snapshot it reads is not, so read it once.
        let pricing = SampleCostCache.current()
        var byPath: [String: Acc] = [:]
        for s in samples {
            let tokens = s.breakdown
            let cost = CostCalculator.sampleCost(s, mode: mode, snapshot: pricing).components
            // Bucket by where in the repo the work ran, with worktrees folded
            // into the subfolder they are a checkout of: one row per real
            // subproject, not one per worktree. A nil originalProjectPath
            // (a row from before the field existed that missed the
            // backfill) counts as the root rather than being dropped.
            let place = ProjectPathCanonicalizer.subproject(
                of: s.originalProjectPath ?? projectPath, in: projectPath)
            var a = byPath[place.subpath] ?? Acc()
            a.tokens += tokens
            a.cost += cost
            if let sid = s.sessionId, !sid.isEmpty { a.sessions.insert(sid) }
            if let w = place.worktree { a.worktrees.insert(w) }
            byPath[place.subpath] = a
        }
        var load = DetailLoad()
        load.paths = byPath.map { key, a in
            DetailLoad.Path(
                subpath: key, worktrees: a.worktrees.count,
                tokens: a.tokens, costParts: a.cost, sessions: a.sessions.count)
        }
        return load
    }

    /// The load as table rows; the tables sort them themselves.
    private static func rows(_ load: DetailLoad) -> Detail {
        Detail(
            subprojects: load.paths.map { p in
                // An empty subpath is work at the repo root; label it so the
                // row reads as intentional, not as a missing field.
                PacerUsageRow(
                    id: p.subpath,
                    label: p.subpath.isEmpty ? "(root)" : p.subpath,
                    subtitle: p.worktrees == 0 ? nil
                        : "+\(p.worktrees) worktree\(p.worktrees == 1 ? "" : "s")",
                    tokens: p.tokens, costParts: p.costParts,
                    extra: DetailPathExtra(sessions: p.sessions))
            })
    }

    var body: some View {
        // Every cache the cards draw from, read here in this view's own body.
        // The cards read them inside `PacerModalContent`'s stored content
        // closure, and a read there may not make this view depend on them,
        // which is the shape of the modal bug #150 fixed. The raw-sample
        // cards most of all: they fill in asynchronously, after the modal is
        // on screen, and the rest change while it's open (#145). (#140)
        let derived = cachedDerived
        let detail = cachedDetail
        let models = modelRows
        // Presentation state, read here so setting it redraws this view and
        // what it presents opens at once. Passed only as a binding, nothing
        // read it: the collections sheet opened only after an unrelated
        // redraw, seconds later (#140; AGENTS.md, "SwiftUI state and data flow").
        let _ = (bulkMergeDraft?.id, mergeError)
        // The sorts are read inside the cards, in that stored closure; read
        // here so clicking a header re-sorts at once.
        let modelShareSort = DetailModalCards.sort(stored: modelShareSortRaw, descending: modelShareSortDescending)
        let modelsSort = DetailModalCards.sort(stored: modelsSortRaw, descending: modelsSortDescending)
        let subprojectsSort = DetailModalCards.sort(stored: subprojectsSortRaw, descending: subprojectsSortDescending,
                                                    own: [DetailPathExtra.sessions])
        let sessionsSort = PacerSessionsTable.sort(stored: sessionsSortRaw, descending: sessionsSortDescending)
        let sessions = sessionRows
        // The cached rows, or on the first frame (before `.onChange` has run)
        // the same rows built once here, so the card opens full.
        let sessionTable = sessionTableRows.isEmpty && !sessions.isEmpty
            ? PacerSessionsTable.rows(sessions) : sessionTableRows
        let summary = summaryModel(derived, cachedActivity, models: models.count, sessions: sessions.count)
        let status = detailStatus
        PacerModalContent(
            title: displayName,
            subtitle: projectPath,
            minWidth: 640, idealWidth: 760,
            minHeight: 540, idealHeight: 720,
            trailing: {
                // Reveal in Finder + Merge — both hidden for the
                // synthetic "(unknown)" path Pacer assigns to
                // samples whose JSONL line lacks `cwd`.
                if projectPath != ProjectDailyAggregate.unknownProjectPath {
                    mergeMenuButton
                    PacerModalIconButton(
                        systemName: "folder",
                        help: "Reveal in Finder",
                        accessibilityLabel: "Reveal in Finder"
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: projectPath)]
                        )
                    }
                }
            }
        ) {
            // The git chip in the first card's title row, where round 4 gave
            // it a row of its own above the card.
            PacerSummaryCard(model: summary) {
                ProjectStatusBadge(state: status)
            }
            if !derived.dailySeries.isEmpty { dailyChartCard(derived.dailySeries) }
            if !models.isEmpty {
                DetailModalCards.modelShareCard(
                    rows: models, sort: modelShareSort, subject: displayName,
                    onSort: { modelShareSortRaw = $0.column; modelShareSortDescending = $0.descending })
            }
            // From the rollup's per-model split, so it draws with the rest.
            if !models.isEmpty {
                DetailModalCards.modelsTableCard(
                    rows: models, tableId: "projectDetail.models", sort: modelsSort,
                    onSort: { modelsSortRaw = $0.column; modelsSortDescending = $0.descending })
            }
            // Hidden when there's only one bucket (no drill-down value).
            if detail.subprojects.count > 1 { subprojectsCard(detail.subprojects, sort: subprojectsSort) }
            if !sessions.isEmpty {
                DetailModalCards.sessionsCard(
                    rows: sessionTable, tableId: "projectDetail.sessions", showProject: false,
                    sort: sessionsSort,
                    onSort: { sessionsSortRaw = $0.column; sessionsSortDescending = $0.descending },
                    onOpen: { row in
                        push(.session(sessionId: row.id, projectDisplayName: displayName))
                    })
            }
            // The project's own settings, after everything the two modals
            // share, so the shared cards keep one order.
            budgetCard
        }
        .onAppear {
            refreshDerived()
            refreshDetail()
            refreshKnownProjectPaths()
        }
        // The session rows are live `@Query` results (scans, a scope switch
        // re-reading the other table); the table's rows follow them.
        .onChange(of: sessions, initial: true) { _, new in
            sessionTableRows = PacerSessionsTable.rows(new)
            refreshSessionsByDay(new)
        }
        // The first card, the daily chart and By model follow the rows they
        // are built from. See `aggregatesFingerprint`. A re-price changes no
        // sample, so the raw-sample cards hear about it here too.
        .onChange(of: aggregatesFingerprint) { old, new in
            refreshDerived()
            if new.isRepricing(of: old) { refreshDetail() }
        }
        // The scope picks which table `aggregates` reads (so the fingerprint
        // follows it) and filters the raw-sample load, which needs telling.
        .onChange(of: scope.accountId) { _, _ in refreshDetail() }
        // Live updates within an existing day: the scan coordinator
        // posts `pacerScanCycleDidComplete` whenever a cycle actually
        // wrote new data. Filter to cycles that touched samples or
        // re-attributed projects — rate-limit-only cycles don't
        // change the raw-sample cards. They need this explicit refresh
        // because their source (raw TokenSample) is not a @Query (see
        // refreshDetail); the rollup-backed cards follow
        // `aggregatesFingerprint`.
        .onReceive(NotificationCenter.default.publisher(
            for: .pacerScanCycleDidComplete
        )) { note in
            guard let summary = note.object as? ScanCycleSummary else { return }
            if summary.samplesChanged || summary.projectAttributionChanged {
                refreshDetail()
            }
            if summary.projectAttributionChanged { refreshKnownProjectPaths() }
        }
        // Cost-mode toggle in Settings must re-price the raw-sample cards —
        // `CostCalculator.sampleCost(mode:)` flips between stored /
        // calculated / auto fallbacks.
        .onChange(of: costModeRaw) { _, _ in refreshDetail() }
        .onDisappear { detailClosed = true }
        .sheet(item: $bulkMergeDraft) { draft in
            BulkMergeSheet(
                knownPaths: knownProjectPathsForBulkMerge,
                initialCanonical: draft.canonical.isEmpty ? nil : draft.canonical,
                initialSources: draft.sources
            )
        }
        // Quick-merge confirmation — single source, single canonical,
        // no editor sheet. Same shape as the Projects-view context-
        // menu path.
        .confirmationDialog(
            mergeConfirmationTitle,
            isPresented: Binding(get: { pendingMergeTarget != nil }, set: { if !$0 { pendingMergeTarget = nil } }),
            titleVisibility: .visible,
            presenting: pendingMergeTarget
        ) { target in
            Button("Merge") { quickMerge(into: target) }
            Button("Cancel", role: .cancel) { pendingMergeTarget = nil }
        } message: { target in
            Text(Self.mergeMessage(from: projectPath, into: target))
        }
        .alert(
            "Could not merge",
            isPresented: Binding(get: { mergeError != nil }, set: { if !$0 { mergeError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mergeError ?? "")
        }
    }

    /// The quick-merge dialog's message, built outside `body`'s modifier
    /// chain: inline, its interpolation pushed that one long expression past
    /// the type checker's time limit.
    private static func mergeMessage(from source: String, into target: String) -> String {
        let from: String = pacerShortPath(source)
        let to: String = pacerShortPath(target)
        return "Existing samples for \(from) will be re-attributed to \(to) on the next scan cycle. You can undo from Settings → Project Aliases."
    }

    // MARK: - Project status

    /// Badge state for the modal header — derived from the single
    /// probe row scoped to this project + a fileExists check. Cheap
    /// (one syscall) and runs once per body render since both
    /// inputs are reactive.
    private var detailStatus: ProjectStatusBadge.State {
        let exists = FileManager.default.fileExists(atPath: projectPath)
        if !exists { return .missing }
        guard let probe = probesForThisProject.first else { return .unknown }
        return probe.gitRoot != nil ? .git : .noGit
    }

    // MARK: - Merge actions

    /// Distinct paths the bulk-merge sheet can choose canonicals
    /// from — every project Pacer has seen, excluding `(unknown)`
    /// (no folder behind it). Only `projectPath` is fetched; without
    /// `propertiesToFetch` SwiftData would materialize every JSON-blob
    /// column on every row.
    private func refreshKnownProjectPaths() {
        var desc = FetchDescriptor<ProjectDailyAggregate>()
        desc.propertiesToFetch = [\ProjectDailyAggregate.projectPath]
        var set: Set<String> = []
        for agg in (try? modelContext.fetch(desc)) ?? [] {
            if agg.projectPath != ProjectDailyAggregate.unknownProjectPath {
                set.insert(agg.projectPath)
            }
        }
        knownProjectPathsForBulkMerge = set.sorted()
    }

    /// Other-project picker for the "Merge this into…" submenu.
    /// Excludes the current project so the menu can't suggest a
    /// self-alias.
    private var otherProjectPaths: [String] {
        knownProjectPathsForBulkMerge.filter { $0 != projectPath }
    }

    /// Title for the confirm dialog. SwiftUI re-reads this when
    /// `pendingMergeTarget` changes; the closure must stay a pure
    /// derivation of @State.
    private var mergeConfirmationTitle: String {
        guard let target = pendingMergeTarget else { return "" }
        return "Merge \(pacerShortPath(projectPath)) into \(pacerShortPath(target))?"
    }

    /// Menu-style trailing button that opens the "Merge this into…"
    /// submenu and the bulk-merge entry point. Custom label
    /// matches the visual idiom of `PacerModalIconButton` so the
    /// chrome reads consistently.
    private var mergeMenuButton: some View {
        Menu {
            if !otherProjectPaths.isEmpty {
                Menu("Merge this project into…") {
                    ForEach(otherProjectPaths, id: \.self) { other in
                        Button(pacerShortPath(other)) {
                            pendingMergeTarget = other
                        }
                    }
                }
            }
            Button("Merge other projects into this…") {
                bulkMergeDraft = BulkMergeDraft(canonical: projectPath, sources: [])
            }
            .disabled(otherProjectPaths.isEmpty)
        } label: {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .help("Merge this project with another, or fold others into this one.")
        .accessibilityLabel("Merge")
    }

    private func quickMerge(into canonical: String) {
        let source = projectPath
        let manager = ProjectPathAliasManager(context: modelContext)
        do {
            try manager.upsert(sourcePath: source, canonicalPath: canonical)
            pendingMergeTarget = nil
            mergeError = nil
            NotificationCenter.default.post(name: .pacerRequestImmediateScan, object: nil)
        } catch let error as ProjectPathAliasManager.AliasError {
            pendingMergeTarget = nil
            switch error {
            case .selfAlias:
                mergeError = "Source and canonical paths must be different."
            case .emptyPath:
                mergeError = "Both paths are required."
            case .wouldCreateCycle:
                mergeError = "That mapping would create a loop with an existing alias."
            }
        } catch {
            pendingMergeTarget = nil
            mergeError = error.localizedDescription
        }
    }

    // MARK: - Budget card

    private var budget: ProjectBudget? { budgetRows.first }

    /// Today's cost for this project, from the existing `aggregates`
    /// @Query. Cheap because `aggregates` is already path-scoped and
    /// typically ≤90 rows.
    private var todayCost: Double {
        let today = TokenSample.formatDate(Date())
        return aggregates
            .filter { $0.date == today }
            .reduce(0) { $0 + $1.totalCostUSD }
    }

    /// Rolling 7-day cost for this project from `aggregates`.
    private var weekCost: Double {
        let weekAgo = TokenSample.formatDate(
            Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
        )
        return aggregates
            .filter { $0.date >= weekAgo }
            .reduce(0) { $0 + $1.totalCostUSD }
    }

    @ViewBuilder
    private var budgetCard: some View {
        PacerCard("Budget", content: {
            BudgetEditor(
                projectPath: projectPath,
                existing: budget,
                todayCost: todayCost,
                weekCost: weekCost,
                context: modelContext
            )
        }, footer: {
            Text("Set a daily or weekly cap to trigger a Pacer notification when this project's cost exceeds the limit. Master notifications must also be enabled in Settings.")
        })
    }


    // MARK: - First card

    /// The first card: the range's cost, two counts and the average, and
    /// its days as a strip (which had use, each one's height its sessions).
    /// Sessions come from the live session rows (distinct sessions, which a
    /// sum of per-day session counts is not), the rest from the caches. Each
    /// count is printed here only; the cards below carry none in their
    /// headers.
    private func summaryModel(
        _ d: Derived, _ a: ActivitySummary, models: Int, sessions: Int
    ) -> PacerSummaryModel {
        let perDay: Double = d.activeDays > 0 ? d.breakdown.total / Double(d.activeDays) : 0
        return PacerSummaryModel(
            breakdown: d.breakdown,
            stats: [
                PacerSummaryFact("sessions", "\(sessions)"),
                PacerSummaryFact("models", "\(models)"),
                PacerSummaryFact("per active day", d.activeDays > 0 ? pacerCost(perDay) : "–",
                                 help: d.activeDays > 0 ? pacerCostExact(perDay) : nil),
            ],
            activity: a.activity,
            span: a.span,
            trendCaption: "sessions a day",
            axis: a.axis,
            cellHelp: a.cellHelp)
    }

    /// The project's cost per active day, stacked by part — the shared
    /// `PacerStackedPartChart`, with the same hover card as every cost chart.
    /// Its top models are by cost, from the rollup's per-model split.
    /// Clicking a bar opens that day.
    private func dailyChartCard(_ series: [PacerChartBucket]) -> some View {
        PacerCard("Daily activity") {
            PacerStackedPartChart(series, kind: .day, onTap: { date in
                push(.day(date: date))
            })
            .accessibilityLabel("Daily cost for \(displayName)")
            .accessibilityHint("Click a bar to drill into that day")
        }
    }

    // MARK: - Tables

    /// By model's sort (which also turns its ring), and the Models and
    /// Subprojects tables' sorts. The Models table keeps the key By model
    /// used to have: a stored sort on its old "In + out" column falls back
    /// to cost (`DetailModalCards.sort`).
    @AppStorage("pacer.projectDetail.modelShareSort", store: PacerSettings.store)
    private var modelShareSortRaw: String = UsageColumn.cost.rawValue
    @AppStorage("pacer.projectDetail.modelShareSortDescending", store: PacerSettings.store)
    private var modelShareSortDescending: Bool = true

    @AppStorage("pacer.projectDetail.modelsSort", store: PacerSettings.store)
    private var modelsSortRaw: String = UsageColumn.cost.rawValue
    @AppStorage("pacer.projectDetail.modelsSortDescending", store: PacerSettings.store)
    private var modelsSortDescending: Bool = true

    @AppStorage("pacer.projectDetail.subprojectsSort", store: PacerSettings.store)
    private var subprojectsSortRaw: String = UsageColumn.cost.rawValue
    @AppStorage("pacer.projectDetail.subprojectsSortDescending", store: PacerSettings.store)
    private var subprojectsSortDescending: Bool = true

    /// Where in the project the cost went, by each turn's original cwd
    /// (before alias and worktree canonicalization): the shared paths table,
    /// as Day detail lists its projects.
    private func subprojectsCard(_ rows: [PacerUsageRow<DetailPathExtra>], sort: PacerUsageSort) -> some View {
        DetailModalCards.pathsTableCard(
            "Subprojects",
            labelTitle: "Subpath",
            rows: rows,
            tableId: "projectDetail.subprojects",
            sort: sort,
            onSort: { subprojectsSortRaw = $0.column; subprojectsSortDescending = $0.descending },
            rowMenu: { row in
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.id)])
                }
                Divider()
                Button("Copy path") { pacerCopyToPasteboard(row.id) }
                Button("Copy cost") { pacerCopyToPasteboard(pacerCostExact(row.cost)) }
            })
    }

    @AppStorage("pacer.projectDetail.sessionsSortField", store: PacerSettings.store)
    private var sessionsSortRaw: String = PacerSessionExtra.lastSeen
    @AppStorage("pacer.projectDetail.sessionsSortDescending", store: PacerSettings.store)
    private var sessionsSortDescending: Bool = true

    /// The Sessions table's rows, rebuilt when the project's sessions change
    /// (a scan, a scope switch) rather than on every body pass.
    @State private var sessionTableRows: [PacerSessionsTable.Row] = []
}

// MARK: - Budget editor

/// Inline editor + progress display for one project's `ProjectBudget`.
/// Write-through to SwiftData on every commit (TextField onSubmit /
/// Toggle binding) so the user doesn't have to hit a save button —
/// matches how the rest of Pacer's settings persist.
///
/// nil / 0 limits are stored as nil (no cap at that period). The
/// master `enabled` toggle pauses both daily AND weekly notifications
/// without zeroing out the thresholds.
private struct BudgetEditor: View {
    let projectPath: String
    let existing: ProjectBudget?
    let todayCost: Double
    let weekCost: Double
    let context: ModelContext

    /// Local mirror of persisted state. We sync from `existing` on
    /// appear and on `.id`-change, then write back through `commit()`
    /// so SwiftUI bindings don't fight live SwiftData updates.
    @State private var enabled: Bool = false
    @State private var dailyLimitText: String = ""
    @State private var weeklyLimitText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Enable budget for this project", isOn: $enabled)
                .onChange(of: enabled) { _, _ in commit() }

            HStack(spacing: 16) {
                limitField(label: "Daily limit", value: $dailyLimitText)
                limitField(label: "Weekly limit", value: $weeklyLimitText)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            if enabled, let limit = dailyLimit, limit > 0 {
                progressRow(label: "Today", current: todayCost, limit: limit)
            }
            if enabled, let limit = weeklyLimit, limit > 0 {
                progressRow(label: "Last 7 days", current: weekCost, limit: limit)
            }
        }
        .onAppear { syncFromPersisted() }
        .onChange(of: existing?.persistentModelID) { _, _ in syncFromPersisted() }
    }

    @ViewBuilder
    private func limitField(label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            HStack(spacing: 4) {
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("0", text: value)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 80)
                    .onSubmit { commit() }
            }
        }
    }

    @ViewBuilder
    private func progressRow(label: String, current: Double, limit: Double) -> some View {
        let ratio = limit > 0 ? current / limit : 0
        let displayRatio = min(1.0, max(0, ratio))
        let pct = "\(Int((ratio * 100).rounded()))%"
        let tint: Color =
            ratio >= 1.0 ? .red :
            ratio >= 0.8 ? .orange : .green
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(pacerCost(current)) / \(pacerCost(limit))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("\(pacerCostExact(current)) of \(pacerCostExact(limit))")
                Text(pct)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint)
                        .frame(width: geo.size.width * displayRatio, height: 4)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: - State syncing

    private var dailyLimit: Double? {
        let trimmed = dailyLimitText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let v = Double(trimmed), v > 0 else { return nil }
        return v
    }

    private var weeklyLimit: Double? {
        let trimmed = weeklyLimitText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let v = Double(trimmed), v > 0 else { return nil }
        return v
    }

    private func syncFromPersisted() {
        if let existing {
            enabled = existing.enabled
            dailyLimitText = existing.dailyLimitUSD.map { String(format: "%.2f", $0) } ?? ""
            weeklyLimitText = existing.weeklyLimitUSD.map { String(format: "%.2f", $0) } ?? ""
        } else {
            enabled = false
            dailyLimitText = ""
            weeklyLimitText = ""
        }
    }

    private func commit() {
        let daily = dailyLimit
        let weekly = weeklyLimit
        // No-budget state — neither limit set AND toggle off. Tear
        // down the row so the table stays clean.
        if !enabled, daily == nil, weekly == nil {
            if let existing {
                context.delete(existing)
                try? context.save()
            }
            return
        }
        if let existing {
            // Seeding the toggle from the stored row on appear fires its
            // `.onChange` too. Without this every open of a budgeted project
            // re-wrote the row and saved, and a save re-fetches every
            // `@Query` in the app.
            if existing.enabled == enabled, existing.dailyLimitUSD == daily,
               existing.weeklyLimitUSD == weekly { return }
            existing.enabled = enabled
            existing.dailyLimitUSD = daily
            existing.weeklyLimitUSD = weekly
            existing.updatedAt = Date()
        } else {
            context.insert(ProjectBudget(
                projectPath: projectPath,
                dailyLimitUSD: daily,
                weeklyLimitUSD: weekly,
                enabled: enabled
            ))
        }
        try? context.save()
    }
}
