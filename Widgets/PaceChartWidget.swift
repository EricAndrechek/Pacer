import WidgetKit
import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Cycle-anchored pace chart widget. The chart itself is the shared
/// `PacerUI.PaceChartView` — exact same SwiftUI view the dashboard's
/// `PaceChartCard` renders, so the widgets are pixel-identical to the
/// app card. This file is just data-fetching + family-aware layout
/// scaffolding.

private enum K {
    static let fiveHourSeconds: TimeInterval = 5 * 3600
    static let sevenDaySeconds: TimeInterval = 7 * 86400
    /// Refresh every 5 minutes — same cadence as the OAuth poller.
    static let refreshSeconds: TimeInterval = 300
}

// MARK: - Entry

struct PaceChartEntry: TimelineEntry {
    let date: Date
    let fiveHour: WindowState?
    let sevenDay: WindowState?
    /// Used % for a window whose latest reading carries no reset time —
    /// the window is idle (0% used; the server returns `resets_at: null`
    /// until your first message of a window anchors the clock). Set only
    /// when the matching `WindowState` is nil for that reason; stays nil
    /// when there's genuinely no sample yet, so the view can tell an idle
    /// window ("No usage yet") apart from a cold start ("collecting…").
    /// See #100.
    var fiveHourIdle: Double? = nil
    var sevenDayIdle: Double? = nil
    /// Scoped per-model windows (`limits[]`), ordered active-first then
    /// hottest, so the large family can render them as first-class rows
    /// alongside 5h/7d. Empty when the account has no scoped windows — in
    /// which case every layout is byte-for-byte unchanged.
    var scoped: [ScopedState] = []
    /// The user's selected windows, already resolved by the provider to keys
    /// that exist in this entry (fallback applied). `primaryKey` drives the
    /// small canvas and the first medium column; `secondaryKey` the second
    /// medium column. The large family shows every window and ignores both.
    /// Default config resolves to `five_hour` / `seven_day`, reproducing the
    /// old `both` behaviour byte-for-byte.
    let primaryKey: String
    let secondaryKey: String

    /// One window's worth of pace data, paired down to what the shared
    /// `PaceChartView` consumes plus the metadata the widget needs for
    /// reset captions and band classification.
    struct WindowState {
        let chart: PaceChartView.Data
        let resetsAt: Date

        /// Active-vs-awaiting bracket. When awaiting, the widget should
        /// render its empty-state treatment instead of the chart + %s
        /// (see #4 — prior-cycle numbers aren't meaningful once the
        /// cycle has ended).
        var cycle: DisplayCycle {
            DisplayCycle.resolve(resetsAt: resetsAt, duration: chart.durationSeconds)
        }

        var isAwaiting: Bool { cycle.isAwaiting }

        var paceEndPct: Double { cycle.paceFraction * 100 }

        var band: PaceBand {
            PaceBand(usedPct: chart.usedPct, paceEndPct: paceEndPct)
        }
    }

    /// One scoped per-model window — a `WindowState` plus the row label and the
    /// binding flag (the "currently in effect" hint). Same forecast bundle as
    /// the fixed windows, keyed to a live `limits[]` identity. `key` is that
    /// identity, so a selection stored by the config intent matches back here.
    struct ScopedState {
        let key: String
        let label: String
        let state: WindowState
        let isActive: Bool
    }

    /// A window resolved for rendering — its label, forecast state, idle
    /// reading, cycle duration, and active flag, looked up by key. Fixed keys
    /// map to the 5h/7d slots; a scoped key matches `scoped` by identity; an
    /// unknown key (a selected window that vanished) falls back to 5-hour so a
    /// stale selection never blanks.
    struct Resolved {
        let label: String
        let state: WindowState?
        let idle: Double?
        let duration: TimeInterval
        let isActive: Bool
    }

