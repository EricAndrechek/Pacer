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
    /// Window key plus the account it belongs to — the all-accounts view can
    /// show two accounts' 5-hour columns at once, and they open different
    /// comparisons.
    let onCompare: ((String, String?) -> Void)?

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
    /// One account's loaded series. Usually there is exactly one — a picked
    /// scope, or a machine that runs its accounts one at a time — and then
    /// `label` is nil and nothing is decorated. Under "all accounts" on a
    /// machine that runs them in parallel there is one per account, and the
    /// columns say whose they are.
    struct AccountSeries: Identifiable {
        let accountId: String?
        let label: String?
        var fixed: [LimitSamplePoint] = []
        var scoped: [ScopedSamplePoint] = []
        var windows: [ScopedWindowRow] = []
        var loadedThrough: Date?
        var id: String { accountId ?? "" }
    }

    @State private var series: [AccountSeries] = []

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

    /// For naming whose windows these are. Two rows, so the query is free.
    @Query private var accounts: [Account]

    /// Rate limits belong to a *login*, so "all accounts" cannot combine them —
    /// two 5-hour windows do not sum into a third. The card falls back to the
    /// active login, which is what every gauge showed before accounts existed
    /// and is still the only defensible single answer. Unlabelled, though, it
    /// reads as "all accounts' limits", which is the one thing it is not.
    private var limitOwnerNote: String? {
        guard accounts.count > 1, limitAccountId != nil else { return nil }
        guard UsageScope.shared.accountId == nil else { return nil }   // a picked scope names itself
        guard series.count <= 1 else { return nil }                    // both are on screen
        let owner = accounts.first { $0.id == limitAccountId }?.label ?? "the active account"
        return "Rate limits are one login's — showing \(owner). Pick an account above for its own."
    }

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
    @Environment(\.usageEngines) private var engines

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

    init(limitAccountId: String? = nil, onCompare: ((String, String?) -> Void)? = nil) {
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
    /// True only while the first, full-window fetch for this account is in
    /// flight — so the card says "loading" rather than showing the cold-start
    /// empty state, which reads as "this account has no data".
    @State private var isLoading = false
    /// Whether this machine runs its accounts in parallel — recomputed with the
    /// series, since it decides how many there are.
    @State private var isParallel = false

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
        isParallel = AccountParallelism.isParallel(context: modelContext)
        let targets = loadTargets()
        let started = Date()
        isLoading = series.isEmpty

        var next: [AccountSeries] = []
        for target in targets {
            var entry = series.first { $0.accountId == target.accountId }
                ?? AccountSeries(accountId: target.accountId, label: target.label)
            entry = AccountSeries(accountId: target.accountId, label: target.label,
                                  fixed: entry.fixed, scoped: entry.scoped,
                                  windows: entry.windows, loadedThrough: entry.loadedThrough)

            // Seed from the cross-rebuild cache before deciding what to fetch:
            // flipping back to an account already loaded this session becomes
            // an incremental top-up rather than another full window.
            if entry.loadedThrough == nil {
                let cached = PaceSeriesCache.shared.series(for: target.accountId)
                if cached.loadedThrough != nil {
                    entry.fixed = cached.fixed
                    entry.scoped = cached.scoped
                    entry.windows = cached.windows
                    entry.loadedThrough = cached.loadedThrough
                }
            }

            let through = entry.loadedThrough
            let account = target.accountId
            let loaded = await Task.detached(priority: .userInitiated) {
                await Self.load(container: container, account: account, through: through)
            }.value

            if through != nil {
                // Incremental. A poll adds a handful of rows to an 8-day window
                // of ~31,000, so re-reading the whole window each time would
                // re-materialize all of them to learn about three. Newest-first
                // order is preserved by prepending, which is why the fetch is
                // ordered the same way.
                if !loaded.fixed.isEmpty { entry.fixed = loaded.fixed + entry.fixed }
                if !loaded.scoped.isEmpty { entry.scoped = loaded.scoped + entry.scoped }
                if !loaded.windows.isEmpty { entry.windows = loaded.windows }
                // Drop what has aged out, so the window stays 8 days rather
                // than growing for as long as Pacer is open.
                entry.fixed.removeAll { $0.sampledAt < loaded.cutoff }
                entry.scoped.removeAll { $0.sampledAt < loaded.cutoff }
            } else {
                entry.fixed = loaded.fixed
                entry.scoped = loaded.scoped
                entry.windows = loaded.windows
            }

            entry.loadedThrough = [entry.fixed.first?.sampledAt, entry.scoped.first?.sampledAt]
                .compactMap { $0 }.max() ?? entry.loadedThrough
            PaceSeriesCache.shared.store(
                .init(fixed: entry.fixed, scoped: entry.scoped, windows: entry.windows,
                      loadedThrough: entry.loadedThrough),
                for: target.accountId)
            next.append(entry)
        }

        isLoading = false
        series = next

        Log.write("PaceChartCard",
                  "loaded \(next.count) series in "
                    + "\(Int(Date().timeIntervalSince(started) * 1000))ms ["
                    + next.map { ($0.accountId.map { String($0.suffix(4)) } ?? "all")
                                 + ":" + String($0.fixed.count + $0.scoped.count) }
                        .joined(separator: " ") + "]")
    }

    /// Which accounts this card should draw.
    ///
    /// A picked scope draws that account alone. "All accounts" draws the active
    /// login alone on a machine that runs its accounts one at a time — that
    /// account's limits are the only ones binding — and every account when they
    /// run in parallel, because then they all are. See `AccountParallelism`.
    private func loadTargets() -> [(accountId: String?, label: String?)] {
        guard UsageScope.shared.accountId == nil, accounts.count > 1, isParallel else {
            return [(limitAccountId, nil)]
        }
        return accounts
            .sorted { $0.isActive != $1.isActive ? $0.isActive : $0.id < $1.id }
            .map { (accountId: Optional($0.id), label: Optional($0.label)) }
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
        /// `"<accountId>|<windowKey>"`. Composite because the all-accounts view
        /// can list several accounts' windows at once and two of them share a
        /// window key — without the account, projections and taps would land on
        /// the wrong column.
        let id: String
        let accountId: String?
        let windowKey: String
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
    private func bucketed(_ entry: AccountSeries) -> Bucketed {
        var b = Bucketed()
        for s in entry.fixed {
            if s.window == RateLimitWindowName.fiveHour { b.fiveHour.append(s) }
            else if s.window == RateLimitWindowName.sevenDay { b.sevenDay.append(s) }
            if s.sampledAt > (b.latest?.sampledAt ?? .distantPast) { b.latest = s }
        }
        return b
    }

    /// True once any series has a reading — the card's "there is something to
    /// draw" test, replacing the single-account `b.latest != nil`.
    private var hasAnyReading: Bool {
        series.contains { bucketed($0).latest != nil || !$0.windows.latestBatch().isEmpty }
    }

    /// The scoped rows to render, one per model/surface-scoped identity in the
    /// latest poll, ordered active-first then hottest (the `latestBatch` order).
    /// Account-wide `session`/`weekly_all` rows are excluded — the fixed 5h/7d
    /// hero columns already own those (Decision C).
    /// Already filtered to model/surface-scoped identities by the loader — the
    /// account-wide `session`/`weekly_all` rows the fixed 5h/7d heroes own are
    /// excluded in the fetch predicate (Decision C).
    private func scopedRows(_ entry: AccountSeries) -> [ScopedWindowRow] {
        entry.windows.latestBatch()
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
    /// Every column, across every account being drawn.
    ///
    /// Within an account the existing order is unchanged. Across accounts the
    /// groups stay whole — an account's windows are read together, and
    /// interleaving 5h(work), 5h(personal), 7d(work)… would make the card a
    /// puzzle. The active login leads.
    private func columns(now: Date) -> [Column] {
        typealias Side = PaceColumnLayout.Side
        var out: [Column] = []
        for entry in series {
            let b = bucketed(entry)
            var tagged: [(side: Side, col: Column)] = [
                (.fiveHour, fixedColumn(entry, title: "5-hour", key: RateLimitWindowName.fiveHour,
                                        duration: Self.fiveHourDuration, samples: b.fiveHour, now: now)),
                (.sevenDay, fixedColumn(entry, title: "7-day", key: RateLimitWindowName.sevenDay,
                                        duration: Self.sevenDayDuration, samples: b.sevenDay, now: now)),
            ]
            for row in scopedRows(entry) {
                let duration = WindowSpec.scopedDuration(group: row.group)
                let severity: Column.SeverityTag? = row.severityValue.isElevated
                    ? .init(text: row.severity.lowercased(), band: row.displayBand)
                    : nil
                let side = PaceColumnLayout.scopedSide(
                    group: row.group, duration: duration,
                    fiveHourDuration: Self.fiveHourDuration, sevenDayDuration: Self.sevenDayDuration)
                tagged.append((side, Column(
                    id: Self.columnID(entry.accountId, row.identity),
                    accountId: entry.accountId, windowKey: row.identity,
                    title: Self.decorate(row.label, with: entry.label),
                    duration: duration,
                    usedPct: row.percent, resetsAt: row.resetsAt,
                    baseChart: .cycle(scoped: row, history: entry.scoped,
                                      duration: duration, now: now),
                    isActive: row.isActive, severity: severity, isScoped: true)))
            }
            out += tagged
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
        return out
    }

    static func columnID(_ accountId: String?, _ windowKey: String) -> String {
        "\(accountId ?? "")|\(windowKey)"
    }

    /// Only decorated when more than one account is on screen — a single
    /// account's card reads exactly as it always did.
    private static func decorate(_ title: String, with label: String?) -> String {
        guard let label else { return title }
        return "\(title) · \(label)"
    }

    private func fixedColumn(_ entry: AccountSeries, title: String, key: String,
                             duration: TimeInterval,
                             samples: [LimitSamplePoint], now: Date) -> Column {
        let latest = samples.first
        return Column(
            id: Self.columnID(entry.accountId, key),
            accountId: entry.accountId, windowKey: key,
            title: Self.decorate(title, with: entry.label), duration: duration,
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
    private func refreshProjections() async {
        guard let engines else { return }
        let started = Date()
        // One ask per account, against that account's own fit. Keys are the
        // composite column ids, so two accounts' 5-hour answers cannot
        // overwrite each other.
        let plan: [(accountId: String?, scoped: [String])] = series.map {
            ($0.accountId, scopedRows($0).map(\.identity))
        }
        var nextSelected: [String: WindowProjection] = [:]
        var nextOutlooks: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
        var nextEnds: [String: Estimate] = [:]

        for entry in plan {
            let engine = engines.engine(forAccount: entry.accountId)
            let account = entry.accountId
            let scoped = entry.scoped
            let computed = await askEngine {
                () -> ([String: WindowProjection],
                       [String: UsageIntelligenceEngine.BurnOutlook],
                       [String: Estimate]) in
                var sel: [String: WindowProjection] = [:]
                var out: [String: UsageIntelligenceEngine.BurnOutlook] = [:]
                var ends: [String: Estimate] = [:]
                func absorb(key: String, outlook: UsageIntelligenceEngine.BurnOutlook?,
                            end: Estimate, list: [BurnTrajectory.ScoredTrajectory]) {
                    let id = Self.columnID(account, key)
                    if let outlook { out[id] = outlook }
                    ends[id] = end
                    if let chosen = list.first(where: { $0.isSelected }) ?? list.first {
                        sel[id] = WindowProjection(trajectory: chosen.trajectory)
                    }
                }
                for window in RateLimitWindowKind.allCases {
                    absorb(key: window.rawValue,
                           outlook: await engine.burnOutlook(window: window),
                           end: await engine.ask(.rateLimitOutlook(window)),
                           list: await engine.rateLimitTrajectories(window: window))
                }
                for id in scoped {
                    absorb(key: id,
                           outlook: await engine.burnOutlook(windowKey: id),
                           end: await engine.ask(.scopedOutlook(id)),
                           list: await engine.rateLimitTrajectories(windowKey: id))
                }
                return (sel, out, ends)
            }
            nextSelected.merge(computed.0) { _, new in new }
            nextOutlooks.merge(computed.1) { _, new in new }
            nextEnds.merge(computed.2) { _, new in new }
        }

        projections = nextSelected
        outlooks = nextOutlooks
        endEstimates = nextEnds
        Log.write("PaceChartCard",
                  "projections for \(nextEnds.count) window(s) across \(plan.count) account(s) in "
                    + "\(Int(Date().timeIntervalSince(started) * 1000))ms")
    }

    // MARK: - Body

    var body: some View {
        let t0 = Date()
        let now = Date()
        let cols = columns(now: now)
        let buildMs = Int(Date().timeIntervalSince(t0) * 1000)
        if buildMs >= 100 {
            let points = series.reduce(0) { $0 + $1.fixed.count + $1.scoped.count }
            Log.write("PaceChartCard",
                      "body build \(buildMs)ms for \(points) point(s)"
                        + " → \(cols.map { $0.baseChart?.points.count ?? 0 }) plotted")
        }
        // Stable key so `.task(id:)` re-runs the engine ask when the window set
        // changes (a scoped window appears / disappears, or an account joins).
        let windowKey = cols.map(\.id).joined(separator: ",")
        let hasScoped = cols.contains { $0.isScoped }

        // The "via oauth · just now" freshness chip lives in the page header
        // (`RateLimitSourceChip` in DashboardView) — it describes the whole
        // dashboard's data feed, not this card alone.
        return PacerCard("Rate-limit pace") {
            if isLoading && !hasAnyReading {
                loadingState
            } else if !hasAnyReading {
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
                if let limitOwnerNote {
                    Text(limitOwnerNote)
                }
                if hasScoped {
                    Text("Per-model windows Anthropic reports for this account, forecast the same way as the 5-hour and 7-day pace — projected fill, time-to-limit, and calibrated bands. A dot marks the window currently in effect. Tap any window to compare every forecast model.")
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
            series = []
            Task { await reload() }
        }
        .task(id: windowKey) { await refreshProjections() }
        .onReceive(NotificationCenter.default.publisher(for: .pacerEngineDidRecompute)) { _ in
            Task { await refreshProjections() }
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
    var onCompare: ((String, String?) -> Void)?

    /// Share affordance state. `hovering` reveals the share button only while
    /// the cursor is over the column (Linear/Things idiom); `sharing` drives the
    /// preview popover.
    @State private var hovering = false
    @State private var sharing = false

    private var windowKey: String { column.windowKey }
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
            Button { onCompare(windowKey, column.accountId) } label: {
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
