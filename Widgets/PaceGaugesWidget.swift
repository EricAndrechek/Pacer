import WidgetKit
import SwiftUI
import SwiftData
import PacerCore

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

    struct WindowState {
        let usedPct: Double
        let resetsAt: Date?
    }
}

struct PaceGaugesProvider: TimelineProvider {
    func placeholder(in context: Context) -> PaceGaugesEntry {
        PaceGaugesEntry(
            date: Date(),
            fiveHour: .init(usedPct: 35, resetsAt: Date().addingTimeInterval(2 * 3600)),
            sevenDay: .init(usedPct: 62, resetsAt: Date().addingTimeInterval(4 * 86400))
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (PaceGaugesEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PaceGaugesEntry>) -> Void) {
        let entry = currentEntry()
        let nextRefresh = Date().addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func currentEntry() -> PaceGaugesEntry {
        do {
            let container = try PacerStore.makeModelContainer()
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
                sevenDay: seven.map { .init(usedPct: $0.usedPercentage, resetsAt: $0.resetsAt) }
            )
        } catch {
            return PaceGaugesEntry(date: Date(), fiveHour: nil, sevenDay: nil)
        }
    }
}

struct PaceGaugesWidgetView: View {
    var entry: PaceGaugesEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall: small
        default:           medium
        }
    }

    @ViewBuilder
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetTitleBar(title: "5-HOUR LIMIT", dotColor: dotColor(for: entry.fiveHour))
            Spacer(minLength: 4)
            // Bigger gauge to claim the small canvas — was 70x70, now
            // expands with the available width and keeps a tight 6pt
            // ring stroke for readability.
            HStack {
                Spacer()
                ringGauge(for: entry.fiveHour, lineWidth: 9, labelSize: 26)
                    .frame(width: 96, height: 96)
                Spacer()
            }
            Spacer(minLength: 2)
            Text(resetText(entry.fiveHour?.resetsAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(WidgetStyle.smallPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitleBar(title: "RATE LIMITS")
            HStack(spacing: 14) {
                gaugeColumn("5-hour", entry.fiveHour)
                Divider()
                gaugeColumn("7-day", entry.sevenDay)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(WidgetStyle.mediumPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func gaugeColumn(_ label: String, _ state: PaceGaugesEntry.WindowState?) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Circle()
                    .fill(dotColor(for: state) ?? .secondary)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ringGauge(for: state, lineWidth: 8, labelSize: 22)
                .frame(width: 78, height: 78)
            Text(resetText(state?.resetsAt))
                .font(.caption2)
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
        WidgetCircularGauge(percentage: pct, lineWidth: lineWidth, labelFont: labelFont)
            .opacity(state == nil ? 0.3 : 1.0)
    }

    private func dotColor(for state: PaceGaugesEntry.WindowState?) -> Color? {
        guard let state else { return nil }
        switch UsageBand(percentage: state.usedPct) {
        case .green:  return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red:    return .red
        }
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "no data" }
        return "resets \(formatRelative(date))"
    }
}

/// Widget-local circular gauge primitive. Mirrors
/// `App/Views/Components/CircularGauge.swift` — kept in sync manually
/// because App-target views aren't importable from extensions.
struct WidgetCircularGauge: View {
    let percentage: Double
    let lineWidth: CGFloat
    let labelFont: Font

    private var fraction: CGFloat {
        max(0, min(1, CGFloat(percentage) / 100))
    }

    private var color: Color {
        switch UsageBand(percentage: percentage) {
        case .green:  return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red:    return .red
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(percentage.rounded()))%")
                .font(labelFont)
                .monospacedDigit()
        }
    }
}

struct PaceGaugesWidget: Widget {
    let kind: String = "PaceGaugesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PaceGaugesProvider()) { entry in
            PaceGaugesWidgetView(entry: entry)
        }
        .configurationDisplayName("Rate limits")
        .description("5-hour and 7-day Claude Code rate-limit usage.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