    func resolve(_ key: String) -> Resolved {
        switch key {
        case "five_hour":
            return Resolved(label: "5-hour", state: fiveHour, idle: fiveHourIdle,
                            duration: K.fiveHourSeconds, isActive: false)
        case "seven_day":
            return Resolved(label: "7-day", state: sevenDay, idle: sevenDayIdle,
                            duration: K.sevenDaySeconds, isActive: false)
        default:
            if let s = scoped.first(where: { $0.key == key }) {
                return Resolved(label: s.label, state: s.state, idle: nil,
                                duration: s.state.chart.durationSeconds, isActive: s.isActive)
            }
            return Resolved(label: "5-hour", state: fiveHour, idle: fiveHourIdle,
                            duration: K.fiveHourSeconds, isActive: false)
        }
    }
}

// MARK: - Provider

struct PaceChartProvider: AppIntentTimelineProvider {
    typealias Intent = PaceChartConfigurationIntent
    typealias Entry = PaceChartEntry

    func placeholder(in context: Context) -> PaceChartEntry {
        PaceChartEntry(
            date: Date(),
            fiveHour: Self.demoState(duration: K.fiveHourSeconds, usedPct: 38, sampleCount: 8),
            sevenDay: Self.demoState(duration: K.sevenDaySeconds, usedPct: 62, sampleCount: 12),
            primaryKey: "five_hour", secondaryKey: "seven_day"
        )
    }

    func snapshot(for configuration: PaceChartConfigurationIntent, in context: Context) async -> PaceChartEntry {
        currentEntry(primary: configuration.primaryWindow, secondary: configuration.secondaryWindow)
    }

    func timeline(for configuration: PaceChartConfigurationIntent, in context: Context) async -> Timeline<PaceChartEntry> {
        let entry = currentEntry(primary: configuration.primaryWindow, secondary: configuration.secondaryWindow)
        let next = Date().addingTimeInterval(K.refreshSeconds)
        return Timeline(entries: [entry], policy: .after(next))
    }

    /// Resolve the two selected windows to keys that exist in the just-built
    /// entry, applying the graceful fallback (primary → 5h; secondary → the
    /// other fixed window). Nil/absent selections reproduce today's 5h+7d.
    private static func resolveKeys(
        primary: PaceWindowEntity?, secondary: PaceWindowEntity?,
        scoped: [PaceChartEntry.ScopedState]
    ) -> (String, String) {
        var available: Set<String> = ["five_hour", "seven_day"]
        for s in scoped { available.insert(s.key) }
        let p = PaceWindowResolver.resolveKey(primary?.id, available: available, fallback: "five_hour")
        let secFallback = (p == "five_hour") ? "seven_day" : "five_hour"
        let s = PaceWindowResolver.resolveKey(secondary?.id, available: available, fallback: secFallback)
        return (p, s)
    }

    private func currentEntry(primary: PaceWindowEntity?, secondary: PaceWindowEntity?) -> PaceChartEntry {
        do {
            let container = try PacerStore.sharedModelContainer()
            let context = ModelContext(container)
            // 8-day window covers the longest cycle (7d) plus headroom
            // for the most-recent 5h cycle; same shape PaceChartCard
            // uses on the dashboard. The fetchLimit is generous (8d ×
            // ~12 samples/hr × 2 windows ≈ 4600) but caps any future
            // burst: a stuck poller or a backfill event won't blow up
            // widget refresh memory.
            let cutoff = Date().addingTimeInterval(-8 * 86400)
            var descriptor = FetchDescriptor<RateLimitSample>(
                predicate: #Predicate<RateLimitSample> { $0.sampledAt >= cutoff },
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
            )
            descriptor.fetchLimit = 6000
            let rows = try context.fetch(descriptor)
            // The engine's exported outlook (the app writes it after every
            // refit): the same dashed trajectory + crossing the dashboard
            // draws, so the widget matches instead of showing a bare line.
            let snapshot = Self.engineSnapshot(context: context)
            let five = Self.window(rows: rows, key: "five_hour", duration: K.fiveHourSeconds,
                                   outlook: snapshot?.fiveHour)
            let seven = Self.window(rows: rows, key: "seven_day", duration: K.sevenDaySeconds,
                                    outlook: snapshot?.sevenDay)
            let scoped = Self.scopedStates(context: context, snapshot: snapshot)
            let (primaryKey, secondaryKey) = Self.resolveKeys(primary: primary, secondary: secondary, scoped: scoped)
            return PaceChartEntry(
                date: Date(), fiveHour: five, sevenDay: seven,
                fiveHourIdle: five == nil ? Self.idleUsedPct(rows: rows, key: "five_hour") : nil,
                sevenDayIdle: seven == nil ? Self.idleUsedPct(rows: rows, key: "seven_day") : nil,
                scoped: scoped,
                primaryKey: primaryKey, secondaryKey: secondaryKey)
        } catch {
            let (primaryKey, secondaryKey) = Self.resolveKeys(primary: primary, secondary: secondary, scoped: [])
            return PaceChartEntry(date: Date(), fiveHour: nil, sevenDay: nil,
                                  primaryKey: primaryKey, secondaryKey: secondaryKey)
        }
    }

