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

    /// One window's worth of pace data, paired down to what the shared
    /// `PaceChartView` consumes plus the metadata the widget needs for
    /// reset captions and band classification.
    struct WindowState {
        let chart: PaceChartView.Data
        let resetsAt: Date

        var paceEndPct: Double {
            PaceMath.paceFraction(
                now: Date(),
                resetsAt: resetsAt,
                windowDuration: chart.durationSeconds
            ) * 100
        }

        var band: PaceBand {
            PaceBand(usedPct: chart.usedPct, paceEndPct: paceEndPct)
        }
    }
}

// MARK: - Provider

struct PaceChartProvider: TimelineProvider {
    func placeholder(in context: Context) -> PaceChartEntry {
        PaceChartEntry(
            date: Date(),
            fiveHour: Self.demoState(duration: K.fiveHourSeconds, usedPct: 38, sampleCount: 8),
            sevenDay: Self.demoState(duration: K.sevenDaySeconds, usedPct: 62, sampleCount: 12)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (PaceChartEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PaceChartEntry>) -> Void) {
        let entry = currentEntry()
        let next = Date().addingTimeInterval(K.refreshSeconds)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentEntry() -> PaceChartEntry {
        do {
            let container = try PacerStore.makeModelContainer()
            let context = ModelContext(container)
            // 8-day window covers the longest cycle (7d) plus headroom
            // for the most-recent 5h cycle; same shape PaceChartCard
            // uses on the dashboard.
            let cutoff = Date().addingTimeInterval(-8 * 86400)
            let descriptor = FetchDescriptor<RateLimitSample>(
                predicate: #Predicate<RateLimitSample> { $0.sampledAt >= cutoff },
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
            )
            let rows = try context.fetch(descriptor)
            let five = Self.window(rows: rows, key: "five_hour", duration: K.fiveHourSeconds)
            let seven = Self.window(rows: rows, key: "seven_day", duration: K.sevenDaySeconds)
            return PaceChartEntry(date: Date(), fiveHour: five, sevenDay: seven)
        } catch {
            return PaceChartEntry(date: Date(), fiveHour: nil, sevenDay: nil)
        }
    }

    /// Filter all samples to one window key and bucket the most-recent
    /// cycle's samples into ascending order. Synthesizes a `now` tail
    /// so the line tracks to current time even if the latest poll
    /// was a few minutes ago.
    private static func window(
        rows: [RateLimitSample],
        key: String,
        duration: TimeInterval
    ) -> PaceChartEntry.WindowState? {
        let windowRows = rows.filter { $0.window == key }
        guard let latest = windowRows.first, let resetsAt = latest.resetsAt else { return nil }
        let cycleStart = resetsAt.addingTimeInterval(-duration)
        let now = Date()
        var points = windowRows
            .filter { $0.sampledAt >= cycleStart && $0.sampledAt <= now }
            .sorted { $0.sampledAt < $1.sampledAt }
            .map { PaceChartView.Data.Point(time: $0.sampledAt, value: $0.usedPercentage) }
        if points.last?.time != now {
            points.append(.init(time: now, value: latest.usedPercentage))
        }
        let chart = PaceChartView.Data(
            cycleStart: cycleStart,
            resetsAt: resetsAt,
            durationSeconds: duration,
            points: points,
            usedPct: latest.usedPercentage
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

    @ViewBuilder
    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetTitleBar(
                title: "5-HOUR PACE",
                dotColor: entry.fiveHour?.band.color
            ) {
                if let s = entry.fiveHour {
                    paceFraction(used: s.chart.usedPct, pace: s.paceEndPct, compact: true)
                }
            }
            if let s = entry.fiveHour {
                PaceChartView(data: s.chart, style: .compact)
                    .frame(maxHeight: .infinity)
                Text(pacerResetCaption(
                    resetsAt: s.resetsAt,
                    durationSeconds: s.chart.durationSeconds
                ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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
            WidgetTitleBar(title: "RATE-LIMIT PACE")
            if entry.fiveHour == nil && entry.sevenDay == nil {
                WidgetEmptyState(message: "Waiting for the first rate-limit reading.")
            } else {
                HStack(alignment: .top, spacing: 12) {
                    column(label: "5-hour", state: entry.fiveHour, style: .compact)
                    Divider()
                    column(label: "7-day", state: entry.sevenDay, style: .compact)
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
            WidgetTitleBar(title: "RATE-LIMIT PACE")
            if entry.fiveHour == nil && entry.sevenDay == nil {
                WidgetEmptyState(message: "Waiting for the first rate-limit reading.")
            } else {
                largeRow(label: "5-hour", state: entry.fiveHour)
                Divider()
                largeRow(label: "7-day", state: entry.sevenDay)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(state?.band.color ?? .secondary)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let state {
                paceFraction(used: state.chart.usedPct, pace: state.paceEndPct, compact: true)
                PaceChartView(data: state.chart, style: style)
                    .frame(maxHeight: .infinity)
                Text(pacerResetCaption(
                    resetsAt: state.resetsAt,
                    durationSeconds: state.chart.durationSeconds
                ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state?.band.color ?? .secondary)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if let state {
                    paceFraction(used: state.chart.usedPct, pace: state.paceEndPct, compact: false)
                }
            }
            if let state {
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
    let kind: String = "PaceChartWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PaceChartProvider()) { entry in
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
    }
}
