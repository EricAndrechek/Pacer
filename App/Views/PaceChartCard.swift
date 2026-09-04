import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Pace charts for every rate-limit window the account has — the fixed
/// account-wide 5-hour and 7-day blocks AND every scoped per-model window
/// Anthropic reports (`limits[]`, e.g. a "Fable" weekly cap). Each window
/// renders as an identical `PaceColumn`: the same used%/pace hero, status +
/// burn chips, projection overlay, and tap-to-compare — there is no separate
/// lesser treatment for scoped windows.
///
/// **Fully dynamic.** Nothing enumerates model names, kinds, or a window
/// count. The fixed pair comes from `RateLimitSample`; the scoped columns are
/// discovered from the latest poll's model/surface-scoped `UsageLimitSample`
/// rows. A window Anthropic adds appears as a new column with zero code change;
/// a window that disappears simply drops out of the latest batch.
///
/// The chart itself lives in `PacerUI.PaceChartView` so the widget extension
/// and the menu-bar popover render the exact same SwiftUI view. This card just
/// sources each window's data and arranges the columns.
struct PaceChartCard: View {
    /// Open the compare-models modal for a window key — `"five_hour"` /
    /// `"seven_day"` for the fixed blocks, or a scoped `limits[]` identity for a
    /// per-model window. Wired by the dashboard to its modal-navigation root, so
    /// every column (fixed + scoped) presents through the same house modal.
    let onCompare: ((String) -> Void)?

    /// 8-day window of fixed rate-limit samples. Body never reads the array —
    /// pre-bucketed by window in `bucketed` so neither fixed column does its
    /// own filter pass.
    ///
    /// **Loaded on a signal, not through `@Query`.** `@Query` re-runs when the
    /// context changes, and Pacer's context changes on every scan cycle
    /// because that's when token samples are written. These two series total
    /// ~25,700 rows over 8 days, so every unrelated save re-materialized all of
    /// them on the main thread while the Dashboard was open. Measured at
    /// **103.9% CPU with the window open against 0.0% with it closed** — the
    /// window being open was the entire difference.
    ///
    /// Rate-limit rows only change when the OAuth poller writes, roughly every
    /// five minutes, so `newestSignal` (one row) decides when to reload.
    @State private var samples: [LimitSamplePoint] = []

    /// The newest scoped `limits[]` rows, newest first — just enough to resolve
    /// the latest poll's batch, which is what decides the scoped column set.
    /// Whole rows: the label, group→duration, binding flag and severity all
    /// read fields a columnar projection wouldn't fetch.
    /// The newest poll's scoped rows for this account, loaded alongside the
    /// history rather than through `@Query`.
    ///
    /// It *was* a `@Query`, scoped by account. A `@Query` predicate is fixed at
    /// init, so on a scope change it kept returning the previous account's
    /// windows until something forced a rebuild — and forcing that rebuild
    /// (`.id` on the scope) threw away the card's measured grid width, so the
    /// three columns re-laid out as a lopsided 2+1 and stayed that way. Loading
    /// it here means the card has no account-dependent query at all, needs no
    /// identity change, and keeps its layout.
    @State private var scopedLatest: [ScopedWindowRow] = []

    /// Scoped rows over the same 8-day window the fixed query uses — the
    /// actual-usage line under each scoped column. Separate from the batch
    /// query because the two want opposite things: the batch needs whole rows
    /// but only the newest few, while the line needs thousands of rows but
    /// only four scalars, so this one is columnar (see `docs/perf-tuning.md`).
    ///
    /// It has no `fetchLimit` on purpose. A flat cap here is a *cap on how much
    /// of the cycle you can see*: at the real poll cadence (~1/min) and one row
    /// per limit per poll, 600 rows is about three hours — 2% of a weekly
    /// window — so the scoped line rendered as a stub near "now" no matter how
    /// long the cycle had been running. The 8-day cutoff bounds it by time
    /// instead, which is the bound that matches what the chart draws.
    @State private var scopedHistory: [ScopedSamplePoint] = []

    /// One row: the newest rate-limit sample. Cheap to re-run on every save —
    /// which is exactly what `@Query` will do — and its timestamp is the
    /// signal that the expensive series are stale.
    @Query private var newestSignal: [RateLimitSample]

    /// The scoped equivalent. Both are watched because a poll can in principle
    /// write scoped `limits[]` rows without a fixed one, and keying the reload
    /// on only the fixed series would leave the per-model charts stale until
    /// the next fixed sample landed. One row each — the cost is nil.
    @Query private var newestScopedSignal: [UsageLimitSample]

    @Environment(\.modelContext) private var modelContext

    /// The shared intelligence engine — single source of the forecast
    /// trajectories (the dashed overlay; the compare-models modal asks the
    /// engine itself), with each model's accuracy coming from the engine's
    /// persisted per-user track record.
    @Environment(\.usageEngine) private var engine

