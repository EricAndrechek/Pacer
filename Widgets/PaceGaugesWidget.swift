import WidgetKit
import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// At-a-glance rate-limit gauges. Small family: just the 5h gauge.
/// Medium: 5h + 7d side by side. Both surface the same data the
/// dashboard's `PaceChartCard` does, just compressed for widget canvas.
///
/// Color band tracks `PacerCore.UsageBand` (green/yellow/orange/red at
/// 50/75/90 thresholds) so the visual matches the menu-bar glyph and
/// Settings-tab thresholds.

struct PaceGaugesEntry: TimelineEntry {
    let date: Date
    let fiveHour: WindowState?
    let sevenDay: WindowState?
    /// Scoped per-model windows (`limits[]`), active-first then hottest — the
    /// large family renders them as ring gauges alongside 5h/7d. Empty when the
    /// account has none, so small/medium are unchanged.
    var scoped: [ScopedGauge] = []
    /// Window pick from the widget intent — same enum the pace chart
    /// widget uses, kept in lockstep so a user who chose "5-hour only"
    /// for one widget gets the same option set on the other.
    let window: PaceWindowOption

    struct WindowState {
        let usedPct: Double
        let resetsAt: Date?
    }

    /// One scoped per-model window's gauge: label + used% + reset, plus its
    /// group-derived duration (for the reset caption) and the binding flag.
    struct ScopedGauge {
        let label: String
        let usedPct: Double
        let resetsAt: Date?
        let durationSeconds: TimeInterval
        let isActive: Bool
    }
}

struct PaceGaugesProvider: AppIntentTimelineProvider {
    typealias Intent = PaceGaugesConfigurationIntent
    typealias Entry = PaceGaugesEntry

    func placeholder(in context: Context) -> PaceGaugesEntry {
        PaceGaugesEntry(
            date: Date(),
            fiveHour: .init(usedPct: 35, resetsAt: Date().addingTimeInterval(2 * 3600)),
            sevenDay: .init(usedPct: 62, resetsAt: Date().addingTimeInterval(4 * 86400)),
            window: .both
        )
    }

    func snapshot(for configuration: PaceGaugesConfigurationIntent, in context: Context) async -> PaceGaugesEntry {
        currentEntry(window: configuration.window)
    }

    func timeline(for configuration: PaceGaugesConfigurationIntent, in context: Context) async -> Timeline<PaceGaugesEntry> {
        let entry = currentEntry(window: configuration.window)
        let nextRefresh = Date().addingTimeInterval(300)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func currentEntry(window: PaceWindowOption) -> PaceGaugesEntry {
        do {
            let container = try PacerStore.sharedModelContainer()
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<RateLimitSample>(
                sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
            )
            descriptor.fetchLimit = 50
            let rows = try context.fetch(descriptor)
            let five = rows.first { $0.window == "five_hour" }
            let seven = rows.first { $0.window == "seven_day" }
            return PaceGaugesEntry(
                date: Date(),
                fiveHour: five.map { .init(usedPct: $0.usedPercentage, resetsAt: $0.resetsAt) },
                sevenDay: seven.map { .init(usedPct: $0.usedPercentage, resetsAt: $0.resetsAt) },
                scoped: Self.scopedGauges(context: context),
                window: window
            )
        } catch {
            return PaceGaugesEntry(date: Date(), fiveHour: nil, sevenDay: nil, window: window)
        }
    }

    /// The scoped per-model windows as gauges, active-first then hottest. Reads
    /// the latest poll's model/surface-scoped `limits[]` rows — fully dynamic,
    /// empty when the account has none.
    private static func scopedGauges(context: ModelContext) -> [PaceGaugesEntry.ScopedGauge] {
        var descriptor = FetchDescriptor<UsageLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        descriptor.fetchLimit = 200
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.latestBatch()
            .filter {
                ($0.modelId?.isEmpty == false)
                    || ($0.modelDisplayName?.isEmpty == false)
                    || ($0.surface?.isEmpty == false)
            }
            .map {
                PaceGaugesEntry.ScopedGauge(
                    label: $0.label, usedPct: $0.percent, resetsAt: $0.resetsAt,
                    durationSeconds: WindowSpec.scopedDuration(group: $0.group),
                    isActive: $0.isActive)
            }
    }
}

struct PaceGaugesWidgetView: View {
    var entry: PaceGaugesEntry
    /// Screenshot/preview override — `widgetFamily` is read-only at runtime, so
    /// the headless capture harness can't inject a family. nil in the real
    /// widget, where the environment drives the layout.
    var forcedFamily: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch forcedFamily ?? family {
        case .systemSmall: small
        case .systemLarge: large
        default:           medium
        }
    }

