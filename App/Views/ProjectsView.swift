import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

/// Per-project breakdown. Reads `ProjectDailyAggregate` (precomputed by
/// the in-process scan) so the table is sub-10ms even on populated
/// installs, and never iterates raw `TokenSample`s.
///
/// **Layout**: page header is just title + subtitle. Range picker
/// lives inline next to the data card it scopes (per the user's
/// "closer to the thing we are showing" feedback). Sort is driven by
/// clicking the table column headers; arrows on the active column
/// indicate direction. Both range and sort persist via App Group
/// `UserDefaults` under per-view keys so Models doesn't share state
/// with Projects.
/// The Projects page's search text and collection filter, held outside the
/// page view.
///
/// `ContentView` rebuilds the page at midnight (`.id(dayKey)`) so its
/// date-pinned queries move to the new day, and `@State` on the page went with
/// the rebuild: the search field and the collection filter cleared themselves
/// at midnight (#140). This lives for the process, like `@State` did, so a
/// relaunch still opens on "All" with no search. An open project detail still
/// closes at midnight: its queries are pinned to the day too, and reopening it
/// reads the new one.
@MainActor
@Observable
final class ProjectsPageState {
    static let shared = ProjectsPageState()
    var searchText = ""
    /// Active collection scope, `""` = All projects. Collections live inline
    /// here (a filter bar), not in a separate tab.
    var collectionFilter = ""
}

struct ProjectsView: View {
    /// Read here so a scope change re-runs the child initialiser — a
    /// `@Query` predicate is captured once at init.
    @State private var scope = UsageScope.shared
    @AppStorage("pacer.projects.range", store: PacerSettings.store)
    private var rangeRaw: String = TimeRange.ninetyDays.rawValue

    /// The table's sort column: a `UsageColumn` raw value, or "sessions" /
    /// "lastActive". The shared table's column ids reuse the raw values the
    /// old `ProjectSort` stored, so a stored sort carries over.
    @AppStorage(PacerSettings.Key.projectsSort, store: PacerSettings.store)
    private var sortRaw: String = UsageColumn.cost.rawValue

    @AppStorage("pacer.projects.sortDescending", store: PacerSettings.store)
    private var sortDescending: Bool = true

    /// The Top projects card's sort, its own: the card ranks the five
    /// largest by it and its ring measures it, while the table below keeps
    /// whatever order its user chose. "cost", "tokens" or "sessions".
    @AppStorage("pacer.projects.topSort", store: PacerSettings.store)
    private var topSortRaw: String = UsageColumn.cost.rawValue
    @AppStorage("pacer.projects.topSortDescending", store: PacerSettings.store)
    private var topSortDescending: Bool = true

    /// Search text and collection filter. See `ProjectsPageState`.
    @State private var page = ProjectsPageState.shared

    /// Optional starting scope (used by the screenshot harness to render a
    /// scoped collection; nil in normal use).
    var initialScope: String? = nil

    /// What the collections sheet opens into: the list ("Manage…"), a new
    /// collection, or one collection's editor ("Edit").
    ///
    /// One `Identifiable` request for `.sheet(item:)`, so the sheet gets its
    /// inputs in the value that opens it. It was three `@State` values set just
    /// before an `isPresented` flag, and the sheet's closure captured them as
    /// they stood when the body last ran: "Edit X" could open the plain list,
    /// or the collection edited last time (#140).
    struct CollectionsSheetRequest: Identifiable {
        enum Mode: Equatable { case manage, new, edit(String) }
        let id = UUID()
        let mode: Mode
    }
    @State private var collectionsSheet: CollectionsSheetRequest?
    /// Drives the project-alias manager sheet, opened from the toolbar.
    /// Lives here (alongside `.searchable`) so the sheet attaches at the
    /// same level as the toolbar item that opens it, outside the
    /// PageScaffold's ScrollView.
    @State private var showingAliasManager = false
    /// Lifted from ProjectsContent so the modal-navigation modifier
    /// can attach OUTSIDE the PageScaffold's ScrollView. Without
    /// lifting this state up, the modal overlay sat inside the
    /// ScrollView's content frame and (a) scrolled with the page,
    /// (b) added empty padding to the bottom of the scrollable area
    /// equal to the modal's frame.
    @State private var modalRoot: PacerModalDestination?

    private var range: TimeRange {
        TimeRange(rawValue: rangeRaw) ?? .ninetyDays
    }
    private var sort: PacerUsageSort {
        PacerUsageSort(column: sortRaw, descending: sortDescending)
    }
    private var topSort: PacerUsageSort {
        PacerUsageSort(column: topSortRaw, descending: topSortDescending)
    }

    var body: some View {
        // Presentation state, read here so setting it redraws this view and
        // what it presents opens at once. Passed only as a binding, nothing
        // read it: the collections sheet opened only after an unrelated
        // redraw, seconds later (#140; AGENTS.md, "SwiftUI state and data flow").
        let _ = (showingAliasManager, collectionsSheet?.id)
        // Read here, in this view's own `body`, and captured by the content
        // closure below. `PageScaffold` stores that closure and runs it in its
        // own body, and a read that happens there may make PageScaffold depend
        // on the value rather than this page. That is the shape of the modal
        // bug #150 fixed, where a click only showed after something unrelated
        // redrew the page (#140; AGENTS.md, "SwiftUI state and data flow").
        let range = self.range, sort = self.sort, topSort = self.topSort
        let scopeAccountId = scope.accountId
        let searchText = page.searchText, collectionFilter = page.collectionFilter
        PageScaffold(
            "Projects",
            subtitle: "Per-project rollup of cost and tokens.",
            trailing: { headerControls }
        ) {
            ProjectsContent(
                range: range,
                scopeAccountId: scopeAccountId,
                sort: sort,
                onSort: { sortRaw = $0.column; sortDescending = $0.descending },
                topSort: topSort,
                onTopSort: { topSortRaw = $0.column; topSortDescending = $0.descending },
                searchText: searchText,
                collectionFilter: collectionFilter,
                rangeBinding: rangeBinding,
                collectionFilterBinding: $page.collectionFilter,
                onSelectProject: { path, displayName, since in
                    Log.write("Navigation", "open project \(URL(fileURLWithPath: path).lastPathComponent)")
                    modalRoot = .project(path: path, displayName: displayName, since: since)
                },
                onNewCollection: { collectionsSheet = .init(mode: .new) },
                onManageCollections: { collectionsSheet = .init(mode: .manage) },
                onEditCollection: { id in collectionsSheet = .init(mode: .edit(id)) }
            )
            .id("\(range.rawValue)")
        }
        // Native macOS search field lives in the window toolbar — frees
        // the card header from the custom magnifying-glass + xmark
        // arrangement we built by hand, and gets the standard search
        // chrome (clear button, placeholder, a11y) for free. Each
        // sidebar destination has its own toolbar context inside the
        // NavigationSplitView, so the field only appears while
        // Projects is the active destination.
        .searchable(
            text: $page.searchText,
            placement: .toolbar,
            prompt: "Filter projects"
        )
        .sheet(isPresented: $showingAliasManager) {
            ProjectAliasManager()
        }
        .sheet(item: $collectionsSheet) { request in
            switch request.mode {
            case .manage:        CollectionsManager()
            case .new:           CollectionsManager(startNew: true)
            case .edit(let id):  CollectionsManager(editCollectionID: id)
            }
        }
        .pacerModalNavigation(modalRoot, root: $modalRoot)
        .onAppear {
            if let initialScope, page.collectionFilter.isEmpty { page.collectionFilter = initialScope }
        }
    }