    /// Forecast trajectory per window, refreshed when the engine refits. Keyed
    /// by window key (fixed name or scoped identity) — the fixed and scoped key
    /// spaces never collide.
    @State private var projections: [String: WindowProjection] = [:]
    /// Per-window outlook (projected end-of-window + band, crossing range,
    /// cycle frequency facts) for the caption line under each chart.
    @State private var outlooks: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
    @State private var endEstimates: [String: Estimate] = [:]

    struct WindowProjection: Equatable, Sendable {
        /// The selected model's raw forward trajectory (origin = the engine's
        /// last-refit snapshot). Re-anchored onto the live actual tail at
        /// render time in `liveChartData` so the dashed line continues the
        /// solid one seamlessly.
        var trajectory: BurnTrajectory.Trajectory
    }

    /// Which account's windows this chart draws — the picked scope, else the
    /// active login. Taken as a parameter, not read from `UsageScope` in here:
    /// a `@Query` predicate is captured once at init, so a card that read the
    /// scope itself would stay pinned to whichever account was selected when
    /// it first appeared.
    let limitAccountId: String?

    init(limitAccountId: String? = nil, onCompare: ((String) -> Void)? = nil) {
        self.limitAccountId = limitAccountId
        self.onCompare = onCompare
        // Only the signal is a `@Query`. One row, so re-running it on every
        // save costs nothing; the series it guards are loaded in `reload()`.
        //
        // Deliberately **unscoped**. These decide *when* to reload, not what
        // to show, and a predicate fixed at init is exactly the wrong thing for
        // a value that changes: an account-scoped signal goes stale the moment
        // the scope changes and then never fires again. Any account's poll is a
        // fine reason to top up, and the top-up itself is scoped.
        var signal = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        signal.fetchLimit = 1
        signal.propertiesToFetch = [\.sampledAt]
        _newestSignal = Query(signal)

        var scopedSignal = FetchDescriptor<UsageLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        scopedSignal.fetchLimit = 1
        scopedSignal.propertiesToFetch = [\.sampledAt]
        _newestScopedSignal = Query(scopedSignal)

    }

    /// Newest timestamp across both sources — the trigger for a reload.
    private var reloadSignal: Date? {
        let fixed = newestSignal.first?.sampledAt
        let scoped = newestScopedSignal.first?.sampledAt
        guard let fixed else { return scoped }
        guard let scoped else { return fixed }
        return max(fixed, scoped)
    }

    /// Load the two 8-day series. Called on appear and whenever a new
    /// rate-limit sample lands — not on every context change.
    ///
    /// The cutoff is computed here rather than held from `init` so the window
    /// stays 8 days wide however long Pacer has been open; a stored constant
    /// would keep its launch-day value and widen the query by a day per day.
    /// Newest sample already loaded. `nil` means nothing has been loaded yet,
    /// which is the only case that reads all 8 days.
    @State private var loadedThrough: Date?
    /// True only while the first, full-window fetch for this account is in
    /// flight — so the card says "loading" rather than showing the cold-start
    /// empty state, which reads as "this account has no data".
    @State private var isLoading = false

    /// Whether the forecast overlay applies to what is on screen.
    ///
    /// The engine fits one login's history — its parameters, snapshot trail
    /// and golden fixtures are all the active account's — so a projection
    /// drawn over another account's series would be a confident line about the
    /// wrong data. Making the engine per-account is a real piece of work and
    /// not this one; until then the chart is honest about showing history
    /// alone when you scope away from the active login.
    private var showsProjections: Bool {
        limitAccountId == nil || limitAccountId == UsageScope.shared.activeAccountId
    }