    /// The scoped per-model windows, as first-class `ScopedState`s ordered
    /// active-first then hottest. Fully dynamic — reads whatever scoped
    /// `limits[]` rows the poller persisted, keeps only the model/surface-scoped
    /// ones (Decision C), and layers the engine's exported per-identity
    /// projection. Empty (⇒ every layout unchanged) when the account has none.
    private static func scopedStates(context: ModelContext, snapshot: EngineSnapshot?) -> [PaceChartEntry.ScopedState] {
        // Recent scoped rows, newest first, bounded. Covers the latest batch
        // (the column set) plus a short actual-line tail per identity.
        var descriptor = FetchDescriptor<UsageLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        descriptor.fetchLimit = 600
        guard let history = try? context.fetch(descriptor) else { return [] }
        let batch = history.latestBatch().filter {
            ($0.modelId?.isEmpty == false)
                || ($0.modelDisplayName?.isEmpty == false)
                || ($0.surface?.isEmpty == false)
        }
        let outlookByIdentity = Dictionary(
            (snapshot?.scoped ?? []).map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
        return batch.compactMap {
            Self.scopedWindow(history: history, row: $0, outlook: outlookByIdentity[$0.identity])
        }
    }

    /// Used % for a window whose most-recent sample has no reset time —
    /// an idle window the server hasn't anchored yet. `nil` when there's
    /// no sample for the window at all (a genuine cold start), so the
    /// view can show "No usage yet" rather than "collecting…". See #100.
    private static func idleUsedPct(rows: [RateLimitSample], key: String) -> Double? {
        guard let latest = rows.first(where: { $0.window == key }) else { return nil }
        return latest.resetsAt == nil ? latest.usedPercentage : nil
    }

    /// Read + decode the engine's outlook export. `nil` when absent or stale
    /// (the app may not be running; an old projection is worse than none).
    private static func engineSnapshot(context: ModelContext) -> EngineSnapshot? {
        let key = EngineSnapshot.metaKey
        let descriptor = FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key })
        guard let json = try? context.fetch(descriptor).first?.value,
              let snapshot = EngineSnapshot.decode(json), snapshot.isFresh else { return nil }
        return snapshot
    }

    /// Filter all samples to one window key and bucket the most-recent
    /// cycle's samples into ascending order. Synthesizes a `now` tail
    /// so the line tracks to current time even if the latest poll
    /// was a few minutes ago.
    private static func window(
        rows: [RateLimitSample],
        key: String,
        duration: TimeInterval,
        outlook: EngineSnapshot.WindowOutlook? = nil
    ) -> PaceChartEntry.WindowState? {
        let windowRows = rows.filter { $0.window == key }
        guard let latest = windowRows.first, let resetsAt = latest.resetsAt else { return nil }
        let cycleStart = resetsAt.addingTimeInterval(-duration)
        let now = Date()
        var points = windowRows
            .inCycle(resetting: resetsAt, duration: duration)
            .filter { $0.sampledAt >= cycleStart && $0.sampledAt <= now }
            .sorted { $0.sampledAt < $1.sampledAt }
            .map { PaceChartView.Data.Point(time: $0.sampledAt, value: $0.usedPercentage) }
        // Clamp the synthesized tail to the cycle: once `now > resetsAt`
        // (cycle ended, no fresh sample yet), a tail at `now` falls
        // outside `chartXScale`'s domain.
        let tailTime = min(now, resetsAt)
        if points.last?.time != tailTime {
            points.append(.init(time: tailTime, value: latest.usedPercentage))
        }
        // Attach the engine's trajectory only when it belongs to THIS cycle
        // (same reset, ±2 min) — a snapshot from a previous cycle would draw
        // a nonsense overlay — and clip it to the chart's domain.
        var projection: [PaceChartView.Data.Point]?
        var crossing: Date?
        if let outlook, abs(outlook.resetsUnix - resetsAt.timeIntervalSince1970) < 120 {
            let pts = outlook.trajectory
                .map { PaceChartView.Data.Point(time: Date(timeIntervalSince1970: $0.t), value: $0.v) }
                .filter { $0.time >= cycleStart && $0.time <= resetsAt }
            if pts.count >= 2 {
                // Re-anchor onto this widget's synthesized tail (last plotted
                // actual point) so the dashed line continues the solid one —
                // the same fix the app chart uses. The persisted snapshot's
                // origin is often several minutes stale here, so the gap is
                // even larger than in-app.
                let r = BurnTrajectory.reanchor(
                    points: pts.map { ($0.time, $0.value) },
                    toTime: tailTime, value: latest.usedPercentage)
                let rebased = r.points.map { PaceChartView.Data.Point(time: $0.at, value: $0.value) }
                if rebased.count >= 2 {
                    projection = rebased
                    crossing = r.crossesFullAt
                }
            }
        }
        let chart = PaceChartView.Data(
            cycleStart: cycleStart,
            resetsAt: resetsAt,
            durationSeconds: duration,
            points: points,
            usedPct: latest.usedPercentage,
            projection: projection,
            projectionCrossesFullAt: crossing
        )
        return PaceChartEntry.WindowState(chart: chart, resetsAt: resetsAt)
    }

    /// One scoped window's `ScopedState` from its `UsageLimitSample` history +
    /// the engine's exported per-identity outlook. Mirrors `window(rows:…)`
    /// exactly — same current-cycle actuals, synthesized `now` tail, and
    /// re-anchored dashed projection — so a scoped row draws identically to
    /// 5h/7d, just keyed by identity instead of a fixed window name.
    private static func scopedWindow(
        history: [UsageLimitSample],
        row: UsageLimitSample,
        outlook: EngineSnapshot.ScopedWindowOutlook?
    ) -> PaceChartEntry.ScopedState? {
        guard let resetsAt = row.resetsAt else { return nil }
        let duration = WindowSpec.scopedDuration(group: row.group)
        let cycleStart = resetsAt.addingTimeInterval(-duration)
        let now = Date()
        var points = history
            .filter { $0.identity == row.identity && $0.resetsAt == resetsAt
                   && $0.sampledAt >= cycleStart && $0.sampledAt <= now }
            .sorted { $0.sampledAt < $1.sampledAt }
            .map { PaceChartView.Data.Point(time: $0.sampledAt, value: $0.percent) }
        let tailTime = min(now, resetsAt)
        if points.last?.time != tailTime {
            points.append(.init(time: tailTime, value: row.percent))
        }
        guard !points.isEmpty else { return nil }
        var projection: [PaceChartView.Data.Point]?
        var crossing: Date?
        if let o = outlook?.outlook, abs(o.resetsUnix - resetsAt.timeIntervalSince1970) < 120 {
            let pts = o.trajectory
                .map { PaceChartView.Data.Point(time: Date(timeIntervalSince1970: $0.t), value: $0.v) }
                .filter { $0.time >= cycleStart && $0.time <= resetsAt }
            if pts.count >= 2 {
                let r = BurnTrajectory.reanchor(
                    points: pts.map { ($0.time, $0.value) },
                    toTime: tailTime, value: row.percent)
                let rebased = r.points.map { PaceChartView.Data.Point(time: $0.at, value: $0.value) }
                if rebased.count >= 2 { projection = rebased; crossing = r.crossesFullAt }
            }
        }
        let chart = PaceChartView.Data(
            cycleStart: cycleStart, resetsAt: resetsAt, durationSeconds: duration,
            points: points, usedPct: row.percent,
            projection: projection, projectionCrossesFullAt: crossing)
        return PaceChartEntry.ScopedState(
            key: row.identity,
            label: row.label,
            state: PaceChartEntry.WindowState(chart: chart, resetsAt: resetsAt),
            isActive: row.isActive)
    }

    /// Synthetic data for the gallery placeholder — gentle ramp from
    /// 0 to `usedPct` so users see what the chart looks like without
    /// real samples.
    private static func demoState(
        duration: TimeInterval,
        usedPct: Double,
        sampleCount: Int
    ) -> PaceChartEntry.WindowState {
        let now = Date()
        let resets = now.addingTimeInterval(duration * 0.55)
        let cycleStart = resets.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(cycleStart)
        let stepInterval = elapsed / Double(max(1, sampleCount - 1))
        let points = (0..<sampleCount).map { i in
            let t = cycleStart.addingTimeInterval(Double(i) * stepInterval)
            // Mild concave ramp so it doesn't look perfectly linear.
            let frac = Double(i) / Double(max(1, sampleCount - 1))
            return PaceChartView.Data.Point(
                time: t,
                value: usedPct * (frac * (1.05 - 0.05 * frac))
            )
        }
        let chart = PaceChartView.Data(
            cycleStart: cycleStart,
            resetsAt: resets,
            durationSeconds: duration,
            points: points,
            usedPct: usedPct
        )
        return PaceChartEntry.WindowState(chart: chart, resetsAt: resets)
    }
}

