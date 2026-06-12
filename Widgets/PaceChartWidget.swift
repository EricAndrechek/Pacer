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
    /// User's chosen window from the widget's intent config. Drives the
    /// view's branching (full-canvas single window vs side-by-side both).
    let window: PaceWindowOption

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
            window: .both
        )
    }

    func snapshot(for configuration: PaceChartConfigurationIntent, in context: Context) async -> PaceChartEntry {
        currentEntry(window: configuration.window)
    }

    func timeline(for configuration: PaceChartConfigurationIntent, in context: Context) async -> Timeline<PaceChartEntry> {
        let entry = currentEntry(window: configuration.window)
        let next = Date().addingTimeInterval(K.refreshSeconds)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func currentEntry(window: PaceWindowOption) -> PaceChartEntry {
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
            return PaceChartEntry(date: Date(), fiveHour: five, sevenDay: seven, window: window)
        } catch {
            return PaceChartEntry(date: Date(), fiveHour: nil, sevenDay: nil, window: window)
        }
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
                projection = pts
                crossing = outlook.crossingDate
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
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:  small
        case .systemLarge:  large
        default:            medium
        }
    }

    /// Title for the dual-window header / fallback. Single-window
    /// configurations use a tighter title in the small/medium layouts
    /// where the title bar IS the only header.
    private var dualTitle: String { "RATE-LIMIT PACE" }

    /// Resolve the small canvas's single window. Small physically can't
    /// fit two charts, so when the user picks `.both` we fall through
    /// to 5-hour — that's the cycle people hit first and watch most.
    private func smallTarget() -> (state: PaceChartEntry.WindowState?, title: String, duration: TimeInterval) {
        switch entry.window {
        case .sevenDay:
            return (entry.sevenDay, "7-DAY PACE", K.sevenDaySeconds)
        case .fiveHour, .both:
            return (entry.fiveHour, "5-HOUR PACE", K.fiveHourSeconds)
        }
    }

    @ViewBuilder
    private var small: some View {
        let target = smallTarget()
        let awaiting = target.state?.isAwaiting == true
        VStack(alignment: .leading, spacing: 4) {
            WidgetTitleBar(
                title: target.title,
                dotColor: awaiting ? .secondary : target.state?.band.color
            ) {
                if let s = target.state, !s.isAwaiting {
                    paceFraction(used: s.chart.usedPct, pace: s.paceEndPct, compact: true)
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
            if entry.fiveHour == nil && entry.sevenDay == nil {
                WidgetEmptyState(message: "Waiting for the first rate-limit reading.")
            } else {
                switch entry.window {
                case .both:
                    HStack(alignment: .top, spacing: 12) {
                        column(label: "5-hour", state: entry.fiveHour, style: .compact)
                        Divider()
                        column(label: "7-day", state: entry.sevenDay, style: .compact)
                    }
                case .fiveHour:
                    // One window, full width — chart gets ~290pt instead
                    // of ~148pt, so we promote to `.detailed` (axis ticks
                    // + 0/50/100% labels) for a layout that mirrors the
                    // dashboard pace card.
                    column(label: "5-hour", state: entry.fiveHour, style: .detailed)
                case .sevenDay:
                    column(label: "7-day", state: entry.sevenDay, style: .detailed)
                }
            }
        }
        .padding(WidgetStyle.mediumPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetCardBackground, for: .widget)
    }

    @ViewBuilder
    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetTitleBar(title: dualTitle)
            if entry.fiveHour == nil && entry.sevenDay == nil {
                WidgetEmptyState(message: "Waiting for the first rate-limit reading.")
            } else {
                switch entry.window {
                case .both:
                    largeRow(label: "5-hour", state: entry.fiveHour)
                    Divider()
                    largeRow(label: "7-day", state: entry.sevenDay)
                case .fiveHour:
                    largeRow(label: "5-hour", state: entry.fiveHour)
                case .sevenDay:
                    largeRow(label: "7-day", state: entry.sevenDay)
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
    private func largeRow(label: String, state: PaceChartEntry.WindowState?) -> some View {
        let awaiting = state?.isAwaiting == true
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(awaiting ? Color.secondary : (state?.band.color ?? .secondary))
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if let state, !state.isAwaiting {
                    paceFraction(used: state.chart.usedPct, pace: state.paceEndPct, compact: false)
                }
            }
            if let state, !state.isAwaiting {
                // Large widget gets the dashboard treatment — axes and
                // full label typography. With `.detailed` the chart
                // looks identical to the app card.
                PaceChartView(data: state.chart, style: .detailed)
                    .frame(maxHeight: .infinity)
                Text(pacerResetCaption(
                    resetsAt: state.resetsAt,
                    durationSeconds: state.chart.durationSeconds
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
        .description("Your usage line traced against the dashed pace target. 5-hour and 7-day windows.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        // Opt out of the system's default ~16pt content margin so our
        // own `WidgetStyle.*Pad` is the only inset. Without this, every
        // widget got system-padding + ours stacked, leaving content
        // visibly cramped vs first-party widgets that hug the canvas.
        .contentMarginsDisabled()
    }
}