    /// Load the two 8-day series **off the main actor**.
    ///
    /// This used to be `@MainActor` and fetch `@Model` rows straight into
    /// `@State`. On a busy account that is ~12,500 fixed and ~19,000 scoped
    /// rows, and SwiftData faults whole objects at roughly 66 µs each however
    /// few properties you ask for — so about two seconds of frozen window.
    /// That was survivable while it happened on appear and then incrementally;
    /// it stopped being survivable when switching accounts started causing it,
    /// because a freeze you cause by clicking something reads as a broken app.
    ///
    /// So the fetch happens on `@ScanActor` with its own `ModelContext` and
    /// only `LimitSamplePoint`/`ScopedSamplePoint` values cross back — the
    /// shape `AccountTotals` and `TokenPoolStatus` already use. The card
    /// renders whatever it has meanwhile.
    private func reload() async {
        guard let container = try? PacerStore.sharedModelContainer() else { return }
        let account = limitAccountId

        // Seed from the cross-rebuild cache before deciding what to fetch: a
        // scope flip back to an account already loaded this session becomes an
        // incremental top-up instead of another full window.
        if loadedThrough == nil {
            let cached = PaceSeriesCache.shared.series(for: account)
            if cached.loadedThrough != nil {
                samples = cached.fixed
                scopedHistory = cached.scoped
                scopedLatest = cached.windows
                loadedThrough = cached.loadedThrough
            }
        }

        let through = loadedThrough
        let started = Date()
        isLoading = through == nil

        let loaded = await Task.detached(priority: .userInitiated) {
            await Self.load(container: container, account: account, through: through)
        }.value
        isLoading = false

        if let through, loadedThrough == through {
            // Incremental. A poll adds a handful of rows to an 8-day window of
            // ~31,000, so re-reading the whole window each time would
            // re-materialize all of them to learn about three.
            //
            // Newest-first order is preserved by prepending, which is also why
            // the fetch is ordered the same way.
            if !loaded.fixed.isEmpty { samples = loaded.fixed + samples }
            if !loaded.scoped.isEmpty { scopedHistory = loaded.scoped + scopedHistory }
            if !loaded.windows.isEmpty { scopedLatest = loaded.windows }
            // Drop what has aged out, so the window stays 8 days rather than
            // growing for as long as Pacer is open.
            samples.removeAll { $0.sampledAt < loaded.cutoff }
            scopedHistory.removeAll { $0.sampledAt < loaded.cutoff }
        } else if through == nil {
            samples = loaded.fixed
            scopedHistory = loaded.scoped
            scopedLatest = loaded.windows
        } else {
            // The scope changed while this load was in flight; its rows belong
            // to the previous account. Drop them rather than mixing.
            return
        }

        let newestLoaded = [samples.first?.sampledAt, scopedHistory.first?.sampledAt]
            .compactMap { $0 }.max()
        if let newestLoaded { loadedThrough = newestLoaded }
        PaceSeriesCache.shared.store(
            .init(fixed: samples, scoped: scopedHistory, windows: scopedLatest,
                  loadedThrough: loadedThrough),
            for: account)

        if through == nil {
            Log.write("PaceChartCard",
                      "loaded \(samples.count) fixed + \(scopedHistory.count) scoped row(s) "
                        + "in \(Int(Date().timeIntervalSince(started) * 1000))ms"
                        + " [account \(account.map { String($0.suffix(4)) } ?? "all")]")
        }
    }

    private struct Loaded: Sendable {
        let fixed: [LimitSamplePoint]
        let scoped: [ScopedSamplePoint]
        /// The newest poll's scoped windows — the column set. Only populated
        /// on a cold load; an incremental top-up leaves the existing set alone
        /// unless it brought newer rows, which `latestBatch` sorts out.
        let windows: [ScopedWindowRow]
        let cutoff: Date
    }

    /// Deliberately **not** on `@ScanActor`. The first version was, and the
    /// same fetch that takes 59 ms against the store directly measured 1,120 ms
    /// in-app — it was not slow, it was queued behind the scan pipeline, which
    /// owns that actor and is at its busiest exactly when the dashboard first
    /// appears. A short-lived context of its own has no such queue, which is
    /// the same reason `PacerSnapshotBuilder` and `PacerUsageBuilder` are
    /// `nonisolated` and build their own.
    /// Deliberately **not** on `@ScanActor`. The first version was, and it
    /// queued behind the scan pipeline, which owns that actor and is at its
    /// busiest exactly when the dashboard first appears. A short-lived context
    /// of its own has no such queue — the same reason `PacerSnapshotBuilder`
    /// and `PacerUsageBuilder` are `nonisolated` and build their own.
    ///
    /// Two bounds here are about fetching what the card *draws*, which on a
    /// busy account is a third of what it used to read:
    ///
    /// - **The 5-hour window does not need eight days.** Both fixed windows
    ///   came from one 8-day fetch, but the 5h column only ever plots its
    ///   current five-hour cycle. Half the fixed rows were being materialised
    ///   to be filtered straight back out. The `(accountId, window, sampledAt)`
    ///   index serves both halves.
    /// - **Account-wide scoped rows are never charted.** The columns keep only
    ///   model/surface-scoped identities, but the history fetch took every
    ///   identity: on this machine `session||` and `weekly_all||` were 12,536
    ///   of 18,822 rows over eight days — two thirds of the scoped cost, drawn
    ///   nowhere.
    private nonisolated static func load(container: ModelContainer, account: String?,
                                         through: Date?) async -> Loaded {
        let context = ModelContext(container)
        let now = Date()
        let cutoff = now.addingTimeInterval(-8 * 86400)
        // Twice the 5-hour cycle, so a window whose reset has just rolled (or
        // whose `resets_at` is briefly stale) still has its whole cycle here.
        let fiveHourCutoff = through ?? now.addingTimeInterval(-12 * 3600)
        let longCutoff = through ?? cutoff

        var fixed: [LimitSamplePoint] = []
        for (window, since) in [(RateLimitWindowName.fiveHour, fiveHourCutoff),
                                (RateLimitWindowName.sevenDay, longCutoff)] {
            var d = FetchDescriptor<RateLimitSample>(
                predicate: Self.fixedPredicate(account: account, window: window,
                                               since: since, incremental: through != nil))
            d.sortBy = [SortDescriptor(\.sampledAt, order: .reverse)]
            // Columnar projection: the card reads only these four scalars.
            d.propertiesToFetch = [\.window, \.sampledAt, \.resetsAt, \.usedPercentage]
            fixed += ((try? context.fetch(d)) ?? []).map(\.limitPoint)
        }

        var scopedDescriptor = FetchDescriptor<UsageLimitSample>(
            predicate: Self.scopedPredicate(account: account, since: longCutoff,
                                            incremental: through != nil))
        scopedDescriptor.sortBy = [SortDescriptor(\.sampledAt, order: .reverse)]
        scopedDescriptor.propertiesToFetch = [\.identity, \.sampledAt, \.resetsAt, \.percent]
        let scopedModels = (try? context.fetch(scopedDescriptor)) ?? []
        let scoped = scopedModels.map(\.scopedPoint)

        // The column set comes off the same rows — whole-row fields (label,
        // group, severity, the binding flag) that the columnar projection above
        // does not carry, so this is a second, tiny fetch of the newest batch.
        var latest = FetchDescriptor<UsageLimitSample>(
            predicate: Self.scopedPredicate(account: account, since: cutoff, incremental: false))
        latest.sortBy = [SortDescriptor(\.sampledAt, order: .reverse)]
        latest.fetchLimit = 120
        let windows = ((try? context.fetch(latest)) ?? []).map(\.scopedWindowRow)

        return Loaded(fixed: fixed.sorted { $0.sampledAt > $1.sampledAt },
                      scoped: scoped, windows: windows, cutoff: cutoff)
    }

