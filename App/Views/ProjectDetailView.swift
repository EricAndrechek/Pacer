import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

// Sort enum was forked into the shared SessionsTable component; this
// view now reuses `SessionsTableSort` directly.

/// Drill-down for a single project. Presented as a sheet from
/// `ProjectsView`. Shows:
///   - Cost / tokens summary headline
///   - Daily-cost mini-chart over the visible range
///   - Models-used pie chart
///   - Recent sessions list (sessionId, last seen, model)
///
/// Reads `ProjectDailyAggregate` and `SessionInfo` directly — both are
/// precomputed by the in-process scan's recomputers, so the view never
/// iterates raw `TokenSample`s.
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
    /// Probe row for this project, if any. Drives the status badge
    /// under the modal subtitle. Scoped via `init` so SwiftData
    /// only fetches the one row we care about (path-keyed unique).
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
    /// Scan-completion trigger. The detail view doesn't subscribe to
    /// the meta probe because the modal lifecycle is short and we
    /// already refresh on `aggregates` change — but caching the
    /// expensive computed properties below still pays off on chart
    /// hover, range filter, and other in-modal re-renders.

    /// Cached output of the per-row `JSONDecoder` walk that builds
    /// `modelSlices`. The previous computed-property version decoded
    /// two JSON blobs per `ProjectDailyAggregate` row (one for tokens,
    /// one for costs) on every body render — and any chart hover or
    /// state change re-evaluates the body. With ~90 rows per project
    /// that's 180 decoder allocations per hover tick.
    @State private var cachedModelSlices: [ModelSlice] = []
    /// The daily chart's bars, each with its breakdown and top models (by
    /// cost, from `modelCostJSON`) precomputed for the hover card, so a
    /// hover reads them rather than decoding anything.
    @State private var cachedDailySeries: [PacerChartBucket] = []
    /// Cached totals. The summary tile-grid reads from this; the
    /// previous version walked every aggregate on every render.
    @State private var cachedTotals = Totals()
    /// The project's cost by priced part over the range (#225), summed in
    /// the same pass as the totals so it follows the same rows.
    @State private var cachedBreakdown = CostBreakdown.zero
    /// Bucket sums keyed by `originalProjectPath`. Computed in one
    /// pass over the fetched samples, same shape as the other cached
    /// derivations. Empty / one-element when there's no drill-down
    /// to show.
    @State private var cachedSubprojects: [SubprojectRow] = []
    /// One Subprojects load at a time; a trigger that lands while one is
    /// running sets `subprojectsRerun` and gets one more load afterwards.
    /// Cancelling is not an option: the load is a detached task, which is not
    /// cancelled with its parent, so "cancel and restart" left every
    /// superseded fetch running — overlapping raw-sample reads on a busy
    /// project, all competing with the scan for the store.
    @State private var subprojectsLoading = false
    @State private var subprojectsRerun = false
    @State private var subprojectsClosed = false
    /// Cost mode. Reactive @AppStorage so the Subprojects card
    /// re-buckets immediately when the user toggles modes in
    /// Settings (same pattern NowStrip uses).
    @AppStorage(PacerSettings.Key.costMode, store: PacerSettings.store)
    private var costModeRaw: String = CostMode.auto.rawValue

    /// Budget row for this project — at most one, by `@Attribute(.unique)`
    /// on `ProjectBudget.projectPath`. fetchLimit isn't necessary
    /// because the predicate is path-keyed unique.
    @Query private var budgetRows: [ProjectBudget]

    /// The account the modal is scoped to, when it is — the Subprojects load
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

    /// The shared project fold (#215): the Projects list and Day detail sum
    /// a project's rows through the same `ProjectUsageTotals`, so all three
    /// give the same tokens for the same range.
    private typealias Totals = ProjectUsageTotals

    private var totals: Totals { cachedTotals }

    private var dailySeries: [PacerChartBucket] { cachedDailySeries }

    private struct ModelSlice: Identifiable {
        let model: String
        let tokens: Int64
        let cost: Double
        var id: String { model }
    }

    private var modelSlices: [ModelSlice] { cachedModelSlices }

    /// One bucket of the Subprojects card. Built by walking
    /// `samples` once and grouping on `originalProjectPath` — what
    /// the JSONL's cwd was BEFORE worktree-strip/alias rewriting,
    /// preserved on `TokenSample` exactly so we can drill back down.
    struct SubprojectRow: Identifiable, Sendable {
        /// The original cwd verbatim — used to bucket and as the
        /// stable id.
        let originalPath: String
        /// Path relative to the canonical project root, e.g.
        /// `local/potato`. Empty string for samples whose original
        /// path IS the canonical (runs at repo root, or legacy
        /// samples backfilled to canonical).
        let relativeSubpath: String
        let totalTokens: Int64
        let cost: Double
        let sessionCount: Int
        var id: String { originalPath }
    }

    private var subprojects: [SubprojectRow] { cachedSubprojects }

    /// Single derivation pass over `aggregates`. Builds totals,
    /// daily series, and model slices in one shot rather than three
    /// separate computed-property walks. Reuses one `JSONDecoder` for
    /// the entire pass instead of allocating per row.
    private func refreshDerived() {
        let t = Totals(rows: aggregates)
        var breakdown = CostBreakdown.zero
        var byModel: [String: (tokens: Int64, cost: Double)] = [:]
        var days = PacerChartBucketBuilder()
        let decoder = JSONDecoder()
        for r in aggregates {
            breakdown += r.costBreakdown
            // Decoded once per row, for the chart's per-day top models and
            // the Models card's per-model cost below.
            let costs = (try? decoder.decode([String: Double].self, from: r.modelCostJSON)) ?? [:]
            days.add(r.date, r.costBreakdown, modelCosts: costs)
            // Uncached (input + output) per model: all the stored side-table
            // holds, so the Models card says so (#215).
            if let tokens = try? decoder.decode([String: Int64].self, from: r.modelTokensJSON) {
                for (model, tok) in tokens {
                    byModel[model, default: (0, 0)].tokens += tok
                }
            }
            for (model, c) in costs {
                byModel[model, default: (0, 0)].cost += c
            }
        }
        cachedTotals = t
        cachedBreakdown = breakdown
        // The builder orders by date rather than leaning on the
        // `@Query(sort:)` staying put — the band-date chart that plots this
        // needs a chronological x-domain (same invariant as the Models trend).
        cachedDailySeries = days.buckets()
        cachedModelSlices = byModel.map { (model, v) in
            ModelSlice(model: model, tokens: v.tokens, cost: v.cost)
        }.sorted { $0.tokens > $1.tokens }
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

    /// Bucket `TokenSample`s for this project by `originalProjectPath`
    /// to build the Subprojects card. Cost uses the shared
    /// `effectiveCostUSD(mode:)` helper — same path
    /// `ProjectDailyAggregate.totalCostUSD` follows — so subprojects
    /// don't undercount when Claude Code didn't write `sourceCostUSD`
    /// on the JSONL line (older builds, some entry types). Without
    /// this every row of a `calculate`-mode user reads as $0.
    ///
    /// Why a manual fetch instead of `@Query`: a `@Query` for samples
    /// was the cause of a freeze-the-whole-modal bug. SwiftData's
    /// @Query for TokenSample re-fetched and decoded the full result
    /// set on every body access (`samples.getter` was 67% of
    /// main-thread time in a `sample` trace), and the modal's body
    /// re-evaluates on every scan-cycle save (~2s) via the other
    /// @Query bindings. A manual fetch driven by `.onAppear`,
    /// aggregate count changes, the cost-mode setting, and the
    /// `pacerScanCycleDidComplete` notification gives the same live-
    /// update behavior with zero per-render cost.
    ///
    /// Off the main actor, in its own `ModelContext`. This is the one read
    /// in the app that materializes raw samples, and a busy project over
    /// 90 days is tens of thousands of them: done on the main context it
    /// was the largest main-thread cost in a `sample` of the live app, run
    /// once as the modal opened (the click that "does nothing" for a
    /// second, then lands with every queued click behind it) and again on
    /// every scan cycle while the modal stayed open.
    private func refreshSubprojects() {
        guard !subprojectsClosed else { return }
        guard !subprojectsLoading else {
            subprojectsRerun = true
            return
        }
        subprojectsLoading = true
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
            let rows = await Task.detached(priority: .userInitiated) {
                Self.loadSubprojects(container: container, projectPath: path,
                                     since: since, accountId: account, mode: mode)
            }.value
            subprojectsLoading = false
            guard !subprojectsClosed else { return }
            cachedSubprojects = rows
            if subprojectsRerun {
                subprojectsRerun = false
                refreshSubprojects()
            }
        }
    }

    private nonisolated static func loadSubprojects(
        container: ModelContainer, projectPath: String, since: Date?,
        accountId: String?, mode: CostMode
    ) -> [SubprojectRow] {
        struct Acc {
            var tokens: Int64 = 0
            var cost: Double = 0
            var sessions: Set<String> = []
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
            // Priced at the rate in effect when each turn was made.
            \.sampledAt,
        ]
        let samples = (try? context.fetch(sampleDesc)) ?? []
        // What `TokenSample.effectiveCostUSD(mode:)` computes, which is
        // main-actor only; the snapshot it reads is not, so read it once.
        let pricing = SampleCostCache.current()
        var byPath: [String: Acc] = [:]
        for s in samples {
            // Fall back to the canonical when originalProjectPath
            // is nil (rows inserted before the field existed and
            // missed the migration somehow). This keeps them
            // counted instead of silently dropped — they just
            // bucket under the canonical's "root" row.
            let key = s.originalProjectPath ?? projectPath
            var a = byPath[key] ?? Acc()
            a.tokens += s.breakdown.all
            a.cost += CostCalculator.cost(s, mode: mode, snapshot: pricing)
            if let sid = s.sessionId, !sid.isEmpty { a.sessions.insert(sid) }
            byPath[key] = a
        }
        let rows: [SubprojectRow] = byPath.map { (key, a) in
            SubprojectRow(
                originalPath: key,
                relativeSubpath: relativeSubpath(canonical: projectPath, from: key),
                totalTokens: a.tokens,
                cost: a.cost,
                sessionCount: a.sessions.count
            )
        }
        // Highest-cost subdir first — matches the natural "what did
        // I spend my budget on" reading order. Stable tiebreaker on
        // path so a re-derivation doesn't shuffle equal-cost rows.
        return rows.sorted { lhs, rhs in
            if lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.originalPath < rhs.originalPath
        }
    }

    /// Trim the canonical project's prefix off a sample's original
    /// path. `/Users/.../support-infra/local/potato` → `local/potato`
    /// when called with canonical `/Users/.../support-infra`. Empty
    /// string when the paths are equal (sample was taken at repo
    /// root, not a subdir).
    private nonisolated static func relativeSubpath(canonical: String, from descendant: String) -> String {
        guard canonical != descendant else { return "" }
        let normalizedCanon = canonical.hasSuffix("/") ? String(canonical.dropLast()) : canonical
        let prefix = normalizedCanon + "/"
        if descendant.hasPrefix(prefix) {
            return String(descendant.dropFirst(prefix.count))
        }
        // Doesn't share the canonical's prefix — fall back to the
        // path's basename so the user has something readable.
        return (descendant as NSString).lastPathComponent
    }

    var body: some View {
        // Every cache the cards draw from, read here in this view's own body.
        // The cards read them inside `PacerModalContent`'s stored content
        // closure, and a read there may not make this view depend on them,
        // which is the shape of the modal bug #150 fixed. Subprojects most of
        // all: it fills in asynchronously, after the modal is on screen, and
        // the other three now change while it's open (#145). (#140)
        let _ = (cachedTotals, cachedBreakdown, cachedDailySeries, cachedModelSlices, cachedSubprojects)
        // Presentation state, read here so setting it redraws this view and
        // what it presents opens at once. Passed only as a binding, nothing
        // read it: the collections sheet opened only after an unrelated
        // redraw, seconds later (#140; AGENTS.md, "SwiftUI state and data flow").
        let _ = (bulkMergeDraft?.id, mergeError)
        // The Sessions sort reaches its table only as bindings; read here so
        // clicking a header re-sorts at once.
        let _ = (sessionsSortRaw, sessionsSortDescending)
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
            // Status badge — same shape as the Projects-list pill.
            // Sits above the summary card so the user sees "git /
            // on-disk / missing" at the same glance as the cost
            // headline. Lightweight (one HStack, one badge) so it
            // doesn't compete with the cards below.
            HStack(spacing: 6) {
                ProjectStatusBadge(state: detailStatus)
                Spacer()
            }
            summaryCard
            if PacerCostBreakdownView.hasContent(cachedBreakdown) { breakdownCard }
            budgetCard
            if !dailySeries.isEmpty { dailyChartCard }
            // Subprojects card lands between the daily chart and the
            // model breakdown — it's a structural break-out ("what
            // parts of this project ate the budget") so it reads
            // naturally between "when did I work" and "with which
            // model." Hidden when there's only one bucket (no
            // drill-down value).
            if subprojects.count > 1 { subprojectsCard }
            if !modelSlices.isEmpty { modelsCard }
            if !sessionRows.isEmpty { sessionsCard }
        }
        .onAppear {
            refreshDerived()
            refreshSubprojects()
            refreshKnownProjectPaths()
        }
        // Totals, daily series and model slices follow the rows they are
        // built from. See `aggregatesFingerprint`.
        .onChange(of: aggregatesFingerprint) { _, _ in refreshDerived() }
        // The scope picks which table `aggregates` reads (so the fingerprint
        // follows it) and filters Subprojects, which needs telling. It only
        // refreshed on a scope switch because the switch usually changed the
        // row count and `refreshDerived` used to chain into it.
        .onChange(of: scope.accountId) { _, _ in refreshSubprojects() }
        // Live updates within an existing day: the scan coordinator
        // posts `pacerScanCycleDidComplete` whenever a cycle actually
        // wrote new data. Filter to cycles that touched samples or
        // re-attributed projects — rate-limit-only cycles don't
        // change the Subprojects card. Subprojects needs this explicit
        // refresh because its source (raw TokenSample) is not a @Query
        // (see refreshSubprojects); the rollup-backed cards follow
        // `aggregatesFingerprint`.
        .onReceive(NotificationCenter.default.publisher(
            for: .pacerScanCycleDidComplete
        )) { note in
            guard let summary = note.object as? ScanCycleSummary else { return }
            if summary.samplesChanged || summary.projectAttributionChanged {
                refreshSubprojects()
            }
            if summary.projectAttributionChanged { refreshKnownProjectPaths() }
        }
        // Cost-mode toggle in Settings must re-bucket the
        // Subprojects card — `effectiveCostUSD(mode:)` flips between
        // stored / calculated / auto fallbacks.
        .onChange(of: costModeRaw) { _, _ in refreshSubprojects() }
        .onDisappear { subprojectsClosed = true }
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
            Text("Existing samples for \(pacerShortPath(projectPath)) will be re-attributed to \(pacerShortPath(target)) on the next scan cycle. You can undo from Settings → Project Aliases.")
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

    private var summaryCard: some View {
        let t = totals
        return PacerCard("Summary") {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                    count: 5
                ),
                alignment: .leading,
                spacing: 12
            ) {
                MetricTile(
                    value: pacerCost(t.cost), label: "cost", size: .hero,
                    tooltip: pacerCostExact(t.cost)
                )
                MetricTile(
                    value: pacerTokens(t.tokens.inputTokens), label: "input",
                    tooltip: pacerTokensExact(t.tokens.inputTokens)
                )
                MetricTile(
                    value: pacerTokens(t.tokens.outputTokens), label: "output",
                    tooltip: pacerTokensExact(t.tokens.outputTokens)
                )
                MetricTile(
                    value: pacerTokens(t.tokens.cacheReadTokens), label: "cache read",
                    tooltip: pacerTokensExact(t.tokens.cacheReadTokens)
                )
                MetricTile(value: "\(aggregates.count)", label: "active days")
            }
        }
    }

    /// Which of the five priced parts made up the project's cost over the
    /// range (#225) — the shared `PacerCostBreakdownView`, the same one Day
    /// detail and the Models tab use.
    private var breakdownCard: some View {
        PacerCard("Cost breakdown") {
            PacerCostBreakdownView(cachedBreakdown)
        }
    }

    // MARK: - Subprojects card

    private var subprojectsCard: some View {
        let totalTokens = subprojects.reduce(Int64(0)) { $0 + $1.totalTokens }
        return PacerCard("Subprojects", trailing: {
            Text("\(subprojects.count) sub-paths")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }) {
            VStack(alignment: .leading, spacing: 6) {
                subprojectsHeader
                Divider().padding(.vertical, 2)
                ForEach(subprojects) { row in
                    subprojectRow(row, totalTokens: totalTokens)
                }
            }
        } footer: {
            Text("Sub-paths come from each sample's original cwd (before alias/worktree canonicalization). Cost shown is what Claude Code reported in the JSONL — historical lines without a stored cost contribute $0 here.")
        }
    }

    private var subprojectsHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Eyebrow(text: "Subpath")
                .frame(maxWidth: .infinity, alignment: .leading)
            Eyebrow(text: "Tokens")
                .frame(width: 100, alignment: .trailing)
            Eyebrow(text: "Sessions")
                .frame(width: 70, alignment: .trailing)
            Eyebrow(text: "Cost")
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func subprojectRow(_ row: SubprojectRow, totalTokens: Int64) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                // Empty `relativeSubpath` means "samples taken at
                // the repo root, not a subdir" — label it
                // explicitly so a (root) row reads as
                // intentional, not as a missing field.
                Text(row.relativeSubpath.isEmpty ? "(root)" : row.relativeSubpath)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(row.originalPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(pacerTokens(row.totalTokens)).help(pacerTokensExact(row.totalTokens))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if totalTokens > 0 {
                    Text("\(Int((Double(row.totalTokens) / Double(totalTokens) * 100).rounded()))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .frame(width: 100, alignment: .trailing)
            Text("\(row.sessionCount)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(pacerCost(row.cost)).help(pacerCostExact(row.cost))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }

    /// The project's cost per active day, stacked by part — the shared
    /// `PacerStackedPartChart`, with the same hover card as every cost chart.
    /// Its top models are by cost, from the rollup's `modelCostJSON`.
    /// Clicking a bar opens that day.
    private var dailyChartCard: some View {
        PacerCard("Daily activity") {
            PacerStackedPartChart(dailySeries, kind: .day, onTap: { date in
                push(.day(date: date))
            })
            .accessibilityLabel("Daily cost for \(displayName)")
            .accessibilityHint("Click a bar to drill into that day")
        }
    }

    @State private var hoveredModelAngle: Double?

    /// VoiceOver alternative to the model donut — per-model token share
    /// read as a comma list.
    private func modelSlicesSummary(total: Int64) -> String {
        guard total > 0 else { return "no data" }
        return modelSlices.prefix(5).map { m in
            let pct = Int(Double(m.tokens) / Double(total) * 100)
            return "\(pacerModelDisplayName(m.model)) \(pct) percent"
        }.joined(separator: ", ")
    }

    private var hoveredModelSlice: ModelSlice? {
        guard let angle = hoveredModelAngle, !modelSlices.isEmpty else { return nil }
        var cumulative = 0.0
        for slice in modelSlices {
            cumulative += Double(slice.tokens)
            if angle <= cumulative { return slice }
        }
        return modelSlices.last
    }

    private var modelsCard: some View {
        let total = modelSlices.reduce(Int64(0)) { $0 + $1.tokens }
        return PacerCard("Uncached tokens by model", trailing: {
            if let m = hoveredModelSlice {
                let pct = total > 0 ? Int(Double(m.tokens) / Double(total) * 100) : 0
                HStack(spacing: 6) {
                    Text(pacerModelDisplayName(m.model))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(pacerTokens(m.tokens)).help("\(pacerTokensExact(m.tokens)) uncached tokens")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("(\(pct)%)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }) {
            HStack(alignment: .top, spacing: 24) {
                PacerDonut(
                    slices: modelSlices.map {
                        PacerDonutSlice(id: pacerShortModel($0.model), value: Double($0.tokens),
                                        color: pacerModelColor($0.model))
                    },
                    hoveredID: hoveredModelSlice.map { pacerShortModel($0.model) },
                    hoveredAngle: $hoveredModelAngle,
                    accessibilityLabel: "Uncached token share by model for \(displayName)",
                    accessibilityValue: modelSlicesSummary(total: total)
                )
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(modelSlices) { m in
                        PacerDonutLegendRow(
                            color: pacerModelColor(m.model),
                            label: pacerModelDisplayName(m.model)
                        ) {
                            Text(pacerTokens(m.tokens)).help("\(pacerTokensExact(m.tokens)) uncached tokens")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            if total > 0 {
                                Text("\(Int(Double(m.tokens) / Double(total) * 100))%")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    @AppStorage("pacer.projectDetail.sessionsSortField", store: PacerSettings.store)
    private var sessionsSortRaw: String = SessionsTableSort.lastSeen.rawValue
    @AppStorage("pacer.projectDetail.sessionsSortDescending", store: PacerSettings.store)
    private var sessionsSortDescending: Bool = true

    private var sessionsSort: SessionsTableSort {
        SessionsTableSort(rawValue: sessionsSortRaw) ?? .lastSeen
    }
    private var sessionsSortBinding: Binding<SessionsTableSort> {
        Binding(get: { sessionsSort }, set: { sessionsSortRaw = $0.rawValue })
    }

    private var sessionsCard: some View {
        PacerCard("Sessions", trailing: {
            Text("\(sessionRows.count) total")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }) {
            // Single shared sortable table. Project-detail hides the
            // "Project" column since the modal is already scoped to
            // one project; day-detail enables the same column.
            SessionsTable(
                rows: sessionRows,
                showProjectColumn: false,
                sort: sessionsSortBinding,
                sortDescending: $sessionsSortDescending,
                onSessionTap: { session in
                    push(.session(
                        sessionId: session.sessionId,
                        projectDisplayName: displayName
                    ))
                }
            )
        }
    }
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
