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
struct ProjectsView: View {
    @AppStorage("pacer.projects.range", store: PacerSettings.store)
    private var rangeRaw: String = TimeRange.ninetyDays.rawValue

    @AppStorage(PacerSettings.Key.projectsSort, store: PacerSettings.store)
    private var sortRaw: String = ProjectSort.cost.rawValue

    @AppStorage("pacer.projects.sortDescending", store: PacerSettings.store)
    private var sortDescending: Bool = true

    @AppStorage("pacer.projects.overviewMetric", store: PacerSettings.store)
    private var overviewMetricRaw: String = ProjectMetric.cost.rawValue

    /// Active collection scope on the Projects tab — `""` = All projects.
    /// Collections live inline here (a filter bar), not in a separate tab.
    /// Not persisted: scope is a transient browsing choice, and reopening
    /// on "All" is the least surprising default.
    @State private var collectionFilter: String = ""

    /// Optional starting scope (used by the screenshot harness to render a
    /// scoped collection; nil in normal use).
    var initialScope: String? = nil

    @State private var searchText: String = ""
    /// Drives the collections-manager sheet, opened from the lane's
    /// "Manage…" button.
    @State private var showingCollectionsManager = false
    /// When true, the collections manager opens straight into the
    /// new-collection editor (from a "New collection" button) rather than
    /// the plain list (from "Manage…").
    @State private var collectionsManagerStartNew = false
    /// When set, the manager opens straight into this collection's editor
    /// (from a scope-header or chip "Edit" action).
    @State private var editingCollectionID: String?
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
    private var sort: ProjectSort {
        ProjectSort(rawValue: sortRaw) ?? .cost
    }
    private var overviewMetric: ProjectMetric {
        ProjectMetric(rawValue: overviewMetricRaw) ?? .cost
    }

    var body: some View {
        PageScaffold(
            "Projects",
            subtitle: "Per-project rollup of cost and tokens.",
            trailing: { headerControls }
        ) {
            ProjectsContent(
                range: range,
                sort: sort,
                descending: sortDescending,
                overviewMetric: overviewMetric,
                searchText: searchText,
                collectionFilter: collectionFilter,
                rangeBinding: rangeBinding,
                sortFieldBinding: sortFieldBinding,
                sortDescendingBinding: $sortDescending,
                overviewMetricBinding: overviewMetricBinding,
                collectionFilterBinding: $collectionFilter,
                onSelectProject: { path, displayName, since in
                    modalRoot = .project(path: path, displayName: displayName, since: since)
                },
                onNewCollection: {
                    editingCollectionID = nil
                    collectionsManagerStartNew = true
                    showingCollectionsManager = true
                },
                onManageCollections: {
                    editingCollectionID = nil
                    collectionsManagerStartNew = false
                    showingCollectionsManager = true
                },
                onEditCollection: { id in
                    collectionsManagerStartNew = false
                    editingCollectionID = id
                    showingCollectionsManager = true
                }
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
            text: $searchText,
            placement: .toolbar,
            prompt: "Filter projects"
        )
        .sheet(isPresented: $showingAliasManager) {
            ProjectAliasManager()
        }
        .sheet(isPresented: $showingCollectionsManager) {
            CollectionsManager(startNew: collectionsManagerStartNew, editCollectionID: editingCollectionID)
        }
        .pacerModalNavigation(root: $modalRoot)
        .onAppear {
            if let initialScope, collectionFilter.isEmpty { collectionFilter = initialScope }
        }
    }

    /// Tab-level controls in the page header: the alias-manager entry
    /// point and the time-range picker. Both belong to the whole tab —
    /// the range picker scopes the "Top projects" donut AND the table,
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
            .controlSize(.small)
            .help("Manage project aliases — fold renamed folders, sibling worktrees, and cross-machine paths into one project.")
            Picker("Time range", selection: rangeBinding) {
                ForEach(TimeRange.allCases) { r in
                    Text(r.shortLabel).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .controlSize(.small)
            .labelsHidden()
        }
    }

    private var rangeBinding: Binding<TimeRange> {
        Binding(get: { range }, set: { rangeRaw = $0.rawValue })
    }
    private var sortFieldBinding: Binding<ProjectSort> {
        Binding(get: { sort }, set: { sortRaw = $0.rawValue })
    }
    private var overviewMetricBinding: Binding<ProjectMetric> {
        Binding(get: { overviewMetric }, set: { overviewMetricRaw = $0.rawValue })
    }
}

/// What column the Projects table sorts by. The direction is held in
/// a separate `Bool` so users can sort ascending OR descending on any
/// column — both bits are persisted independently.
enum ProjectSort: String, CaseIterable, Identifiable {
    case cost
    case tokens
    case sessions
    case lastActive
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cost:       return "Cost"
        case .tokens:     return "Tokens"
        case .sessions:   return "Sessions"
        case .lastActive: return "Last active"
        case .name:       return "Project"
        }
    }
}