    /// `sampledAt >= since` for a cold load, `> since` for an incremental one
    /// — the incremental path is topping up past a row it already holds.
    private nonisolated static func fixedPredicate(
        account: String?, window: String, since: Date, incremental: Bool
    ) -> Predicate<RateLimitSample> {
        switch (account, incremental) {
        case let (a?, true):
            return #Predicate { $0.accountId == a && $0.window == window && $0.sampledAt > since }
        case let (a?, false):
            return #Predicate { $0.accountId == a && $0.window == window && $0.sampledAt >= since }
        case (nil, true):
            return #Predicate { $0.window == window && $0.sampledAt > since }
        case (nil, false):
            return #Predicate { $0.window == window && $0.sampledAt >= since }
        }
    }

    /// Model/surface-scoped rows only — the account-wide `session` and
    /// `weekly_all` identities duplicate the 5h/7d columns and are filtered out
    /// of the column set anyway, so reading their history is pure cost.
    private nonisolated static func scopedPredicate(
        account: String?, since: Date, incremental: Bool
    ) -> Predicate<UsageLimitSample> {
        switch (account, incremental) {
        case let (a?, true):
            return #Predicate {
                $0.accountId == a && $0.sampledAt > since
                    && ($0.modelId != nil || $0.modelDisplayName != nil || $0.surface != nil)
            }
        case let (a?, false):
            return #Predicate {
                $0.accountId == a && $0.sampledAt >= since
                    && ($0.modelId != nil || $0.modelDisplayName != nil || $0.surface != nil)
            }
        case (nil, true):
            return #Predicate {
                $0.sampledAt > since
                    && ($0.modelId != nil || $0.modelDisplayName != nil || $0.surface != nil)
            }
        case (nil, false):
            return #Predicate {
                $0.sampledAt >= since
                    && ($0.modelId != nil || $0.modelDisplayName != nil || $0.surface != nil)
            }
        }
    }

    // MARK: - Column model

    /// Everything one `PaceColumn` needs, sourced uniformly whether the window
    /// is a fixed block (`RateLimitSample`) or a scoped per-model cap
    /// (`UsageLimitSample`). The column view is source-agnostic.
    struct Column: Identifiable, Equatable {
        let id: String            // window key / scoped identity
        let title: String
        let duration: TimeInterval
        /// Latest reading (nil ⇒ no sample yet — the genuine cold start).
        let usedPct: Double?
        /// Window rollover (nil ⇒ idle / server anchored no cycle).
        let resetsAt: Date?
        /// Projection-free actual line — the shared-image-parity base the
        /// column layers its forecast overlay onto.
        let baseChart: PaceChartView.Data?
        /// This scoped window is the one currently in effect for the account.
        /// Always false for fixed windows.
        let isActive: Bool
        /// Scoped windows only: a raised-severity tag ("warning"/"critical")
        /// when the server flags one. nil for fixed windows and normal rows.
        let severity: SeverityTag?
        let isScoped: Bool

        struct SeverityTag: Equatable { let text: String; let band: UsageBand }
    }

    // MARK: - Column set

    private struct Bucketed {
        var fiveHour: [LimitSamplePoint] = []
        var sevenDay: [LimitSamplePoint] = []
        var latest: LimitSamplePoint?
    }

    /// Derived synchronously from `samples` so the first render already has the
    /// real layout — see the perf note in git history for why this isn't
    /// `@State` + `.onAppear`.
    private var bucketed: Bucketed {
        var b = Bucketed()
        for s in samples {
            if s.window == RateLimitWindowName.fiveHour { b.fiveHour.append(s) }
            else if s.window == RateLimitWindowName.sevenDay { b.sevenDay.append(s) }
            if s.sampledAt > (b.latest?.sampledAt ?? .distantPast) { b.latest = s }
        }
        return b
    }

    /// The scoped rows to render, one per model/surface-scoped identity in the
    /// latest poll, ordered active-first then hottest (the `latestBatch` order).
    /// Account-wide `session`/`weekly_all` rows are excluded — the fixed 5h/7d
    /// hero columns already own those (Decision C).
    private var scopedRows: [ScopedWindowRow] {
        // Already filtered to model/surface-scoped identities by the loader —
        // the account-wide `session`/`weekly_all` rows the fixed 5h/7d heroes
        // own are excluded in the fetch predicate (Decision C).
        scopedLatest.latestBatch()
    }

    /// Fixed 5-hour / 7-day durations — the anchors both the sort (which side a
    /// scoped window snaps to) and the fixed columns share.
    private static let fiveHourDuration: TimeInterval = 5 * 3600
    private static let sevenDayDuration: TimeInterval = 7 * 86400

    /// The full ordered column set, arranged by a single comparator so the two
    /// account-wide heroes stay glued together: scoped **session**-side windows,
    /// then **5h**, then **7d**, then scoped **weekly**-side windows, then any
    /// longer/other scoped window — sorting on `(side, duration, displayName)`.
    /// A scoped window can never land between 5h and 7d because its `side` is
    /// always outside the adjacent `.fiveHour`/`.sevenDay` ranks
    /// (`PaceColumnLayout.scopedSide`). With no scoped rows this yields exactly
    /// `[5h, 7d]`, unchanged.
    private func columns(_ b: Bucketed, now: Date) -> [Column] {
        typealias Side = PaceColumnLayout.Side
        var tagged: [(side: Side, col: Column)] = [
            (.fiveHour, fixedColumn(title: "5-hour", key: RateLimitWindowName.fiveHour,
                                    duration: Self.fiveHourDuration, samples: b.fiveHour, now: now)),
            (.sevenDay, fixedColumn(title: "7-day", key: RateLimitWindowName.sevenDay,
                                    duration: Self.sevenDayDuration, samples: b.sevenDay, now: now)),
        ]
        for row in scopedRows {
            let duration = WindowSpec.scopedDuration(group: row.group)
            let severity: Column.SeverityTag? = row.severityValue.isElevated
                ? .init(text: row.severity.lowercased(), band: row.displayBand)
                : nil
            let side = PaceColumnLayout.scopedSide(
                group: row.group, duration: duration,
                fiveHourDuration: Self.fiveHourDuration, sevenDayDuration: Self.sevenDayDuration)
            tagged.append((side, Column(
                id: row.identity, title: row.label, duration: duration,
                usedPct: row.percent, resetsAt: row.resetsAt,
                baseChart: .cycle(scoped: row, history: scopedHistory,
                                  duration: duration, now: now),
                isActive: row.isActive, severity: severity, isScoped: true)))
        }
        return tagged
            .sorted { lhs, rhs in
                if lhs.side != rhs.side { return lhs.side < rhs.side }
                if lhs.col.duration != rhs.col.duration { return lhs.col.duration < rhs.col.duration }
                if lhs.col.title != rhs.col.title {
                    return lhs.col.title.localizedCaseInsensitiveCompare(rhs.col.title) == .orderedAscending
                }
                return lhs.col.id < rhs.col.id
            }
            .map(\.col)
    }

    private func fixedColumn(title: String, key: String, duration: TimeInterval,
                             samples: [LimitSamplePoint], now: Date) -> Column {
        let latest = samples.first
        return Column(
            id: key, title: title, duration: duration,
            usedPct: latest?.usedPercentage, resetsAt: latest?.resetsAt,
            baseChart: .cycle(fixed: samples, duration: duration, now: now),
            isActive: false, severity: nil, isScoped: false)
    }

    // MARK: - Engine refresh

    /// Re-ask the engine for every window's answers — fixed and scoped in one
    /// pass. Powers the overlay (selected model), the status/burn chips, and the
    /// outlook caption. Runs OFF the main actor (awaiting the `@ModelActor`
    /// engine from `@MainActor` would otherwise resume the heavy forecast fit
    /// inline on the main thread).
    private func refreshProjections(scopedIdentities: [String]) async {
        guard showsProjections else {
            projections = [:]
            outlooks = [:]
            return
        }
        guard let engine else { return }
        let started = Date()
        let computed = await Task.detached(priority: .userInitiated) { [engine] in
            var nextSelected: [String: WindowProjection] = [:]
            var nextOutlooks: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
            var nextEnds: [String: Estimate] = [:]
            func absorb(key: String, outlook: UsageIntelligenceEngine.BurnOutlook?,
                        end: Estimate, list: [BurnTrajectory.ScoredTrajectory]) {
                if let outlook { nextOutlooks[key] = outlook }
                nextEnds[key] = end
                if let chosen = list.first(where: { $0.isSelected }) ?? list.first {
                    nextSelected[key] = WindowProjection(trajectory: chosen.trajectory)
                }
            }
            for window in RateLimitWindowKind.allCases {
                absorb(key: window.rawValue,
                       outlook: await engine.burnOutlook(window: window),
                       end: await engine.ask(.rateLimitOutlook(window)),
                       list: await engine.rateLimitTrajectories(window: window))
            }
            for id in scopedIdentities {
                absorb(key: id,
                       outlook: await engine.burnOutlook(windowKey: id),
                       end: await engine.ask(.scopedOutlook(id)),
                       list: await engine.rateLimitTrajectories(windowKey: id))
            }
            return (nextSelected, nextOutlooks, nextEnds)
        }.value
        projections = computed.0
        outlooks = computed.1
        endEstimates = computed.2
        Log.write("PaceChartCard",
                  "projections for \(2 + scopedIdentities.count) window(s) in "
                    + "\(Int(Date().timeIntervalSince(started) * 1000))ms")
    }

    // MARK: - Body

    var body: some View {
        let t0 = Date()
        let b = bucketed
        let now = Date()
        let cols = columns(b, now: now)
        let buildMs = Int(Date().timeIntervalSince(t0) * 1000)
        if buildMs >= 100 {
            Log.write("PaceChartCard",
                      "body build \(buildMs)ms for \(samples.count)+\(scopedHistory.count) point(s)"
                        + " → \(cols.map { $0.baseChart?.points.count ?? 0 }) plotted")
        }
        let scopedIds = scopedRows.map(\.identity)
        // Stable key so `.task(id:)` re-runs the engine ask when the window set
        // changes (a scoped window appears / disappears).
        let windowKey = cols.map(\.id).joined(separator: ",")
        let hasScoped = cols.contains { $0.isScoped }

        // The "via oauth · just now" freshness chip lives in the page header
        // (`RateLimitSourceChip` in DashboardView) — it describes the whole
        // dashboard's data feed, not this card alone.
        return PacerCard("Rate-limit pace") {
            if isLoading && b.latest == nil {
                loadingState
            } else if b.latest == nil && scopedRows.isEmpty {
                emptyState
            } else if cols.count <= 2 {
                // Exactly the fixed pair — reproduce the original two-column
                // layout byte-for-byte so 5h/7d are unchanged when they're the
                // only windows.
                HStack(alignment: .top, spacing: 24) {
                    column(cols[0])
                    Divider().frame(height: 110)
                    column(cols[1])
                }
            } else {
                // N windows (> 2) — a balanced, width-aware grid. The column
                // count is computed from the measured content width so rows
                // stay even (4→2+2, 5→3+2, 6→3+3) and drop to fewer columns as
                // the pane narrows (6→2+2+2) instead of crushing 4+ windows
                // into a too-narrow row. The last row is left-aligned.
                PaceColumnGrid() {
                    ForEach(cols) { column($0) }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if hasScoped {
                    Text("Per-model windows Anthropic reports for this account, forecast the same way as the 5-hour and 7-day pace — projected fill, time-to-limit, and calibrated bands. A dot marks the window currently in effect. Tap any window to compare every forecast model.")
                }
                if !showsProjections {
                    Text("History only. Forecasts follow the active account.")
                }
            }
        }
        // Reload the 8-day series when a NEW rate-limit sample lands (the
        // poller writes roughly every five minutes), not on every context
        // change. `.task(id:)` also fires once on appear, which seeds them.
        .task(id: reloadSignal) { await reload() }
        // A scope change invalidates everything loaded. The card is *not*
        // rebuilt by identity for this — doing that threw away its measured
        // grid width and re-laid the columns out lopsided — so it clears its
        // own state instead.
        .onChange(of: limitAccountId) {
            samples = []
            scopedHistory = []
            scopedLatest = []
            loadedThrough = nil
            Task { await reload() }
        }
        .task(id: windowKey) { await refreshProjections(scopedIdentities: scopedIds) }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshProjections(scopedIdentities: scopedIds) }
        }
    }

    private func column(_ col: Column) -> PaceColumn {
        PaceColumn(
            column: col,
            projection: projections[col.id],
            outlook: outlooks[col.id],
            endEstimate: endEstimates[col.id],
            onCompare: onCompare)
    }

    /// Shown only while the first full-window fetch for an account is in
    /// flight. Terse on purpose: the alternative is the cold-start empty
    /// state, which says "waiting for the first reading" and would be a
    /// straight-up lie about an account with four months of history.
    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading history…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Waiting for the first rate-limit reading")
                    .font(.body.weight(.medium))
                Text("Pacer checks Anthropic every 5 minutes. If you're signed into Claude Code, the 5-hour and 7-day pace will appear within about 5 minutes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .frame(minHeight: 96, alignment: .topLeading)
    }
}