    /// Tab-level controls in the page header: the alias-manager entry
    /// point and the time-range picker. Both belong to the whole tab —
    /// the range picker scopes the collections, the donut AND the table,
    /// and the alias manager acts across every project — so they live in
    /// the page header rather than a single card's header, matching the
    /// History tab. (Previously the picker sat in the "All projects" card
    /// header, which made it read as if it only scoped the list.)
    @ViewBuilder
    private var headerControls: some View {
        HStack(spacing: 10) {
            Button {
                showingAliasManager = true
            } label: {
                Label("Aliases…", systemImage: "arrow.triangle.merge")
            }
            .pacerDenseControl()
            .help("Manage project aliases — fold renamed folders, sibling worktrees, and cross-machine paths into one project.")
            Picker("Time range", selection: rangeBinding) {
                ForEach(TimeRange.allCases) { r in
                    Text(r.shortLabel).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .pacerDenseControl()
            .labelsHidden()
        }
    }

    private var rangeBinding: Binding<TimeRange> {
        Binding(get: { range }, set: { rangeRaw = $0.rawValue })
    }
}

/// The metric the heatmap colours its days by. (The Top projects donut
/// follows its list's sort instead: `PacerShareDonutData`.)
enum ProjectMetric: String, CaseIterable, Identifiable {
    case cost
    case tokens
    case sessions

    var id: String { rawValue }
    var label: String {
        switch self {
        case .cost:     return "Cost"
        case .tokens:   return "Tokens"
        case .sessions: return "Sessions"
        }
    }
}

private struct ProjectsContent: View {
    @Query private var globalAggregates: [ProjectDailyAggregate]
    /// The same rollup sliced to one account; `scope` picks which is read.
    @Query private var scopedAggregates: [AccountProjectDailyAggregate]
    @State private var scope = UsageScope.shared

    /// Every account, or one. Both queries are live, so switching is a
    /// re-read rather than a recompute.
    private var aggregates: [any ProjectDailyReadable] {
        scope.isAll ? globalAggregates : scopedAggregates
    }
    /// Singleton-row probe that fires exactly once per completed scan
    /// cycle. Drives the cache refresh below — far cheaper than
    /// recomputing `allRows` on every SwiftData notification.
    @Query(ScanMetaFetchDescriptor.scanCompletedProbe)
    private var scanMeta: [ClaudeCodeMeta]
    /// Per-path probe rows (small table, ~one per known project)
    /// drive the git/no-git badge on each row. The auto-aliaser
    /// maintains this table during the scan cycle.
    @Query private var probes: [ProjectPathProbe]
    /// Collections are small; queried here so the filter bar, per-row
    /// membership chips, and scope resolution all read from one source.
    @Query(sort: [SortDescriptor(\ProjectCollection.sortOrder, order: .reverse)])
    private var collections: [ProjectCollection]
    /// Per-project metadata (stable color seed). Small, sparse table.
    @Query private var projectMetas: [ProjectMeta]
    @Environment(\.modelContext) private var modelContext

    /// Pending one-tap merge from the "Merge into → X" submenu.
    /// Driving a `.confirmationDialog` off this state — the user has
    /// already picked both sides via the submenu, so opening a full
    /// editor sheet (the old behavior) was needless friction. A
    /// single confirm click is enough; mistakes are recoverable from
    /// Settings → Project Aliases.
    @State private var pendingQuickMerge: QuickMerge?
    /// Drives the bulk-merge sheet (multi-source picker). Reachable
    /// from the card-header button OR from a row's "Merge with
    /// others…" context-menu item.
    @State private var bulkMergeDraft: BulkMergeDraft?
    @State private var aliasError: String?

    /// Cached group/sort pipeline output. Populated via `.onAppear` /
    /// `.onChange` on scan tick / sort. nil → body falls back to a
    /// synchronous compute so the first render after a `.id(range)`
    /// re-init never flashes an empty list while waiting for
    /// `.onAppear` to fire. Hover-driven body re-fires (chart selection,
    /// table row hover) skip the recompute because the cache is
    /// populated by then.
    @State private var cachedAllRows: [ProjectRow]?
    /// Filtered + searched derivative. Separate cache so keystrokes in
    /// the search field only re-run the filter, not the whole
    /// bucket+sort pass. Debounced from search text to avoid recomputing
    /// on every individual character.
    @State private var cachedFilteredRows: [ProjectRow]?
    /// `cachedFilteredRows` as the shared table's rows, built with it so a
    /// body pass does not rebuild them or their colours.
    @State private var cachedTableRows: [PacerUsageRow<ProjectRow>]?
    /// The Top projects card: its ring and list follow the table's rows (the
    /// search and the collection) and the card's own sort, so both refresh it
    /// (`refreshFilteredRows`, and the sort's own trigger). Hundreds of
    /// projects are too many to rank per body pass.
    @State private var cachedTop: PacerShareListData<ProjectRow>?
    /// The sort the card was last built for, kept as state so a refresh
    /// from the search debounce, whose closure holds an older copy of this
    /// view, still ranks by the sort on screen.
    @State private var builtTopSort: PacerUsageSort
    @State private var debouncedSearch: String = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    /// Candidate canonical paths for the "Merge into…" submenu. Used
    /// to be filtered per row inside the context menu (O(rows²) per
    /// table render — the dominant scroll-lag cost on a list of any
    /// size). Derived once alongside `cachedAllRows` and consulted by
    /// each row's menu builder via path-equality skip, dropping the
    /// per-render filter to O(rows).
    @State private var cachedMergeCandidates: [ProjectRow]?
    /// path -> collection ids, for the per-row membership chips. Built once
    /// per scan tick (not per row) to keep the table scroll cheap.
    @State private var cachedMembership: [String: [String]] = [:]
    /// Resolved + rolled-up collections for the filter bar, ranked by cost.
    @State private var cachedCollectionRollups: [CollectionRollupResult] = []

    let rangeSince: Date?
    let searchText: String
    /// The table's sort. The table sorts the cached rows itself.
    let sort: PacerUsageSort
    let onSort: (PacerUsageSort) -> Void
    /// The Top projects card's sort: an input to `cachedTop`.
    let topSort: PacerUsageSort
    let onTopSort: (PacerUsageSort) -> Void
    /// Active collection scope — `""` = All projects.
    let collectionFilter: String

    let rangeBinding: Binding<TimeRange>
    let collectionFilterBinding: Binding<String>
    /// Callback into the page-level modal navigator. Receives the
    /// project's path + display name + the range's start-date so the
    /// detail view can scope its @Query.
    let onSelectProject: (_ path: String, _ displayName: String, _ since: Date?) -> Void
    let onNewCollection: () -> Void
    let onManageCollections: () -> Void
    let onEditCollection: (_ id: String) -> Void

    init(
        range: TimeRange,
        scopeAccountId: String? = nil,
        sort: PacerUsageSort,
        onSort: @escaping (PacerUsageSort) -> Void,
        topSort: PacerUsageSort,
        onTopSort: @escaping (PacerUsageSort) -> Void,
        searchText: String,
        collectionFilter: String,
        rangeBinding: Binding<TimeRange>,
        collectionFilterBinding: Binding<String>,
        onSelectProject: @escaping (_ path: String, _ displayName: String, _ since: Date?) -> Void,
        onNewCollection: @escaping () -> Void,
        onManageCollections: @escaping () -> Void,
        onEditCollection: @escaping (_ id: String) -> Void
    ) {
        let since: Date?
        let cutoffString: String?
        if let days = range.days {
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
            since = cutoffDate
            cutoffString = TokenSample.formatDate(cutoffDate)
        } else {
            since = nil
            cutoffString = nil
        }
        self.rangeSince = since
        self.searchText = searchText
        // Starts from the search the page holds. It outlives this view
        // (`ProjectsPageState`), and `.onChange(of: searchText)` fires only on
        // a change, so a rebuild (tab switch, range change, midnight) left the
        // field showing "pacer" over an unfiltered list.
        _debouncedSearch = State(initialValue: searchText)
        self.sort = sort
        self.onSort = onSort
        self.topSort = topSort
        _builtTopSort = State(initialValue: topSort)
        self.onTopSort = onTopSort
        self.collectionFilter = collectionFilter
        self.rangeBinding = rangeBinding
        self.collectionFilterBinding = collectionFilterBinding
        self.onSelectProject = onSelectProject
        self.onNewCollection = onNewCollection
        self.onManageCollections = onManageCollections
        self.onEditCollection = onEditCollection
        let acct = scopeAccountId ?? UsageScope.noAccountSentinel
        if let cutoffString {
            _globalAggregates = Query(
                filter: #Predicate<ProjectDailyAggregate> { $0.date >= cutoffString }
            )
            _scopedAggregates = Query(
                filter: #Predicate<AccountProjectDailyAggregate> {
                    $0.date >= cutoffString && $0.accountId == acct
                }
            )
        } else {
            _globalAggregates = Query()
            _scopedAggregates = Query(
                filter: #Predicate<AccountProjectDailyAggregate> { $0.accountId == acct }
            )
        }
    }

    /// One project. It is also the table row's `extra`, so the row menu and
    /// the Sessions / Last active columns read it directly.
    fileprivate struct ProjectRow: Identifiable, PacerUsageExtra {
        static let sessionsColumn = "sessions"
        static let lastActiveColumn = "lastActive"

        let path: String
        let displayName: String
        let cost: Double
        /// From `ProjectUsageTotals` — the fold Project detail and Day detail
        /// use, so all three agree (#215).
        let tokens: TokenBreakdown
        var totalTokens: Int64 { tokens.all }
        /// `cost` by priced part, for the table's ratio and Mix columns.
        let costParts: CostComponents
        let sessionCount: Int
        let lastActive: Date
        let modelCount: Int
        /// Folded into the row at `refreshAllRows` time so badge
        /// rendering doesn't do per-row filesystem syscalls during
        /// a scroll pass.
        let status: ProjectStatusBadge.State
        /// Stable-color inputs from `ProjectMeta` (frozen seed / optional
        /// override), folded in at cache-build time.
        let colorSeed: String?
        let colorHex: String?
        var id: String { path }

        func sortKey(forColumn id: String) -> PacerUsageSortKey? {
            switch id {
            case Self.sessionsColumn:   return .number(Double(sessionCount))
            case Self.lastActiveColumn: return .date(lastActive)
            default:                    return nil
            }
        }

        /// Sessions add up across projects, so sorting Top projects by them
        /// turns its ring to sessions. Last active is a date and does not.
        static func shareMetric(forColumn id: String) -> PacerShareMetric? {
            id == sessionsColumn ? PacerShareMetric(column: id, title: "Sessions") : nil
        }

        func shareValue(forColumn id: String) -> Double? {
            id == Self.sessionsColumn ? Double(sessionCount) : nil
        }
    }

    /// A pending source→canonical pair waiting on the user's confirm
    /// click in `.confirmationDialog`. Lighter than the old
    /// `AliasDraft` sheet because no editing is exposed — the user
    /// already specified both sides via the context-menu submenu.
    struct QuickMerge: Equatable {
        let source: String
        let canonical: String
    }

    /// Public accessor used by `body` and the "Merge into…" submenu.
    /// Falls back to a synchronous compute when the cache hasn't been
    /// populated yet — that's the first render after a `.id(range)`
    /// re-init, before `.onAppear` fires `refreshAllRows`.
    ///
    /// The fallback is memoised for that first render. Every visible row's
    /// context menu reads `mergeCandidates` while the list is built, and
    /// without the memo each one recomputed every row from the aggregates —
    /// O(rows²) on exactly the render a tab switch waits for. Sampled at
    /// ~90 ms of a 627 ms main-thread stall switching to this tab.
    private var allRows: [ProjectRow] {
        if let cached = cachedAllRows { return cached }
        if let memo = firstRenderMemo.rows { return memo }
        let rows = computeAllRowsSync()
        firstRenderMemo.rows = rows
        return rows
    }

    private var mergeCandidates: [ProjectRow] {
        if let cached = cachedMergeCandidates { return cached }
        if let memo = firstRenderMemo.candidates { return memo }
        let candidates = allRows.filter { $0.path != ProjectDailyAggregate.unknownProjectPath }
        firstRenderMemo.candidates = candidates
        return candidates
    }

    /// A reference, so `body` can fill it: `@State` cannot be written during
    /// a render, and this only has to live until `refreshAllRows` fills the
    /// real caches on appear (which clears it).
    private final class FirstRenderMemo {
        var rows: [ProjectRow]?
        var candidates: [ProjectRow]?
    }
    @State private var firstRenderMemo = FirstRenderMemo()

    /// Rebuild the `cachedAllRows` snapshot. Called on appear, on
    /// scan-meta tick, and whenever sort/range changes invalidate the
    /// existing snapshot. O(aggregates) — typically thousands of rows
    /// on a power user's DB; runs at most once per scan cycle now
    /// instead of once per body render.
    private func refreshAllRows() {
        let rows = computeAllRowsSync()
        cachedAllRows = rows
        firstRenderMemo = FirstRenderMemo()
        // Pre-build the merge-candidate list once. Each row's context
        // menu used to do `allRows.filter { $0.path != row.path && ... }`
        // — O(rows) per row, O(rows²) per table render. With the
        // candidates cached, the menu just skips the one current row
        // at iteration time and is O(rows) total per render.
        cachedMergeCandidates = rows.filter {
            $0.path != ProjectDailyAggregate.unknownProjectPath
        }
        // Collection derivations, built once per scan tick (not per row):
        // the per-path membership map for row chips, and the ranked
        // rollups for the filter bar.
        let allPaths = rows.map(\.path)
        cachedMembership = CollectionResolver.membership(
            of: allPaths, collections: collections, knownPaths: allPaths
        )
        cachedCollectionRollups = CollectionUsageRollup
            .resolveAll(collections: collections, aggregates: aggregates)
            // Stable tiebreaker on the collection id so two equal-cost
            // collections don't swap order (and reshuffle the filter chips)
            // between scan ticks — Swift's sort isn't guaranteed stable.
            .sorted {
                $0.totals.cost != $1.totals.cost
                    ? $0.totals.cost > $1.totals.cost
                    : $0.id < $1.id
            }
        refreshFilteredRows()
    }

    /// Resolve the active collection scope to its member paths, or nil for
    /// "All". Cheap set-ops; used to filter the displayed rows.
    private func scopeMemberPaths() -> Set<String>? {
        guard !collectionFilter.isEmpty else { return nil }
        return cachedCollectionRollups.first { $0.id == collectionFilter }?.memberPaths
            ?? {
                let byID = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                // `allRows`, not `cachedAllRows`: on the first frame the cache
                // is still empty, and against no known projects a rule (a
                // folder, a pattern) matches nothing. A collection scoped
                // through rules opened showing only its hand-picked members
                // (one donut wedge as the whole ring), then snapped to the
                // rest a frame later.
                let known = allRows.map(\.path)
                return CollectionResolver.resolve(collectionFilter, collections: byID, knownPaths: known)
            }()
    }

    private func applyScope(_ rows: [ProjectRow]) -> [ProjectRow] {
        guard let members = scopeMemberPaths() else { return rows }
        return rows.filter { members.contains($0.path) }
    }

    /// Pure computation over `aggregates` + `probes`. Used both by
    /// `refreshAllRows()` (writes to `@State`) and by the `allRows` fallback
    /// when the cache hasn't landed yet — that's the first render after a
    /// `.id(range)` re-init, before `.onAppear` fires. The table's sort is
    /// not an input: the table sorts these rows itself.
    private func computeAllRowsSync() -> [ProjectRow] {
        struct Acc {
            var totals = ProjectUsageTotals.zero
            var modelCount: Int = 0
        }
        var byProject: [String: Acc] = [:]
        for r in aggregates {
            var a = byProject[r.projectPath] ?? Acc()
            a.totals.add(r)
            a.modelCount += r.modelCount
            byProject[r.projectPath] = a
        }
        // Index probes once for the badge derivation below. Small
        // table (~one row per known project) so the dict build is
        // ~microseconds.
        let probeByPath = Dictionary(uniqueKeysWithValues: probes.map { ($0.path, $0) })
        // Collision-aware names so two "website" projects are
        // distinguishable in the leaderboard. Computed once over the whole
        // path set, folded into the cached row.
        let names = pacerDisambiguatedNames(Array(byProject.keys))
        let metaByPath = Dictionary(projectMetas.map { ($0.projectPath, $0) }, uniquingKeysWith: { a, _ in a })
        let fm = FileManager.default
        let unsorted = byProject.map { (key, a) in
            // Per-row fs check folded into the cache build so scroll
            // and hover passes don't trigger syscalls. The cost is
            // one `fileExists` per project (~50 typical) per scan
            // tick, well under a millisecond total.
            let exists = fm.fileExists(atPath: key)
            let status = projectStatusBadgeState(
                for: key, probesByPath: probeByPath, existsOnDisk: exists
            )
            return ProjectRow(
                path: key,
                displayName: names[key] ?? pacerShortPath(key),
                cost: a.totals.cost,
                tokens: a.totals.tokens,
                costParts: a.totals.costParts,
                sessionCount: a.totals.sessionCount,
                lastActive: a.totals.lastActive,
                modelCount: a.modelCount,
                status: status,
                colorSeed: metaByPath[key]?.colorSeed,
                colorHex: metaByPath[key]?.colorHex
            )
        }
        // Cost, largest first, path breaking ties: a stable base order for
        // the merge submenu. The table re-sorts by the user's column.
        return unsorted.sorted { lhs, rhs in
            lhs.cost != rhs.cost ? lhs.cost > rhs.cost : lhs.path < rhs.path
        }
    }

    /// Filter the cached snapshot by the (debounced) search needle.
    /// Cheap — O(cachedAllRows), no per-row recompute — but worth
    /// caching too so view body never does string lowercasing.
    private func refreshFilteredRows() {
        let source = applyScope(cachedAllRows ?? computeAllRowsSync())
        let filtered = filter(rows: source, by: debouncedSearch)
        cachedFilteredRows = filtered
        let tableRows = Self.tableRows(filtered)
        cachedTableRows = tableRows
        cachedTop = Self.top(tableRows, sort: builtTopSort)
    }

    /// Top projects' columns: each project's share of the cost, the tokens
    /// and the sessions. Shares, not amounts: the table below prints every
    /// project's amounts, and the page prints a number once.
    private static let topColumns: [PacerShareListColumn] = [
        .share(of: UsageColumn.cost.rawValue, title: "Cost", format: .cost, help: "Share of the cost"),
        .share(of: UsageColumn.tokens.rawValue, title: "Tokens", format: .tokens, help: "Share of every token"),
        .share(of: ProjectRow.sessionsColumn, title: "Sessions", format: .count, help: "Share of the sessions",
               width: 66),
    ]

    /// The five largest projects by the card's sort, and the rest as one
    /// Other line and wedge: the share is of everything the table lists.
    private static func top(_ rows: [PacerUsageRow<ProjectRow>], sort: PacerUsageSort) -> PacerShareListData<ProjectRow> {
        PacerShareListData(rows: rows, sort: sort, columns: topColumns, maxSlices: 5)
    }

    /// The table's plain-value rows: the project's name over its path, in
    /// its identity colour (the one its donut wedge is drawn in).
    private static func tableRows(_ rows: [ProjectRow]) -> [PacerUsageRow<ProjectRow>] {
        rows.map { row in
            PacerUsageRow(
                id: row.path,
                label: row.displayName,
                subtitle: row.path,
                color: pacerProjectColor(path: row.path, seed: row.colorSeed, hex: row.colorHex),
                tokens: row.tokens,
                costParts: row.costParts,
                cost: row.cost,
                extra: row)
        }
    }

    private func filter(rows: [ProjectRow], by needle: String) -> [ProjectRow] {
        let trimmed = needle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        let lower = trimmed.lowercased()
        return rows.filter {
            $0.path.lowercased().contains(lower) ||
            $0.displayName.lowercased().contains(lower)
        }
    }

    /// What the body actually renders. Falls back to a synchronous
    /// filter when the cache hasn't landed yet so the first render
    /// after a `.id(range)` re-init never shows an empty list.
    private var rows: [ProjectRow] {
        if let cached = cachedFilteredRows { return cached }
        return filter(rows: applyScope(allRows), by: debouncedSearch)
    }

    var body: some View {
        // Presentation state, read here so setting it redraws this view and
        // what it presents opens at once. Passed only as a binding, nothing
        // read it: the collections sheet opened only after an unrelated
        // redraw, seconds later (#140; AGENTS.md, "SwiftUI state and data flow").
        let _ = (bulkMergeDraft?.id, aliasError)
        // No more `.dismissibleModal` here — it lives on the outer
        // ProjectsView so the overlay sits ABOVE the PageScaffold's
        // ScrollView rather than inside its content. This view just
        // sets the binding when the user picks a project; the parent
        // owns the modal layer.
        VStack(alignment: .leading, spacing: PacerDesign.sectionSpacing) {
            collectionFilterBar
            if !collectionFilter.isEmpty { scopeHeader }
            if let comp = scopeComposition() { compositionCard(comp) }
            if rows.isEmpty && !searchText.isEmpty {
                noSearchMatchesState
            } else if rows.isEmpty {
                emptyState
            } else {
                topProjectsCard
                projectListCard
            }
        }
        .sheet(item: $bulkMergeDraft) { draft in
            BulkMergeSheet(
                knownPaths: allRows.map(\.path).filter { $0 != ProjectDailyAggregate.unknownProjectPath },
                initialCanonical: draft.canonical,
                initialSources: draft.sources
            )
        }
        // Quick-merge confirmation. The user already picked both
        // sides from the context-menu submenu — a full editor sheet
        // there was three extra clicks (open / focus Save / close)
        // for no actual editing. `.confirmationDialog` gives the
        // single Yes/No moment the action needs.
        .confirmationDialog(
            quickMergePrompt,
            isPresented: Binding(get: { pendingQuickMerge != nil }, set: { if !$0 { pendingQuickMerge = nil } }),
            titleVisibility: .visible,
            presenting: pendingQuickMerge
        ) { merge in
            Button("Merge") {
                quickMerge(merge)
            }
            Button("Cancel", role: .cancel) { pendingQuickMerge = nil }
        } message: { merge in
            Text("Existing samples for \(pacerShortPath(merge.source)) will be re-attributed to \(pacerShortPath(merge.canonical)) on the next scan cycle. You can undo from Settings → Project Aliases.")
        }
        .alert(
            "Could not merge",
            isPresented: Binding(get: { aliasError != nil }, set: { if !$0 { aliasError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(aliasError ?? "")
        }
        // Cache refresh triggers. We rebuild `cachedAllRows` only when
        // something that *could* change its contents fires: a scan
        // committed new data, the user picked a different range / sort
        // / direction, or the view just appeared. Hover state changes
        // and chart re-renders no longer trigger the O(aggregates)
        // bucket+sort pipeline.
        .modifier(RefreshTriggers(owner: self))
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                debouncedSearch = newValue
                refreshFilteredRows()
            }
        }
    }

    /// The cache-refresh triggers, lifted out of the body's modifier chain.
    ///
    /// Ten `.onChange` modifiers plus the `@Query` macros is past what the type
    /// inferencer will do in reasonable time — adding the scope trigger tipped
    /// it into a hard "unable to type-check" error. Splitting gives it two
    /// small problems instead of one large one.
    struct RefreshTriggers: ViewModifier {
        let owner: ProjectsContent
        func body(content: Content) -> some View { owner.refreshTriggerModifiers(content) }
    }

    /// Changes whenever a collection changes in any way the rows, chips or
    /// scope header read.
    private var collectionsFingerprint: Int {
        var h = Hasher()
        for c in collections {
            h.combine(c.id)
            h.combine(c.name)
            h.combine(c.colorSeed)
            h.combine(c.colorHex)
            h.combine(c.sortOrder)
            h.combine(c.includePathsJSON)
            h.combine(c.excludePathsJSON)
            h.combine(c.rulesJSON)
            h.combine(c.childCollectionIDsJSON)
        }
        return h.finalize()
    }

    @ViewBuilder
    fileprivate func refreshTriggerModifiers(_ base: some View) -> some View {
        base
            .onAppear { refreshAllRows() }
            .onChange(of: scanMeta.first?.value) { _, _ in refreshAllRows() }
            // The scope is a refresh trigger like any other. Without it the
            // cache holds the previous account's numbers until the *next scan
            // cycle* happens to fire — on an idle machine seven to ten seconds,
            // which looks like a very slow render rather than a stale one.
            .onChange(of: scope.accountId) { _, _ in refreshAllRows() }
            // No `rangeSince` trigger: `.id(range)` rebuilds this view when the
            // range changes, and the cutoff is recomputed from `Date()` on
            // every init, so as a trigger it re-ran the whole refresh on any
            // redraw of the page — each search keystroke, each project click.
            .onChange(of: collectionFilter) { _, _ in refreshFilteredRows() }
            // Top projects ranks by its own sort: a title click re-ranks the
            // list and the ring without a rows refresh.
            .onChange(of: topSort) { _, sort in
                builtTopSort = sort
                cachedTop = Self.top(cachedTableRows ?? Self.tableRows(rows), sort: sort)
            }
            // Every field the rollups read, not the count: editing a
            // collection renames, recolours and re-members it in place.
            .onChange(of: collectionsFingerprint) { _, _ in refreshAllRows() }
            .onChange(of: projectMetas.count) { _, _ in refreshAllRows() }
            // Probe count drives the badge state — picks up the very first
            // probe write, plus churn from a forced re-walk.
            .onChange(of: probes.count) { _, _ in refreshAllRows() }
    }

    /// Submenu listing every other project as a possible canonical.
    /// Selecting one fires a confirmation dialog (NOT the alias
    /// editor) — both paths are already known by the time the user
    /// drilled this far into the menu, so a tight Yes/No prompt is
    /// all the action needs. The shared `ProjectPathAliasManager.upsert`
    /// still runs cycle/self-alias validation; errors surface in the
    /// "Could not merge" alert.
    ///
    /// "Merge with others…" beneath the submenu opens the bulk-merge
    /// sheet with this row preselected as the canonical, for the
    /// "I've got 5+ derivative paths to fold into Pacer" case.
    ///
    /// Iterates `cachedMergeCandidates` (built once in `refreshAllRows`)
    /// rather than re-filtering `allRows` per row — the previous
    /// shape was O(rows²) per table render, which was the dominant
    /// cause of scroll lag on a project list of any size.
    @ViewBuilder
    private func mergeIntoMenu(for row: ProjectRow) -> some View {
        let candidates = mergeCandidates
        if row.path != ProjectDailyAggregate.unknownProjectPath
            && candidates.count > 1 {
            Menu("Merge into…") {
                ForEach(candidates) { other in
                    if other.path != row.path {
                        Button(other.displayName) {
                            pendingQuickMerge = QuickMerge(
                                source: row.path,
                                canonical: other.path
                            )
                        }
                    }
                }
            }
            Button("Merge others into this…") {
                bulkMergeDraft = BulkMergeDraft(
                    canonical: row.path,
                    sources: []
                )
            }
            .help("Open the bulk-merge dialog with this project preselected as the canonical.")
        }
    }

    /// The confirmation-dialog title. SwiftUI re-reads this whenever
    /// `pendingQuickMerge` changes, so keep it a pure derivation.
    private var quickMergePrompt: String {
        guard let m = pendingQuickMerge else { return "" }
        return "Merge \(pacerShortPath(m.source)) into \(pacerShortPath(m.canonical))?"
    }

    private func quickMerge(_ merge: QuickMerge) {
        let manager = ProjectPathAliasManager(context: modelContext)
        do {
            try manager.upsert(sourcePath: merge.source, canonicalPath: merge.canonical)
            pendingQuickMerge = nil
            aliasError = nil
            // Same as the bulk path: kick a scan cycle now so the
            // user doesn't sit waiting for the watcher backstop to
            // notice the alias-fingerprint drift.
            NotificationCenter.default.post(name: .pacerRequestImmediateScan, object: nil)
        } catch let error as ProjectPathAliasManager.AliasError {
            pendingQuickMerge = nil
            switch error {
            case .selfAlias:
                aliasError = "Source and canonical paths must be different."
            case .emptyPath:
                aliasError = "Both paths are required."
            case .wouldCreateCycle:
                aliasError = "That mapping would create a loop with an existing alias."
            }
        } catch {
            pendingQuickMerge = nil
            aliasError = error.localizedDescription
        }
    }

    private var noSearchMatchesState: some View {
        PacerCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("No projects match \u{201C}\(searchText)\u{201D}")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Text("Try clearing the filter or widening the time range.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var emptyState: some View {
        PacerCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("No project activity in the selected range.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("Pacer reads `cwd` from each Claude Code JSONL line, so projects show up automatically as soon as you run Claude Code in a directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The five projects with the largest share of the card's sort (cost by
    /// default), and the rest as one line: the shared donut card. Its
    /// columns are shares, so none of the table's amounts is printed twice;
    /// clicking one ranks the list by it and turns the ring to it. A line
    /// opens its project, as the table's rows do.
    private var topProjectsCard: some View {
        let tableRows = cachedTableRows ?? Self.tableRows(rows)
        let top = cachedTop ?? Self.top(tableRows, sort: topSort)
        return PacerDonutListCard(
            "Top projects",
            data: top,
            labelTitle: "Project",
            accessibilityLabel: "Projects by \(top.donut.metric.title.lowercased())",
            onSort: onTopSort,
            onOpen: { row in onSelectProject(row.extra.path, row.extra.displayName, rangeSince) })
    }

    /// Every project, in the shared usage table as its own card: the token
    /// parts, the total and the cost, plus Sessions and Last active. Click a
    /// row for Project detail; right-click for collections, merges and
    /// copying. The range picker and the alias manager live in the page
    /// header, and the search field in the window toolbar (`.searchable` on
    /// the parent view).
    ///
    /// Round 3 put this table beside the Top projects donut in one card, and
    /// the owner found it very hard to read; the donut is its own card above
    /// again, and the table has the page's width.
    private var projectListCard: some View {
        let tableRows = cachedTableRows ?? Self.tableRows(rows)
        return PacerTableCard("All projects", trailing: {
            Text("\(tableRows.count) project\(tableRows.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }) {
            // A native table only realizes the rows in view, which is
            // what the `LazyVStack` here used to buy: a long project
            // list does not build every row's context menu up front.
            PacerUsageTable(
                rows: tableRows,
                // The full-width list's own layout, as it was before round 3
                // put it beside the donut (under "projects.list"). A width
                // saved in another window size is refitted to this one.
                tableId: "projects",
                labelTitle: "Project",
                sort: sort,
                onSort: onSort,
                onOpen: { row in
                    onSelectProject(row.extra.path, row.extra.displayName, rangeSince)
                },
                extraColumns: {
                    PacerUsageColumns.extra(ProjectRow.sessionsColumn, title: "Sessions",
                                            of: ProjectRow.self,
                                            minWidth: 28, idealWidth: 58) { row in
                        Text("\(row.extra.sessionCount)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    PacerUsageColumns.extra(ProjectRow.lastActiveColumn, title: "Last active",
                                            of: ProjectRow.self,
                                            minWidth: 36, idealWidth: 70) { row in
                        // Judged against the clock, so it needs one: on an
                        // idle machine nothing else redraws the list, and
                        // "2 min ago" stayed put.
                        TimelineView(.everyMinute) { _ in
                            Text(pacerRelative(row.extra.lastActive))
                                .help(pacerRelativeExact(row.extra.lastActive))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                },
                labelAccessory: { row in
                    ProjectStatusBadge(state: row.extra.status)
                    membershipDots(for: row.extra.path)
                },
                rowMenu: { row in
                    projectMenu(for: row.extra)
                })
        }
    }

    @ViewBuilder
    private func projectMenu(for row: ProjectRow) -> some View {
        Button("Open project") {
            onSelectProject(row.path, row.displayName, rangeSince)
        }
        if row.path != ProjectDailyAggregate.unknownProjectPath {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: row.path)]
                )
            }
        }
        Divider()
        if !collections.isEmpty {
            addToCollectionMenu(for: row)
        }
        mergeIntoMenu(for: row)
        Divider()
        Button("Copy path") {
            pacerCopyToPasteboard(row.path)
        }
        Button("Copy display name") {
            pacerCopyToPasteboard(row.displayName)
        }
    }

    // MARK: - Collections (inline in the Projects tab)

    private var collectionsByID: [String: ProjectCollection] {
        Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Horizontal filter bar: "All" + one chip per collection (with its
    /// rolled-up total). Selecting a chip scopes the donut + table to that
    /// collection. This is where collections live now — inline in Projects,
    /// not a separate tab.
    @ViewBuilder
    private var collectionFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if cachedCollectionRollups.isEmpty {
                    Text("Collections")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button(action: onNewCollection) {
                        Label("Group projects…", systemImage: "plus.circle")
                    }
                    .pacerDenseControl()
                    .buttonStyle(.borderless)
                    .help("Roll up related projects into a collection you can filter by, right here.")
                } else {
                    filterChip(id: "", label: "All", hue: .secondary, cost: nil)
                    ForEach(cachedCollectionRollups) { r in
                        filterChip(
                            id: r.id,
                            label: r.name,
                            hue: pacerCollectionColor(seed: r.colorSeed, hex: r.colorHex),
                            cost: r.totals.cost
                        )
                    }
                    Divider().frame(height: 16).padding(.horizontal, 2)
                    Button(action: onNewCollection) {
                        Image(systemName: "plus")
                    }
                    .pacerDenseControl().buttonStyle(.borderless).help("New collection")
                    Button("Manage", action: onManageCollections)
                        .pacerDenseControl().buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func filterChip(id: String, label: String, hue: Color, cost: Double?) -> some View {
        let active = collectionFilter == id
        return Button {
            collectionFilterBinding.wrappedValue = active ? "" : id
        } label: {
            HStack(spacing: 5) {
                if !id.isEmpty {
                    Circle().fill(hue).frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                if let cost {
                    Text(pacerCost(cost))
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(active ? hue.opacity(0.20) : Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule().stroke(active ? hue.opacity(0.55) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// When a collection is scoped, a slim summary: hue + name + totals +
    /// Edit + clear. The donut and table below are already filtered to it.
    @ViewBuilder
    private var scopeHeader: some View {
        if let r = cachedCollectionRollups.first(where: { $0.id == collectionFilter }) {
            let hue = pacerCollectionColor(seed: r.colorSeed, hex: r.colorHex)
            HStack(spacing: 10) {
                Circle().fill(hue).frame(width: 10, height: 10)
                Text(r.name).font(.system(size: 15, weight: .semibold))
                Text("\(r.memberCount) project\(r.memberCount == 1 ? "" : "s") · \(pacerCost(r.totals.cost)) · \(pacerTokens(r.totals.tokens.all))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit collection") { onEditCollection(r.id) }
                    .pacerDenseControl()
                Button {
                    collectionFilterBinding.wrappedValue = ""
                } label: { Label("All projects", systemImage: "xmark.circle.fill") }
                    .pacerDenseControl().buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hue.opacity(0.08))
            )
        }
    }

    private struct CompositionRow: Identifiable {
        let id: String
        let name: String
        let hue: Color
        let cost: Double
        let share: Double     // fraction of the parent's total
        let isDirect: Bool
    }

    /// When the scoped collection nests others, break its total down by
    /// sub-collection (+ a "directly added" bucket) so nesting carries
    /// proportional meaning, not just bulk-add convenience. Returns nil
    /// when there's nothing to break down.
    private func scopeComposition() -> (rows: [CompositionRow], overlaps: Bool)? {
        guard !collectionFilter.isEmpty,
              let parent = collections.first(where: { $0.id == collectionFilter }),
              !parent.childCollectionIDs.isEmpty else { return nil }
        let byID = collectionsByID
        let perPath = CollectionUsageRollup.perPathTotals(from: aggregates)
        let known = Array(perPath.keys)
        let parentMembers = CollectionResolver.resolve(parent.id, collections: byID, knownPaths: known)
        let parentCost = CollectionUsageRollup.totals(for: parentMembers, perPath: perPath).cost
        guard parentCost > 0 else { return nil }

        var rows: [CompositionRow] = []
        var childUnion: Set<String> = []
        var shareSum = 0.0
        for cid in parent.childCollectionIDs {
            guard let child = byID[cid] else { continue }
            let m = CollectionResolver.resolve(cid, collections: byID, knownPaths: known)
            childUnion.formUnion(m)
            let cost = CollectionUsageRollup.totals(for: m, perPath: perPath).cost
            let share = cost / parentCost
            shareSum += share
            rows.append(CompositionRow(
                id: cid, name: child.name,
                hue: pacerCollectionColor(seed: child.colorSeed, hex: child.colorHex),
                cost: cost, share: share, isDirect: false
            ))
        }
        // Projects that belong to the parent directly (not via any child).
        let directOnly = parentMembers.subtracting(childUnion)
        let directCost = CollectionUsageRollup.totals(for: directOnly, perPath: perPath).cost
        if directCost > 0 {
            rows.append(CompositionRow(
                id: "__direct__", name: "Directly in \(parent.name)",
                hue: .secondary, cost: directCost, share: directCost / parentCost, isDirect: true
            ))
        }
        // Children overlap if their shares plus the direct share exceed 1
        // (a project counted in more than one sub-collection).
        let overlaps = (shareSum + directCost / parentCost) > 1.001
        return (rows.sorted { $0.cost > $1.cost }, overlaps)
    }

    private func compositionCard(_ comp: (rows: [CompositionRow], overlaps: Bool)) -> some View {
        let maxShare = comp.rows.map(\.share).max() ?? 1
        return PacerCard("Made up of") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(comp.rows) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Circle().fill(r.hue).frame(width: 8, height: 8)
                            Text(r.name)
                                .font(.callout)
                                .foregroundStyle(r.isDirect ? .secondary : .primary)
                            Spacer(minLength: 8)
                            Text("\(Int((r.share * 100).rounded()))%")
                                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            Text(pacerCost(r.cost))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                .frame(width: 64, alignment: .trailing)
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(r.hue.opacity(0.55))
                                .frame(width: maxShare > 0 ? geo.size.width * (r.share / maxShare) : 0, height: 5)
                        }
                        .frame(height: 5)
                    }
                }
            }
        } footer: {
            if comp.overlaps {
                Text("Sub-collections share some projects, so their percentages add up to more than 100%.")
            }
        }
    }

    /// Membership provenance for a project row — a small cluster of
    /// collection-colored dots (names on hover), excluding the one
    /// currently scoped. Dots instead of name-pills keep the leaderboard
    /// from getting busy. Scoping is done from the filter bar.
    @ViewBuilder
    private func membershipDots(for path: String) -> some View {
        let ids = (cachedMembership[path] ?? []).filter { $0 != collectionFilter }
        if !ids.isEmpty {
            let names = ids.compactMap { collectionsByID[$0]?.name }
            HStack(spacing: 3) {
                ForEach(ids.prefix(5), id: \.self) { id in
                    if let c = collectionsByID[id] {
                        Circle()
                            .fill(pacerCollectionColor(seed: c.colorSeed, hex: c.colorHex))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .help(names.count == 1 ? "In \(names[0])" : "In \(names.joined(separator: ", "))")
        }
    }

    /// Context-menu submenu to tag a project into a collection (distinct
    /// from the destructive "Merge into…"). A checkmark marks collections
    /// the project already belongs to.
    @ViewBuilder
    private func addToCollectionMenu(for row: ProjectRow) -> some View {
        if row.path != ProjectDailyAggregate.unknownProjectPath {
            Menu("Add to collection") {
                ForEach(collections) { c in
                    let isMember = (cachedMembership[row.path] ?? []).contains(c.id)
                    Button {
                        toggleMembership(row.path, c.id, isMember: isMember)
                    } label: {
                        if isMember {
                            Label(c.name, systemImage: "checkmark")
                        } else {
                            Text(c.name)
                        }
                    }
                }
                Divider()
                Button("New collection…") { onNewCollection() }
            }
        }
    }

    private func toggleMembership(_ path: String, _ collectionID: String, isMember: Bool) {
        guard let c = collections.first(where: { $0.id == collectionID }) else { return }
        if isMember {
            let byID = collectionsByID
            let known = (cachedAllRows ?? []).map(\.path)
            let viaRuleOrChild = CollectionResolver.resolve(collectionID, collections: byID, knownPaths: known)
                .contains(path) && !c.includePaths.contains(path)
            // If it's in via a rule/child, removing the manual include
            // isn't enough — but for the common manual case just drop it.
            CollectionsMutator.removeProject(path, from: c, stillMatchesViaRuleOrChild: viaRuleOrChild)
        } else {
            CollectionsMutator.addProject(path, to: c)
        }
        try? modelContext.save()
        refreshAllRows()
        NotificationCenter.default.post(name: .pacerRequestImmediateScan, object: nil)
    }

}