// MARK: - View

struct PaceChartWidgetView: View {
    let entry: PaceChartEntry
    /// Screenshot/preview override — `widgetFamily` is a read-only environment
    /// value at runtime, so the headless capture harness can't inject a family.
    /// Left nil in the real widget, where the environment drives the layout.
    var forcedFamily: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch forcedFamily ?? family {
        case .systemSmall:  small
        case .systemLarge:  large
        default:            medium
        }
    }

    /// Title for the dual-window header / fallback. Single-window
    /// configurations use a tighter title in the small/medium layouts
    /// where the title bar IS the only header.
    private var dualTitle: String { "RATE-LIMIT PACE" }

    /// No window has anything to show — neither a chart nor an idle
    /// reading. Drives the single cold-start empty state in medium/large.
    private var hasNoReadings: Bool {
        entry.fiveHour == nil && entry.sevenDay == nil
            && entry.fiveHourIdle == nil && entry.sevenDayIdle == nil
            && entry.scoped.isEmpty
    }

    /// Max window rows the large canvas renders legibly. 5h + 7d + up to two
    /// scoped windows; charts stay readable at this density and beyond it the
    /// per-row height collapses.
    private static let largeRowCap = 4

    /// One large-canvas row: a fixed window (5h/7d) or a scoped per-model
    /// window, uniformly. `isActive` marks the scoped window in effect.
    private struct LargeWindow: Identifiable {
        let id: String
        let label: String
        let state: PaceChartEntry.WindowState?
        let idle: Double?
        let isActive: Bool
    }

    /// The ordered large-canvas rows: always 5-hour + 7-day first, then scoped
    /// windows (active/hottest first) filling the remaining capacity. Large is
    /// the all-windows view — the small/medium window selection doesn't narrow
    /// it. With no scoped windows this is the fixed 5h/7d pair, unchanged.
    private var largeWindows: [LargeWindow] {
        var out: [LargeWindow] = [
            .init(id: "five_hour", label: "5-hour",
                  state: entry.fiveHour, idle: entry.fiveHourIdle, isActive: false),
            .init(id: "seven_day", label: "7-day",
                  state: entry.sevenDay, idle: entry.sevenDayIdle, isActive: false),
        ]
        for s in entry.scoped.prefix(max(0, Self.largeRowCap - out.count)) {
            out.append(.init(id: s.label, label: s.label,
                             state: s.state, idle: nil, isActive: s.isActive))
        }
        return out
    }

    /// The bare used % shown for an idle window — a reading exists but no
    /// pace target to divide against (no anchored cycle), so just the
    /// number, in `paceFraction`'s numeral styling. See #100.
    @ViewBuilder
    private func idleNumber(_ used: Double, large: Bool = false) -> some View {
        Text("\(Int(used.rounded()))%")
            .font(.system(size: large ? 22 : 16, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var small: some View {
        // Small physically can't fit two charts, so it renders the single
        // primary window. Default primary is 5-hour — the cycle people hit
        // first and watch most — so the default small is unchanged.
        let target = entry.resolve(entry.primaryKey)
        let awaiting = target.state?.isAwaiting == true
        VStack(alignment: .leading, spacing: 4) {
            WidgetTitleBar(
                title: "\(target.label.uppercased()) PACE",
                dotColor: awaiting ? .secondary : target.state?.band.color
            ) {
                if let s = target.state, !s.isAwaiting {
                    paceFraction(used: s.chart.usedPct, pace: s.paceEndPct, compact: true)
                } else if let idle = target.idle {
                    idleNumber(idle)
                }
            }
            if let s = target.state, !s.isAwaiting {
                // Caption sits between the title bar and the chart so it
                // gets the full column width (~134pt) instead of fighting
                // for space below the chart's `maxHeight: .infinity`.
                // `compact: true` shortens "in 2 hr. · 10:23 AM" to
                // "in 2h · 10p" so the 7-day form (~22 chars) clears the
                // single-line budget on a 158pt small canvas.
                Text(pacerResetCaption(
                    resetsAt: s.resetsAt,
                    durationSeconds: s.chart.durationSeconds,
                    compact: true
                ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                PaceChartView(data: s.chart, style: .compact)
                    .frame(maxHeight: .infinity)
            } else if awaiting {
                WidgetEmptyState(message: "Cycle reset. Awaiting fresh sample.")
            } else if target.idle != nil {
                WidgetEmptyState(message: "No usage yet. The window starts when you next use Claude.")
            } else {
                WidgetEmptyState(message: "Waiting for the first rate-limit reading.")
            }
        }
        .padding(WidgetStyle.smallPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetCardBackground, for: .widget)
    }

    @ViewBuilder
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitleBar(title: dualTitle)
            if hasNoReadings {
                WidgetEmptyState(message: "Waiting for the first rate-limit reading.")
            } else {
                // Medium is the two-card layout: the primary and secondary
                // windows side by side. Default (5h + 7d) is byte-unchanged;
                // pick e.g. 5h + Fable to swap the second card.
                let a = entry.resolve(entry.primaryKey)
                let b = entry.resolve(entry.secondaryKey)
                HStack(alignment: .top, spacing: 12) {
                    column(label: a.label, state: a.state, idle: a.idle, style: .compact)
                    Divider()
                    column(label: b.label, state: b.state, idle: b.idle, style: .compact)
                }
            }
        }
        .padding(WidgetStyle.mediumPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetCardBackground, for: .widget)
    }

    @ViewBuilder
    private var large: some View {
        let windows = largeWindows
        // >2 rows can't each keep the full detailed-chart height, so the whole
        // stack goes compact. With no scoped windows this is always ≤2 rows and
        // the detailed treatment is unchanged.
        let dense = windows.count > 2
        // How many scoped windows didn't fit — surfaced as a trailing "+N".
        let shownScoped = windows.filter { $0.id != "five_hour" && $0.id != "seven_day" }.count
        let overflow = max(0, entry.scoped.count - shownScoped)
        VStack(alignment: .leading, spacing: dense ? 6 : 10) {
            WidgetTitleBar(title: dualTitle) {
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if hasNoReadings {
                WidgetEmptyState(message: "Waiting for the first rate-limit reading.")
            } else {
                ForEach(Array(windows.enumerated()), id: \.element.id) { idx, w in
                    if idx > 0 { Divider() }
                    largeRow(label: w.label, state: w.state, idle: w.idle,
                             isActive: w.isActive, dense: dense)
                }
            }
        }
        .padding(WidgetStyle.largePad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetCardBackground, for: .widget)
    }

    @ViewBuilder
    private func column(
        label: String,
        state: PaceChartEntry.WindowState?,
        idle: Double? = nil,
        style: PaceChartView.Style
    ) -> some View {
        let awaiting = state?.isAwaiting == true
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(awaiting ? Color.secondary : (state?.band.color ?? .secondary))
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let state, !state.isAwaiting {
                paceFraction(used: state.chart.usedPct, pace: state.paceEndPct, compact: true)
                // Caption goes above the chart so it has the column's
                // full width (~148pt at medium) instead of being squeezed
                // by the chart filling vertically below. Compact format
                // keeps the 7-day form ("resets in 4d · Mon 3p", ~22
                // chars) inside the column width budget.
                Text(pacerResetCaption(
                    resetsAt: state.resetsAt,
                    durationSeconds: state.chart.durationSeconds,
                    compact: true
                ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                PaceChartView(data: state.chart, style: style)
                    .frame(maxHeight: .infinity)
            } else if awaiting {
                Text("cycle reset · awaiting sample")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else if let idle {
                idleNumber(idle)
                Text("idle · no usage yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else {
                Text("collecting…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func largeRow(label: String, state: PaceChartEntry.WindowState?, idle: Double? = nil,
                          isActive: Bool = false, dense: Bool = false) -> some View {
        let awaiting = state?.isAwaiting == true
        // The active scoped window's dot is drawn in the accent color so it
        // reads as "in effect" without a jargon label; the band-coloured %
        // beside it still carries urgency. Fixed rows are never active, so
        // their dot is unchanged.
        let dotColor: Color = isActive
            ? Color.accentColor
            : (awaiting ? Color.secondary : (state?.band.color ?? .secondary))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font((dense ? Font.caption : Font.subheadline).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if let state, !state.isAwaiting {
                    paceFraction(used: state.chart.usedPct, pace: state.paceEndPct, compact: dense)
                } else if let idle {
                    idleNumber(idle, large: !dense)
                }
            }
            if let state, !state.isAwaiting {
                // Large widget gets the dashboard treatment — axes and
                // full label typography. With `.detailed` the chart
                // looks identical to the app card; dense stacks drop to
                // `.compact` so every row keeps a legible height.
                PaceChartView(data: state.chart, style: dense ? .compact : .detailed)
                    .frame(maxHeight: .infinity)
                Text(pacerResetCaption(
                    resetsAt: state.resetsAt,
                    durationSeconds: state.chart.durationSeconds,
                    compact: dense
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if awaiting {
                Text("Cycle reset · awaiting first sample")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else if idle != nil {
                Text("No usage yet — the window starts when you next use Claude.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else {
                Text("collecting…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// "38% / 45%" — used vs theoretical pace endpoint, color-banded.
    @ViewBuilder
    private func paceFraction(used: Double, pace: Double, compact: Bool) -> some View {
        let band = PaceBand(usedPct: used, paceEndPct: pace)
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(Int(used.rounded()))%")
                .font(.system(size: compact ? 16 : 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(band.color)
            Text("/")
                .font(.system(size: compact ? 11 : 14))
                .foregroundStyle(.tertiary)
            Text("\(Int(pace.rounded()))%")
                .font(.system(size: compact ? 11 : 14, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Configuration

struct PaceChartWidget: Widget {
    let kind: String = WidgetKinds.paceChart

    var body: some WidgetConfiguration {
        // `AppIntentConfiguration` swaps the static layout for a user-
        // editable one: long-press the widget → "Edit Widget" → window
        // picker (5h / 7d / both). Provider is now async-form
        // `AppIntentTimelineProvider`; entry carries the chosen window
        // so the view can branch between full-canvas and split layouts.
        AppIntentConfiguration(
            kind: kind,
            intent: PaceChartConfigurationIntent.self,
            provider: PaceChartProvider()
        ) { entry in
            PaceChartWidgetView(entry: entry)
        }
        // Display name matches the dashboard card's title verbatim
        // ("Rate-limit pace") so the picker hits the user's existing
        // mental model — this is the dashboard's signature view, not
        // a separate concept.
        .configurationDisplayName("Rate-limit pace")
        // Literal description — no interpolation; learned the hard way
        // that LocalizedStringKey + interpolation crashes the bundle on
        // launch. See `Widgets/TopProjectsWidget.swift` history.
        .description("Your usage line traced against the dashed pace target. The 5-hour and 7-day windows, plus any per-model windows in the large size.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        // Opt out of the system's default ~16pt content margin so our
        // own `WidgetStyle.*Pad` is the only inset. Without this, every
        // widget got system-padding + ours stacked, leaving content
        // visibly cramped vs first-party widgets that hug the canvas.
        .contentMarginsDisabled()
    }
}