/// One window's column — the reusable per-window renderer for the fixed 5h/7d
/// blocks AND every scoped per-model window. Renders the title, hero used%/
/// pace% line, status + burn chips, the shared `PaceChartView`, and the outlook
/// caption. The view itself is in PacerUI so the widget extension renders the
/// same chart pixel-for-pixel.
private struct PaceColumn: View {
    let column: PaceChartCard.Column
    /// Forecast trajectory for this window (nil when unavailable). Drawn only on
    /// the live dashboard chart — deliberately not on the shared image.
    var projection: PaceChartCard.WindowProjection?
    /// Engine burn outlook (crossing range + cycle frequency facts) and the
    /// projected end-of-window estimate, for the outlook caption.
    var outlook: UsageIntelligenceEngine.BurnOutlook?
    var endEstimate: Estimate?
    /// Opens the compare-models modal (threaded from the dashboard's
    /// modal-navigation root), keyed by this window's key / identity.
    var onCompare: ((String) -> Void)?

    /// Share affordance state. `hovering` reveals the share button only while
    /// the cursor is over the column (Linear/Things idiom); `sharing` drives the
    /// preview popover.
    @State private var hovering = false
    @State private var sharing = false

    private var windowKey: String { column.id }
    private var title: String { column.title }
    private var duration: TimeInterval { column.duration }