    /// The full window set as ring gauges: 5h, 7d, then each scoped per-model
    /// window (active/hottest first). This is where scoped windows become
    /// first-class gauges — the small/medium canvases can't hold more than the
    /// fixed pair legibly, so the large family owns the dynamic N-window grid.
    struct GaugeCell: Identifiable {
        let id: String
        let label: String
        let usedPct: Double?
        let resetsAt: Date?
        let durationSeconds: TimeInterval
        let isActive: Bool
    }

    /// Ordered gauge cells for the large grid, capped so the rings stay legible.
    private var largeCells: [GaugeCell] {
        var cells: [GaugeCell] = [
            GaugeCell(id: "five_hour", label: "5-hour", usedPct: entry.fiveHour?.usedPct,
                      resetsAt: entry.fiveHour?.resetsAt, durationSeconds: 5 * 3600, isActive: false),
            GaugeCell(id: "seven_day", label: "7-day", usedPct: entry.sevenDay?.usedPct,
                      resetsAt: entry.sevenDay?.resetsAt, durationSeconds: 7 * 86_400, isActive: false),
        ]
        // Up to four scoped gauges → six total, a clean 3×2 grid at most.
        for s in entry.scoped.prefix(4) {
            cells.append(GaugeCell(id: s.label, label: s.label, usedPct: s.usedPct,
                                   resetsAt: s.resetsAt, durationSeconds: s.durationSeconds,
                                   isActive: s.isActive))
        }
        return cells
    }