/// Metric a metric-pickable card colors / sizes by. Shared between
/// the top-projects donut card and the heatmap.
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
    @Query private var aggregates: [ProjectDailyAggregate]
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
    let sort: ProjectSort
    let descending: Bool
    let overviewMetric: ProjectMetric
    /// Active collection scope — `""` = All projects.
    let collectionFilter: String

    let rangeBinding: Binding<TimeRange>
    let sortFieldBinding: Binding<ProjectSort>
    let sortDescendingBinding: Binding<Bool>
    let overviewMetricBinding: Binding<ProjectMetric>
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
        sort: ProjectSort,
        descending: Bool,
        overviewMetric: ProjectMetric,
        searchText: String,
        collectionFilter: String,
        rangeBinding: Binding<TimeRange>,
        sortFieldBinding: Binding<ProjectSort>,
        sortDescendingBinding: Binding<Bool>,
        overviewMetricBinding: Binding<ProjectMetric>,
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
        self.sort = sort
        self.descending = descending
        self.overviewMetric = overviewMetric
        self.collectionFilter = collectionFilter
        self.rangeBinding = rangeBinding
        self.sortFieldBinding = sortFieldBinding
        self.sortDescendingBinding = sortDescendingBinding
        self.overviewMetricBinding = overviewMetricBinding
        self.collectionFilterBinding = collectionFilterBinding
        self.onSelectProject = onSelectProject
        self.onNewCollection = onNewCollection
        self.onManageCollections = onManageCollections
        self.onEditCollection = onEditCollection
        if let cutoffString {
            _aggregates = Query(
                filter: #Predicate<ProjectDailyAggregate> { $0.date >= cutoffString }
            )
        } else {
            _aggregates = Query()
        }
    }

    private struct ProjectRow: Identifiable {
        let path: String
        let displayName: String
        let cost: Double
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheReadTokens: Int64
        let totalTokens: Int64
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
    private var allRows: [ProjectRow] {
        cachedAllRows ?? computeAllRowsSync()
    }

    private var mergeCandidates: [ProjectRow] {
        if let cached = cachedMergeCandidates { return cached }
        return allRows.filter { $0.path != ProjectDailyAggregate.unknownProjectPath }
    }

    /// Rebuild the `cachedAllRows` snapshot. Called on appear, on
    /// scan-meta tick, and whenever sort/range changes invalidate the
    /// existing snapshot. O(aggregates) — typically thousands of rows
    /// on a power user's DB; runs at most once per scan cycle now
    /// instead of once per body render.
    private func refreshAllRows() {
        let rows = computeAllRowsSync()
        cachedAllRows = rows
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
            .sorted { $0.totals.cost > $1.totals.cost }
        refreshFilteredRows()
    }

    /// Resolve the active collection scope to its member paths, or nil for
    /// "All". Cheap set-ops; used to filter the displayed rows.
    private func scopeMemberPaths() -> Set<String>? {
        guard !collectionFilter.isEmpty else { return nil }
        return cachedCollectionRollups.first { $0.id == collectionFilter }?.memberPaths
            ?? {
                let byID = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let known = (cachedAllRows ?? []).map(\.path)
                return CollectionResolver.resolve(collectionFilter, collections: byID, knownPaths: known)
            }()
    }

    private func applyScope(_ rows: [ProjectRow]) -> [ProjectRow] {
        guard let members = scopeMemberPaths() else { return rows }
        return rows.filter { members.contains($0.path) }
    }

    /// Pure computation over `aggregates` + `probes` + `sort` +
    /// `descending`. Used both by `refreshAllRows()` (writes to
    /// `@State`) and by the `allRows` fallback when the cache hasn't
    /// landed yet — that's the first render after a `.id(range)`
    /// re-init, before `.onAppear` fires.
    private func computeAllRowsSync() -> [ProjectRow] {
        struct Acc {
            var cost: Double = 0
            var input: Int64 = 0
            var output: Int64 = 0
            var cacheRead: Int64 = 0
            var sessionCount: Int = 0
            var modelCount: Int = 0
            var lastActive: Date = .distantPast
        }
        var byProject: [String: Acc] = [:]
        for r in aggregates {
            var a = byProject[r.projectPath] ?? Acc()
            a.cost += r.totalCostUSD
            a.input += r.inputTokens
            a.output += r.outputTokens
            a.cacheRead += r.cacheReadTokens
            a.sessionCount += r.sessionCount
            a.modelCount += r.modelCount
            if r.lastActive > a.lastActive { a.lastActive = r.lastActive }
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
                cost: a.cost,
                inputTokens: a.input,
                outputTokens: a.output,
                cacheReadTokens: a.cacheRead,
                totalTokens: a.input + a.output + a.cacheRead,
                sessionCount: a.sessionCount,
                lastActive: a.lastActive,
                modelCount: a.modelCount,
                status: status,
                colorSeed: metaByPath[key]?.colorSeed,
                colorHex: metaByPath[key]?.colorHex
            )
        }
        return apply(sort: sort, descending: descending, to: unsorted)
    }

    /// Filter the cached snapshot by the (debounced) search needle.
    /// Cheap — O(cachedAllRows), no per-row recompute — but worth
    /// caching too so view body never does string lowercasing.
    private func refreshFilteredRows() {
        let source = applyScope(cachedAllRows ?? computeAllRowsSync())
        cachedFilteredRows = filter(rows: source, by: debouncedSearch)
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

    private func apply(sort: ProjectSort, descending: Bool, to rows: [ProjectRow]) -> [ProjectRow] {
        // Closures take an `(lhs, rhs)` and return ascending order. We
        // chain a deterministic tiebreaker (path) into every primary
        // comparison so rows with equal primary values don't shuffle
        // when SwiftData refreshes — concretely, before the
        // tiebreaker, all-$0 day-detail / 0-token projects swapped
        // positions on every scan tick.
        let primary: (ProjectRow, ProjectRow) -> Bool
        switch sort {
        case .cost:
            primary = { $0.cost < $1.cost }
        case .tokens:
            primary = { $0.totalTokens < $1.totalTokens }
        case .sessions:
            primary = { $0.sessionCount < $1.sessionCount }
        case .lastActive:
            primary = { $0.lastActive < $1.lastActive }
        case .name:
            primary = { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        let sorted = rows.sorted { lhs, rhs in
            if primary(lhs, rhs) { return true }
            if primary(rhs, lhs) { return false }
            // Deterministic tiebreaker: path (always unique per row).
            return lhs.path < rhs.path
        }
        return descending ? sorted.reversed() : sorted
    }

    /// What the body actually renders. Falls back to a synchronous
    /// filter when the cache hasn't landed yet so the first render
    /// after a `.id(range)` re-init never shows an empty list.
    private var rows: [ProjectRow] {
        if let cached = cachedFilteredRows { return cached }
        return filter(rows: applyScope(allRows), by: debouncedSearch)
    }

    var body: some View {
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
                overviewCard
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
        .onAppear { refreshAllRows() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshAllRows() }
        .onChange(of: rangeSince) { _, _ in refreshAllRows() }
        .onChange(of: sort) { _, _ in refreshAllRows() }
        .onChange(of: descending) { _, _ in refreshAllRows() }
        .onChange(of: collectionFilter) { _, _ in refreshFilteredRows() }
        .onChange(of: collections.count) { _, _ in refreshAllRows() }
        .onChange(of: projectMetas.count) { _, _ in refreshAllRows() }
        // Probe count drives the badge state. Refreshing on count
        // change picks up the very first probe write (first scan
        // after install) plus any churn from the user clearing the
        // probe table to force a re-walk.
        .onChange(of: probes.count) { _, _ in refreshAllRows() }
        // Search debounce: re-filter ~200ms after the last keystroke
        // rather than on every character. Filtering is cheap relative
        // to `refreshAllRows`, so a short debounce is enough.
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

    /// Top-N projects donut + ranking. The metric the donut/legend uses
    /// (cost, tokens, sessions) is user-selectable via segmented picker
    /// in the card header — mirrors the heatmap's metric picker so the
    /// app feels consistent.
    @State private var hoveredOverviewAngle: Double?

    /// Cumulative-angle index over the top-5 rows for the active
    /// metric. Derived synchronously so a Projects-tab mount renders
    /// the donut at its real size on the first frame — the previous
    /// @State + .onAppear pattern showed an empty donut briefly, then
    /// snapped to the populated layout one tick later.
    private var overviewIndex: (cumulative: [(row: ProjectRow, max: Double)], total: Double) {
        let top = Array(rows.prefix(5))
        var running = 0.0
        var built: [(row: ProjectRow, max: Double)] = []
        built.reserveCapacity(top.count)
        for row in top {
            running += value(for: overviewMetric, in: row)
            built.append((row, running))
        }
        return (built, running)
    }

    private func hoveredOverviewProject(cumulative: [(row: ProjectRow, max: Double)]) -> ProjectRow? {
        guard let angle = hoveredOverviewAngle, !cumulative.isEmpty else { return nil }
        for entry in cumulative where angle <= entry.max {
            return entry.row
        }
        return cumulative.last?.row
    }

    private var overviewCard: some View {
        let top = Array(rows.prefix(5))
        let index = overviewIndex
        let totalForMetric = index.total
        let hovered = hoveredOverviewProject(cumulative: index.cumulative)
        return PacerCard("Top projects", trailing: {
            HStack(spacing: 12) {
                if let h = hovered {
                    let v = value(for: overviewMetric, in: h)
                    let pct = totalForMetric > 0 ? Int(v / totalForMetric * 100) : 0
                    HStack(spacing: 6) {
                        Text(h.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(formatMetric(v, kind: overviewMetric))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("(\(pct)%)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Picker("Overview metric", selection: overviewMetricBinding) {
                    ForEach(ProjectMetric.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .controlSize(.small)
                .labelsHidden()
            }
        }) {
            HStack(alignment: .top, spacing: 24) {
                Chart(top) { row in
                    SectorMark(
                        angle: .value("Metric", value(for: overviewMetric, in: row)),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Project", row.displayName))
                    .cornerRadius(2)
                    .opacity(hovered.map { $0.id == row.id ? 1.0 : 0.45 } ?? 1.0)
                }
                .frame(width: 160, height: 160)
                // Pin each project to its stable color so the wedge matches
                // its legend dot (they used to use two unrelated color
                // systems) and doesn't reshuffle when the ranking changes.
                .chartForegroundStyleScale(
                    domain: top.map(\.displayName),
                    range: top.map { pacerProjectColor(path: $0.path, seed: $0.colorSeed, hex: $0.colorHex) }
                )
                .chartLegend(.hidden)
                .chartAngleSelection(value: $hoveredOverviewAngle)
                .accessibilityLabel("Top 5 projects by \(overviewMetric.label)")
                .accessibilityValue(topProjectsSummary(top: top, total: totalForMetric))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(top.enumerated()), id: \.offset) { idx, row in
                        let v = value(for: overviewMetric, in: row)
                        HStack(alignment: .firstTextBaseline) {
                            Circle()
                                .fill(pacerProjectColor(path: row.path, seed: row.colorSeed, hex: row.colorHex))
                                .frame(width: 8, height: 8)
                            Text(row.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: 220, alignment: .leading)
                            Spacer(minLength: 8)
                            Text(formatMetric(v, kind: overviewMetric))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                            if totalForMetric > 0 {
                                Text("\(Int((v / totalForMetric * 100).rounded()))%")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    /// VoiceOver alternative to the donut. Lists each top project with
    /// its share of the active metric, comma-separated.
    private func topProjectsSummary(top: [ProjectRow], total: Double) -> String {
        guard total > 0 else { return "no data yet" }
        return top.map { row in
            let v = value(for: overviewMetric, in: row)
            let pct = Int((v / total * 100).rounded())
            return "\(row.displayName) \(pct) percent"
        }.joined(separator: ", ")
    }

    private func value(for metric: ProjectMetric, in row: ProjectRow) -> Double {
        switch metric {
        case .cost:     return row.cost
        case .tokens:   return Double(row.totalTokens)
        case .sessions: return Double(row.sessionCount)
        }
    }

    private func formatMetric(_ v: Double, kind: ProjectMetric) -> String {
        switch kind {
        case .cost:     return pacerCost(v)
        case .tokens:   return pacerTokens(Int64(v))
        case .sessions: return "\(Int(v))"
        }
    }

    /// Big project list with sortable column headers. The time-range
    /// picker and the alias-manager entry point used to live in this
    /// card header; both moved to the page header (`headerControls`) once
    /// the range was understood to scope the whole tab (donut + list),
    /// not just this card. Bulk merge is now reached from the alias
    /// manager's "Merge multiple…" button; per-row merges stay on the
    /// row context menu below.
    ///
    /// The text filter lives in the window toolbar via `.searchable` on
    /// the parent view — the native macOS search field (system clear
    /// button, accessibility label, placement consistency with Mail /
    /// Finder / Notes).
    private var projectListCard: some View {
        PacerCard("All projects") {
            // `LazyVStack` around the row `ForEach` so that on a project
            // list of any size the cards below the card-bottom (and
            // below the viewport) aren't realized. Each row carries a
            // `HoverRow` (`.onHover` listener) and a `.contextMenu`
            // whose body is built at row-construction time — for a
            // user with 50+ projects, every scroll-induced re-eval was
            // building 50+ context menus eagerly. With this lazy
            // boundary, only the rows the user can actually see are
            // built and laid out.
            VStack(alignment: .leading, spacing: 0) {
                tableHeader
                Divider().padding(.vertical, 4)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HoverRow(action: {
                            onSelectProject(row.path, row.displayName, rangeSince)
                        }) {
                            projectRow(row)
                        }
                        .contextMenu {
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
                    }
                }
                HStack {
                    Text("\(rows.count) project\(rows.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
    }

    /// Column headers double as sort controls. Click an inactive column
    /// to make it the sort field; click the active column to flip
    /// direction. Visual: tracked uppercase label + a small chevron on
    /// the active column.
    private var tableHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            SortableColumnHeader(
                "Project",
                field: ProjectSort.name,
                alignment: .leading,
                active: sortFieldBinding,
                descending: sortDescendingBinding,
                defaultDescending: false
            )
            .padding(.leading, 8)

            Spacer()

            SortableColumnHeader(
                "Tokens",
                field: ProjectSort.tokens,
                alignment: .trailing,
                active: sortFieldBinding,
                descending: sortDescendingBinding
            ).frame(width: 100)
            SortableColumnHeader(
                "Sessions",
                field: ProjectSort.sessions,
                alignment: .trailing,
                active: sortFieldBinding,
                descending: sortDescendingBinding
            ).frame(width: 70)
            SortableColumnHeader(
                "Last",
                field: ProjectSort.lastActive,
                alignment: .trailing,
                active: sortFieldBinding,
                descending: sortDescendingBinding
            ).frame(width: 90)
            SortableColumnHeader(
                "Cost",
                field: ProjectSort.cost,
                alignment: .trailing,
                active: sortFieldBinding,
                descending: sortDescendingBinding
            ).frame(width: 84)
        }
        .padding(.trailing, 8)
        .padding(.bottom, 4)
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
                    .controlSize(.small)
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
                    .controlSize(.small).buttonStyle(.borderless).help("New collection")
                    Button("Manage", action: onManageCollections)
                        .controlSize(.small).buttonStyle(.borderless)
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
                Text("\(r.memberCount) project\(r.memberCount == 1 ? "" : "s") · \(pacerCost(r.totals.cost)) · \(pacerTokens(r.totals.totalTokens))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit collection") { onEditCollection(r.id) }
                    .controlSize(.small)
                Button {
                    collectionFilterBinding.wrappedValue = ""
                } label: { Label("All projects", systemImage: "xmark.circle.fill") }
                    .controlSize(.small).buttonStyle(.borderless)
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

    @ViewBuilder
    private func projectRow(_ row: ProjectRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    ProjectStatusBadge(state: row.status)
                    membershipDots(for: row.path)
                }
                Text(row.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(pacerTokens(row.totalTokens)).help(pacerTokensExact(row.totalTokens))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)
            Text("\(row.sessionCount)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(pacerRelative(row.lastActive))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(pacerCost(row.cost)).help(pacerCostExact(row.cost))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
    }

}