    /// Display-cycle for this column. nil only when there's no reading or the
    /// reading has no `resetsAt`. Otherwise resolves the active-or-awaiting
    /// bracket for everything in the column body.
    private var cycle: DisplayCycle? {
        guard let resets = column.resetsAt else { return nil }
        return DisplayCycle.resolve(resetsAt: resets, duration: duration)
    }

    /// Used % when we have a fresh reading but the server anchored no reset to
    /// it — the window is idle (0% used until the first message of a window
    /// starts the clock). `nil` when there's no reading at all (the genuine
    /// "still collecting the first reading" state). See #100.
    private var idleUsedPct: Double? {
        guard column.resetsAt == nil, let used = column.usedPct else { return nil }
        return used
    }

    /// `baseChart` plus the forecast overlay — used only by the live dashboard
    /// chart. `baseChart` itself stays projection-free so the shared image is
    /// unchanged.
    private func liveChartData(base: PaceChartView.Data?) -> PaceChartView.Data? {
        guard let base else { return nil }
        guard let projection else { return base }
        // Re-anchor the forecast onto the live actual tail so the dashed line
        // continues the solid one without a step.
        guard let tail = base.points.last else { return base }
        let rebased = projection.trajectory.reanchored(toTime: tail.time, value: tail.value)
        let pts = rebased.points.map { PaceChartView.Data.Point(time: $0.at, value: $0.usedPercentage) }
        // At/over the cap the trajectory collapses to its origin — fall back to
        // the projection-free chart.
        guard pts.count >= 2 else { return base }
        return base.withProjection(pts, crossesFullAt: rebased.crossesFullAt)
    }