    @ViewBuilder
    private var large: some View {
        let cells = largeCells
        VStack(alignment: .leading, spacing: 10) {
            WidgetTitleBar(title: "RATE LIMITS")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 92, maximum: .infinity), spacing: 12)],
                alignment: .leading, spacing: 14
            ) {
                ForEach(cells) { gaugeCell($0) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(WidgetStyle.largePad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetCardBackground, for: .widget)
    }

    @ViewBuilder
    private func gaugeCell(_ cell: GaugeCell) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                // Accent dot marks the scoped window currently in effect; fixed
                // rows fall back to the band color. No jargon label.
                Circle()
                    .fill(cell.isActive ? Color.accentColor
                          : (cell.usedPct.map { UsageBand(percentage: $0).color } ?? .secondary))
                    .frame(width: 6, height: 6)
                Text(cell.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ringGauge(for: cell.usedPct.map { .init(usedPct: $0, resetsAt: cell.resetsAt) },
                      lineWidth: 8, labelSize: 20)
                .frame(width: 74, height: 74)
            Text(resetText(cell.resetsAt, durationSeconds: cell.durationSeconds))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// Resolve the small canvas's single window. `.both` collapses to
    /// 5-hour because small can't fit two ring gauges side by side at
    /// a legible size.
    private func smallTarget() -> (state: PaceGaugesEntry.WindowState?, title: String, duration: TimeInterval) {
        switch entry.window {
        case .sevenDay:
            return (entry.sevenDay, "7-DAY LIMIT", 7 * 86400)
        case .fiveHour, .both:
            return (entry.fiveHour, "5-HOUR LIMIT", 5 * 3600)
        }
    }

    @ViewBuilder
    private var small: some View {
        let target = smallTarget()
        VStack(alignment: .leading, spacing: 0) {
            WidgetTitleBar(title: target.title, dotColor: dotColor(for: target.state))
            Spacer(minLength: 4)
            // Bigger gauge to claim the small canvas — was 70x70, now
            // expands with the available width and keeps a tight 6pt
            // ring stroke for readability.
            HStack {
                Spacer()
                ringGauge(for: target.state, lineWidth: 9, labelSize: 26)
                    .frame(width: 96, height: 96)
                Spacer()
            }
            Spacer(minLength: 2)
            Text(resetText(target.state?.resetsAt, durationSeconds: target.duration))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(WidgetStyle.smallPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetCardBackground, for: .widget)
    }

    @ViewBuilder
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitleBar(title: mediumTitle)
            switch entry.window {
            case .both:
                HStack(spacing: 14) {
                    gaugeColumn("5-hour", entry.fiveHour, durationSeconds: 5 * 3600)
                    Divider()
                    gaugeColumn("7-day", entry.sevenDay, durationSeconds: 7 * 86400)
                }
                .frame(maxHeight: .infinity)
            case .fiveHour:
                // One gauge, full canvas — bigger ring, more readable
                // from across the desk than the split-medium version.
                gaugeColumn("5-hour", entry.fiveHour, durationSeconds: 5 * 3600, large: true)
                    .frame(maxHeight: .infinity)
            case .sevenDay:
                gaugeColumn("7-day", entry.sevenDay, durationSeconds: 7 * 86400, large: true)
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(WidgetStyle.mediumPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(widgetCardBackground, for: .widget)
    }

    /// Title for the medium-family header — adapts to the chosen window.
    private var mediumTitle: String {
        switch entry.window {
        case .both:     return "RATE LIMITS"
        case .fiveHour: return "5-HOUR LIMIT"
        case .sevenDay: return "7-DAY LIMIT"
        }
    }

    @ViewBuilder
    private func gaugeColumn(
        _ label: String,
        _ state: PaceGaugesEntry.WindowState?,
        durationSeconds: TimeInterval,
        large: Bool = false
    ) -> some View {
        // `large=true` is the single-window medium layout: gauge claims
        // the whole canvas, so we scale the ring up and use the
        // dashboard's ~28pt percentage font instead of the cramped 22pt
        // we use in the dual-column layout.
        let ringSize: CGFloat = large ? 116 : 78
        let lineWidth: CGFloat = large ? 11 : 8
        let labelSize: CGFloat = large ? 28 : 22
        VStack(spacing: large ? 8 : 6) {
            HStack(spacing: 4) {
                Circle()
                    .fill(dotColor(for: state) ?? .secondary)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ringGauge(for: state, lineWidth: lineWidth, labelSize: labelSize)
                .frame(width: ringSize, height: ringSize)
            Text(resetText(state?.resetsAt, durationSeconds: durationSeconds))
                .font(large ? .caption : .caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func ringGauge(
        for state: PaceGaugesEntry.WindowState?,
        lineWidth: CGFloat,
        labelSize: CGFloat
    ) -> some View {
        let pct = state?.usedPct ?? 0
        let labelFont: Font = .system(size: labelSize, weight: .semibold, design: .rounded)
        // Shared `PacerUI.CircularGauge` — same primitive the dashboard
        // uses, identical geometry/coloring per UsageBand. No widget-
        // local copy.
        CircularGauge(percentage: pct, lineWidth: lineWidth, labelFont: labelFont)
            .opacity(state == nil ? 0.3 : 1.0)
    }

    private func dotColor(for state: PaceGaugesEntry.WindowState?) -> Color? {
        guard let state else { return nil }
        return UsageBand(percentage: state.usedPct).color
    }

    /// Reset caption: relative duration plus the wall-clock anchor —
    /// "resets in 2h · 9 PM" for 5h, "resets in 4d · Mon 3 PM" for 7d.
    /// Mirrors `App/Views/PaceChartCard.swift:resetLabel(resets:)` so
    /// the gauge widget reads the same as the dashboard pace card.
    private func resetText(_ date: Date?, durationSeconds: TimeInterval) -> String {
        guard let date else { return "no data" }
        let rel = pacerRelative(date)
        let clock = durationSeconds <= 6 * 3600
            ? pacerClockTime(date)
            : pacerWeekdayClock(date)
        return "resets \(rel) · \(clock)"
    }
}

struct PaceGaugesWidget: Widget {
    let kind: String = WidgetKinds.paceGauges

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: PaceGaugesConfigurationIntent.self,
            provider: PaceGaugesProvider()
        ) { entry in
            PaceGaugesWidgetView(entry: entry)
        }
        .configurationDisplayName("Rate limits")
        .description("Claude Code rate-limit usage — the 5-hour and 7-day windows, plus any per-model windows in the large size.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
