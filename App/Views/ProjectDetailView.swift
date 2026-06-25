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
    @Query private var aggregates: [ProjectDailyAggregate]
    @Query private var sessionRows: [SessionInfo]
    /// Probe row for this project, if any. Drives the status badge
    /// under the modal subtitle. Scoped via `init` so SwiftData
    /// only fetches the one row we care about (path-keyed unique).
    @Query private var probesForThisProject: [ProjectPathProbe]
    /// Every project path Pacer has seen — drives the "Merge this
    /// into…" submenu. Light because we only fetch `projectPath`
    /// from the rollup, not the wide aggregate columns.
    @Query private var allProjectAggregates: [ProjectDailyAggregate]

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
    /// Cached output of the per-row `.map` that builds the chart's
    /// daily series. Cheap to compute, but cached for the same
    /// reason — avoids redundant work on chart hover.
    @State private var cachedDailySeries: [DayPoint] = []
    /// Cached totals. The summary tile-grid reads from this; the
    /// previous version walked every aggregate on every render.
    @State private var cachedTotals = Totals()
    /// Bucket sums keyed by `originalProjectPath`. Computed in one
    /// pass over the fetched samples, same shape as the other cached
    /// derivations. Empty / one-element when there's no drill-down
    /// to show.
    @State private var cachedSubprojects: [SubprojectRow] = []
    /// Cost mode. Reactive @AppStorage so the Subprojects card
    /// re-buckets immediately when the user toggles modes in
    /// Settings (same pattern NowStrip uses).
    @AppStorage(PacerSettings.Key.costMode, store: PacerSettings.store)
    private var costModeRaw: String = CostMode.auto.rawValue

    /// Budget row for this project — at most one, by `@Attribute(.unique)`
    /// on `ProjectBudget.projectPath`. fetchLimit isn't necessary
    /// because the predicate is path-keyed unique.
    @Query private var budgetRows: [ProjectBudget]

    init(projectPath: String, displayName: String, since: Date?) {
        self.projectPath = projectPath
        self.displayName = displayName
        self.since = since
        let path = projectPath
        _budgetRows = Query(
            filter: #Predicate<ProjectBudget> { $0.projectPath == path }
        )
        if let cutoffDate = since {
            let cutoffString = TokenSample.formatDate(cutoffDate)
            _aggregates = Query(
                filter: #Predicate<ProjectDailyAggregate> {
                    $0.projectPath == path && $0.date >= cutoffString
                },
                sort: \.date
            )
            _sessionRows = Query(
                filter: #Predicate<SessionInfo> {
                    $0.projectPath == path && $0.lastSeenAt >= cutoffDate
                },
                sort: \.lastSeenAt,
                order: .reverse
            )
        } else {
            _aggregates = Query(
                filter: #Predicate<ProjectDailyAggregate> { $0.projectPath == path },
                sort: \.date
            )
            _sessionRows = Query(
                filter: #Predicate<SessionInfo> { $0.projectPath == path },
                sort: \.lastSeenAt,
                order: .reverse
            )
        }
        // The "all project paths" query for the merge submenu: only
        // need projectPath. Without `propertiesToFetch` SwiftData
        // would materialize every JSON-blob column on every row.
        var allDesc = FetchDescriptor<ProjectDailyAggregate>()
        allDesc.propertiesToFetch = [\ProjectDailyAggregate.projectPath]
        _allProjectAggregates = Query(allDesc)
        // Probe row scoped to this project. Predicate filter keeps
        // SwiftData from materializing the whole probe table on
        // every save — we just need the one row.
        _probesForThisProject = Query(
            filter: #Predicate<ProjectPathProbe> { $0.path == path }
        )
    }

    private struct Totals {
        var cost: Double = 0
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
    }

    private var totals: Totals { cachedTotals }

    private struct DayPoint: Identifiable {
        let date: String
        let cost: Double
        let tokens: Int64
        var id: String { date }
    }

    private var dailySeries: [DayPoint] { cachedDailySeries }

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
    struct SubprojectRow: Identifiable {
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
        var t = Totals()
        var byModel: [String: (tokens: Int64, cost: Double)] = [:]
        var days: [DayPoint] = []
        days.reserveCapacity(aggregates.count)
        let decoder = JSONDecoder()
        for r in aggregates {
            t.cost += r.totalCostUSD
            t.input += r.inputTokens
            t.output += r.outputTokens
            t.cacheRead += r.cacheReadTokens
            days.append(DayPoint(
                date: r.date,
                cost: r.totalCostUSD,
                tokens: r.inputTokens + r.outputTokens
            ))
            if let tokens = try? decoder.decode([String: Int64].self, from: r.modelTokensJSON) {
                for (model, tok) in tokens {
                    byModel[model, default: (0, 0)].tokens += tok
                }
            }
            if let costs = try? decoder.decode([String: Double].self, from: r.modelCostJSON) {
                for (model, c) in costs {
                    byModel[model, default: (0, 0)].cost += c
                }
            }
        }
        cachedTotals = t
        cachedDailySeries = days
        cachedModelSlices = byModel.map { (model, v) in
            ModelSlice(model: model, tokens: v.tokens, cost: v.cost)
        }.sorted { $0.tokens > $1.tokens }
        refreshSubprojects()
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
    private func refreshSubprojects() {
        struct Acc {
            var tokens: Int64 = 0
            var cost: Double = 0
            var sessions: Set<String> = []
        }
        let path = projectPath
        var sampleDesc: FetchDescriptor<TokenSample>
        if let cutoffDate = since {
            let cutoffString = TokenSample.formatDate(cutoffDate)
            sampleDesc = FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> {
                    $0.projectPath == path && $0.date >= cutoffString
                }
            )
        } else {
            sampleDesc = FetchDescriptor<TokenSample>(
                predicate: #Predicate<TokenSample> { $0.projectPath == path }
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
        ]
        let samples = (try? modelContext.fetch(sampleDesc)) ?? []
        let mode = CostMode(rawValue: costModeRaw) ?? .auto
        var byPath: [String: Acc] = [:]
        for s in samples {
            // Fall back to the canonical when originalProjectPath
            // is nil (rows inserted before the field existed and
            // missed the migration somehow). This keeps them
            // counted instead of silently dropped — they just
            // bucket under the canonical's "root" row.
            let key = s.originalProjectPath ?? projectPath
            var a = byPath[key] ?? Acc()
            a.tokens += s.inputTokens + s.outputTokens
            a.cost += s.effectiveCostUSD(mode: mode)
            if let sid = s.sessionId, !sid.isEmpty { a.sessions.insert(sid) }
            byPath[key] = a
        }
        let canonicalPrefix = projectPath
        let rows: [SubprojectRow] = byPath.map { (key, a) in
            let rel = relativeSubpath(canonical: canonicalPrefix, from: key)
            return SubprojectRow(
                originalPath: key,
                relativeSubpath: rel,
                totalTokens: a.tokens,
                cost: a.cost,
                sessionCount: a.sessions.count
            )
        }
        // Highest-cost subdir first — matches the natural "what did
        // I spend my budget on" reading order. Stable tiebreaker on
        // path so a re-derivation doesn't shuffle equal-cost rows.
        cachedSubprojects = rows.sorted { lhs, rhs in
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
    private func relativeSubpath(canonical: String, from descendant: String) -> String {
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
        .onAppear { refreshDerived() }
        // `aggregates.count` ticks on the FIRST sample of a new day
        // for this project; refreshDerived() recomputes
        // dailySeries / modelSlices / totals from the @Query result
        // and chains into refreshSubprojects().
        .onChange(of: aggregates.count) { _, _ in refreshDerived() }
        // Live updates within an existing day: the scan coordinator
        // posts `pacerScanCycleDidComplete` whenever a cycle actually
        // wrote new data. Filter to cycles that touched samples or
        // re-attributed projects — rate-limit-only cycles don't
        // change the Subprojects card. The aggregates @Query handles
        // its own re-fetch; only Subprojects needs the explicit
        // refresh because its source (raw TokenSample) is no longer
        // a @Query (see refreshSubprojects).
        .onReceive(NotificationCenter.default.publisher(
            for: .pacerScanCycleDidComplete
        )) { note in
            guard let summary = note.object as? ScanCycleSummary else { return }
            if summary.samplesChanged || summary.projectAttributionChanged {
                refreshSubprojects()
            }
        }
        // Cost-mode toggle in Settings must re-bucket the
        // Subprojects card — `effectiveCostUSD(mode:)` flips between
        // stored / calculated / auto fallbacks.
        .onChange(of: costModeRaw) { _, _ in refreshSubprojects() }
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
    /// (no folder behind it) and the current project (can't merge
    /// into yourself).
    private var knownProjectPathsForBulkMerge: [String] {
        var set: Set<String> = []
        for agg in allProjectAggregates {
            if agg.projectPath != ProjectDailyAggregate.unknownProjectPath {
                set.insert(agg.projectPath)
            }
        }
        return set.sorted()
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
                    value: pacerTokens(t.input), label: "input",
                    tooltip: pacerTokensExact(t.input)
                )
                MetricTile(
                    value: pacerTokens(t.output), label: "output",
                    tooltip: pacerTokensExact(t.output)
                )
                MetricTile(
                    value: pacerTokens(t.cacheRead), label: "cache read",
                    tooltip: pacerTokensExact(t.cacheRead)
                )
                MetricTile(value: "\(aggregates.count)", label: "active days")
            }
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

    /// Debounced hover (chart RuleMark + reads). Updated from
    /// `rawHoveredDate` only once the pointer settles, so a scroll sweeping
    /// the bars doesn't re-lay-out the chart per pointer event. See
    /// docs/perf-tuning.md.
    @State private var hoveredDate: String?
    /// Raw `chartXSelection` binding (immediate); feeds the debounce + tap.
    @State private var rawHoveredDate: String?
    @State private var hoveredDateDebounce: Task<Void, Never>?

    private var dailyChartCard: some View {
        PacerCard("Daily activity", trailing: {
            // Hover swaps the trailing slot to show the selected
            // bar's date + cost — same pattern as DailyCostChartCard.
            // Keeps the chart's plot area a fixed height regardless of
            // hover state; the previous "annotation on rule mark" path
            // pushed the bars up and down on every hover.
            if let d = hoveredDate, let row = dailySeries.first(where: { $0.date == d }) {
                HStack(spacing: 8) {
                    Text(row.date)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(pacerCost(row.cost)).help(pacerCostExact(row.cost))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }) {
            Chart {
                ForEach(dailySeries) { d in
                    BarMark(
                        x: .value("Date", d.date),
                        y: .value("Cost", d.cost)
                    )
                    .foregroundStyle(.tint)
                    .cornerRadius(1.5)
                }
                if let h = hoveredDate, dailySeries.contains(where: { $0.date == h }) {
                    RuleMark(x: .value("Selected", h))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            .frame(height: 160)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(pacerCost(v)).help(pacerCostExact(v))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                // Show every Nth date label so the axis isn't crowded
                // on long ranges. With ~90 days at default range, 10
                // strides ≈ 9 labels; reads well at the card's width.
                AxisMarks(values: stridedDailySeriesDates(every: max(dailySeries.count / 9, 1))) { value in
                    AxisValueLabel {
                        if let date = value.as(String.self) {
                            Text(shortDailyDate(date))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXSelection(value: $rawHoveredDate)
            .onChange(of: rawHoveredDate) { _, newValue in
                hoveredDateDebounce?.cancel()
                hoveredDateDebounce = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(40))
                    guard !Task.isCancelled else { return }
                    hoveredDate = newValue
                }
            }
            // Arrow cursor (default) per macOS HIG — clickable charts
            // don't warrant the link cursor.
            .contentShape(Rectangle())
            .onTapGesture {
                // Immediate selection, not the debounced one — the 40ms
                // debounce may not have committed `hoveredDate` yet on tap.
                if let d = rawHoveredDate {
                    push(.day(date: d))
                }
            }
            .accessibilityLabel("Daily cost for \(displayName)")
            .accessibilityHint("Click a bar to drill into that day")
        }
    }

    private func stridedDailySeriesDates(every n: Int) -> [String] {
        guard !dailySeries.isEmpty, n > 0 else { return [] }
        return stride(from: 0, to: dailySeries.count, by: n).map { dailySeries[$0].date }
    }

    /// `2026-04-30` → `04-30`. Year omitted at this density; user
    /// already has page context (the project detail header shows the
    /// time range).
    private func shortDailyDate(_ ymd: String) -> String {
        guard ymd.count == 10 else { return ymd }
        return String(ymd.suffix(5))
    }

    @State private var hoveredModelAngle: Double?

    /// VoiceOver alternative to the model donut — per-model token share
    /// read as a comma list.
    private func modelSlicesSummary(total: Int64) -> String {
        guard total > 0 else { return "no data" }
        return modelSlices.prefix(5).map { m in
            let pct = Int(Double(m.tokens) / Double(total) * 100)
            return "\(pacerShortModel(m.model)) \(pct) percent"
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
        return PacerCard("Models", trailing: {
            if let m = hoveredModelSlice {
                let pct = total > 0 ? Int(Double(m.tokens) / Double(total) * 100) : 0
                HStack(spacing: 6) {
                    Text(pacerShortModel(m.model))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(pacerTokens(m.tokens)).help(pacerTokensExact(m.tokens))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("(\(pct)%)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }) {
            HStack(alignment: .top, spacing: 24) {
                Chart(modelSlices) { m in
                    SectorMark(
                        angle: .value("tokens", m.tokens),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Model", pacerShortModel(m.model)))
                    .cornerRadius(2)
                    .opacity(hoveredModelSlice.map { $0.id == m.id ? 1.0 : 0.45 } ?? 1.0)
                }
                .frame(width: 160, height: 160)
                .chartLegend(.hidden)
                .chartAngleSelection(value: $hoveredModelAngle)
                .accessibilityLabel("Model share for \(displayName)")
                .accessibilityValue(modelSlicesSummary(total: total))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(modelSlices) { m in
                        HStack(alignment: .firstTextBaseline) {
                            Text(pacerShortModel(m.model))
                                .font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 8)
                            Text(pacerTokens(m.tokens)).help(pacerTokensExact(m.tokens))
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