    var body: some View {
        // Resolve the chart data ONCE per body pass. `base` stays
        // projection-free (share-image parity); `live` layers the forecast.
        let base = column.baseChart
        let live = liveChartData(base: base)
        return VStack(alignment: .leading, spacing: 8) {
            header(chartData: base)
            heroLine
            chipRow
            chartSlot(live: live)
            outlookLines
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }

    /// Status + burn chips under the hero numbers — the at-a-glance verdict row.
    @ViewBuilder
    private var chipRow: some View {
        if let used = column.usedPct, let cycle, !cycle.isAwaiting {
            let band = PaceBand(usedPct: used, paceEndPct: cycle.paceFraction * 100)
            HStack(spacing: 6) {
                paceChip(band: band)
                burnChipView
            }
        }
    }

    @ViewBuilder
    private func paceChip(band: PaceBand) -> some View {
        Group {
            switch band {
            case .green:
                Chip(text: "behind", systemImage: "checkmark", tint: .green, size: .compact)
            case .white:
                Chip(text: "on pace", tint: .secondary, size: .compact)
            case .yellow:
                Chip(text: "ahead", systemImage: "exclamationmark", tint: .yellow, size: .compact)
            case .red:
                Chip(text: "danger", systemImage: "exclamationmark.triangle.fill", tint: .red, size: .compact)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var burnChipView: some View {
        if let used = column.usedPct, let outlook,
           let chip = IntelligenceFormatting.burnChip(outlook: outlook, endEstimate: endEstimate,
                                                      duration: duration, usedPct: used) {
            Chip(text: chip.text, systemImage: "flame.fill", tint: chip.tint, size: .compact)
                .fixedSize()
                .help(chip.help)
        }
    }

    /// One muted line of the user's own history with this window
    /// ("topped 90% in 3 of 73 cycles · hit the limit 1×").
    @ViewBuilder
    private var outlookLines: some View {
        if cycle?.isAwaiting == false, let o = outlook,
           let freq = IntelligenceFormatting.frequencyLine(o) {
            Text(freq)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// "Compare models" — opens the all-models projection modal. Hover-revealed
    /// (the Linear/Things idiom).
    @ViewBuilder
    private func compareButton(chartData: PaceChartView.Data?) -> some View {
        if let onCompare, cycle?.isAwaiting == false, chartData != nil, projection != nil {
            Button { onCompare(windowKey) } label: {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Compare every forecast model's projection and its accuracy on your cycles")
            .opacity(hovering || sharing ? 1 : 0)
        }
    }

    /// Everything the share sheet needs to render and name this window's chart
    /// as an image — built from the same resolved values the live chart draws.
    private func sharePayload(chartData: PaceChartView.Data?) -> PaceSharePayload? {
        guard let chartData,
              let cycle, !cycle.isAwaiting,
              let used = column.usedPct, let resets = column.resetsAt
        else { return nil }
        let windowName: String
        let slug: String
        if column.isScoped {
            windowName = title
            slug = title.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        } else {
            windowName = duration <= 6 * 3600 ? "5-Hour" : "7-Day"
            slug = duration <= 6 * 3600 ? "5-hour" : "7-day"
        }
        return PaceSharePayload(
            title: "\(windowName) Usage Pace",
            data: chartData,
            duration: duration,
            resetsAt: resets,
            usedPct: used,
            paceEndPct: cycle.paceFraction * 100,
            fileName: "pacer-\(slug.isEmpty ? "window" : slug)-pace.png")
    }

    /// Hover-revealed share button + its preview popover.
    @ViewBuilder
    private func shareButton(chartData: PaceChartView.Data?) -> some View {
        if let payload = sharePayload(chartData: chartData) {
            Button { sharing = true } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Share this chart as an image")
            .opacity(hovering || sharing ? 1 : 0)
            .popover(isPresented: $sharing, arrowEdge: .bottom) {
                ChartShareSheet(
                    fileName: payload.fileName,
                    makeCard: { scheme in AnyView(PaceShareCard(payload: payload, scheme: scheme)) }
                )
            }
        }
    }

    /// Renders the chart for an active cycle or a textual placeholder when
    /// awaiting / idle / collecting. Same vertical footprint either way so the
    /// grid's equal-height rows stay stable.
    @ViewBuilder
    private func chartSlot(live: PaceChartView.Data?) -> some View {
        if cycle?.isAwaiting == true {
            placeholderSlot(
                title: "Awaiting first sample of new cycle",
                detail: "Pacer will plot the new cycle once a fresh sample arrives.")
        } else if let live {
            PaceChartView(data: live, style: .detailed)
                .frame(height: 96)
        } else if idleUsedPct != nil {
            placeholderSlot(
                title: "No usage in this window yet",
                detail: "The window starts when you next use Claude.")
        } else {
            Text("collecting…")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(height: 96)
        }
    }

    private func placeholderSlot(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 96, alignment: .topLeading)
    }

    private func header(chartData: PaceChartView.Data?) -> some View {
        HStack(spacing: 8) {
            // Subtle "currently in effect" indicator for the active scoped
            // window — a small accent dot, no jargon label.
            if column.isActive {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Currently the active limit")
                    .help("Currently the active limit for this account")
            }
            Eyebrow(text: title)
            if let severity = column.severity {
                Chip(text: severity.text, tint: severity.band.color, size: .compact)
            }
            Spacer(minLength: 8)
            compareButton(chartData: chartData)
            shareButton(chartData: chartData)
            caption
        }
    }

    @ViewBuilder
    private var caption: some View {
        if let cycle, cycle.isAwaiting {
            Text("cycle reset · awaiting")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else if let resets = column.resetsAt {
            Text(pacerResetCaption(resetsAt: resets, durationSeconds: duration))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else if idleUsedPct != nil {
            Text("idle · no active window")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else {
            Text("resets unknown")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var heroLine: some View {
        if let used = column.usedPct, let cycle, !cycle.isAwaiting {
            let paceEndPct = cycle.paceFraction * 100
            let band = PaceBand(usedPct: used, paceEndPct: paceEndPct)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(used.rounded()))%")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(band.color)
                Text("/")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
                Text("\(Int(paceEndPct.rounded()))%")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else if let idle = idleUsedPct {
            // Idle window: show the real reading on its own — no pace target to
            // divide against (no cycle), so no "/ NN%".
            Text("\(Int(idle.rounded()))%")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text("--")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }
}
