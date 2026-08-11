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
    @State private var samples: [RateLimitSample] = []

    /// The newest scoped `limits[]` rows, newest first — just enough to resolve
    /// the latest poll's batch, which is what decides the scoped column set.
    /// Whole rows: the label, group→duration, binding flag and severity all
    /// read fields a columnar projection wouldn't fetch.
    @Query(PaceChartCard.scopedLatestDescriptor) private var scopedLatest: [UsageLimitSample]

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
    @State private var scopedHistory: [UsageLimitSample] = []

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

    /// Measured content width of the multi-window grid, fed by a background
    /// `GeometryReader`, so the balanced column count adapts to the pane. 0
    /// until the first layout pass resolves it (the grid falls back to a
    /// single column for that first frame, then corrects).
    @State private var gridWidth: CGFloat = 0

    struct WindowProjection: Equatable, Sendable {
        /// The selected model's raw forward trajectory (origin = the engine's
        /// last-refit snapshot). Re-anchored onto the live actual tail at
        /// render time in `liveChartData` so the dashed line continues the
        /// solid one seamlessly.
        var trajectory: BurnTrajectory.Trajectory
    }

    init(onCompare: ((String) -> Void)? = nil) {
        self.onCompare = onCompare
        // Only the signal is a `@Query`. One row, so re-running it on every
        // save costs nothing; the series it guards are loaded in `reload()`.
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

    @MainActor
    private func reload() {
        let cutoff = Date().addingTimeInterval(-8 * 86400)

        // Incremental. A poll adds a handful of rows to an 8-day window of
        // ~25,700, so re-reading the whole window each time re-materialized
        // ~25,700 rows to learn about ~3. Once the per-save churn was fixed
        // this became the largest remaining consumer in the process.
        //
        // Newest-first order is preserved by prepending, which is also why the
        // fetch below is ordered the same way.
        if let through = loadedThrough {
            var fresh = FetchDescriptor<RateLimitSample>(
                predicate: #Predicate<RateLimitSample> { $0.sampledAt > through },
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
            )
            fresh.propertiesToFetch = [\.window, \.sampledAt, \.resetsAt, \.usedPercentage]
            let added = (try? modelContext.fetch(fresh)) ?? []
            if !added.isEmpty { samples = added + samples }

            var freshScoped = FetchDescriptor<UsageLimitSample>(
                predicate: #Predicate<UsageLimitSample> { $0.sampledAt > through },
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
            )
            freshScoped.propertiesToFetch = [\.identity, \.sampledAt, \.resetsAt, \.percent]
            let addedScoped = (try? modelContext.fetch(freshScoped)) ?? []
            if !addedScoped.isEmpty { scopedHistory = addedScoped + scopedHistory }

            // Drop what has aged out, so the window stays 8 days rather than
            // growing for as long as Pacer is open.
            samples.removeAll { $0.sampledAt < cutoff }
            scopedHistory.removeAll { $0.sampledAt < cutoff }
        } else {
            var descriptor = FetchDescriptor<RateLimitSample>(
                predicate: #Predicate<RateLimitSample> { $0.sampledAt >= cutoff },
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
            )
            // Columnar projection: the card reads only these four scalars.
            descriptor.propertiesToFetch = [\.window, \.sampledAt, \.resetsAt, \.usedPercentage]
            samples = (try? modelContext.fetch(descriptor)) ?? []

            var scopedDescriptor = FetchDescriptor<UsageLimitSample>(
                predicate: #Predicate<UsageLimitSample> { $0.sampledAt >= cutoff },
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
            )
            scopedDescriptor.propertiesToFetch = [\.identity, \.sampledAt, \.resetsAt, \.percent]
            scopedHistory = (try? modelContext.fetch(scopedDescriptor)) ?? []
        }

        let newestLoaded = [samples.first?.sampledAt, scopedHistory.first?.sampledAt]
            .compactMap { $0 }.max()
        if let newestLoaded { loadedThrough = newestLoaded }
    }

    /// Newest scoped rows, whole, capped well above any plausible `limits[]`
    /// count so one poll's batch always fits.
    private static let scopedLatestDescriptor: FetchDescriptor<UsageLimitSample> = {
        var d = FetchDescriptor<UsageLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 120
        return d
    }()

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
        var fiveHour: [RateLimitSample] = []
        var sevenDay: [RateLimitSample] = []
        var latest: RateLimitSample?
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
    private var scopedRows: [UsageLimitSample] {
        scopedLatest.latestBatch().filter {
            ($0.modelId?.isEmpty == false)
                || ($0.modelDisplayName?.isEmpty == false)
                || ($0.surface?.isEmpty == false)
        }
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
                             samples: [RateLimitSample], now: Date) -> Column {
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
        guard let engine else { return }
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
    }

    // MARK: - Body

    var body: some View {
        let b = bucketed
        let now = Date()
        let cols = columns(b, now: now)
        let scopedIds = scopedRows.map(\.identity)
        // Stable key so `.task(id:)` re-runs the engine ask when the window set
        // changes (a scoped window appears / disappears).
        let windowKey = cols.map(\.id).joined(separator: ",")
        let hasScoped = cols.contains { $0.isScoped }

        // The "via oauth · just now" freshness chip lives in the page header
        // (`RateLimitSourceChip` in DashboardView) — it describes the whole
        // dashboard's data feed, not this card alone.
        return PacerCard("Rate-limit pace") {
            if b.latest == nil && scopedRows.isEmpty {
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
                let colCount = PaceColumnLayout.columnCount(
                    itemCount: cols.count, availableWidth: Double(gridWidth),
                    minItemWidth: 250, spacing: 24)
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 24, alignment: .top),
                        count: colCount),
                    alignment: .leading, spacing: 22
                ) {
                    ForEach(cols) { column($0) }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: PaceGridWidthKey.self, value: geo.size.width)
                    }
                )
                .onPreferenceChange(PaceGridWidthKey.self) { gridWidth = $0 }
            }
        } footer: {
            if hasScoped {
                Text("Per-model windows Anthropic reports for this account, forecast the same way as the 5-hour and 7-day pace — projected fill, time-to-limit, and calibrated bands. A dot marks the window currently in effect. Tap any window to compare every forecast model.")
            }
        }
        // Reload the 8-day series when a NEW rate-limit sample lands (the
        // poller writes roughly every five minutes), not on every context
        // change. `.task(id:)` also fires once on appear, which seeds them.
        .task(id: reloadSignal) { reload() }
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

/// Carries the multi-window grid's measured content width up to the card so the
/// balanced column count (`PaceColumnLayout.columnCount`) can react to the pane
/// resizing. The grid always fills the available width regardless of its column
/// count, so measuring it introduces no layout feedback loop.
private struct PaceGridWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
