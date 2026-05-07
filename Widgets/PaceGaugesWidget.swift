import WidgetKit
import SwiftUI
import SwiftData
import PacerCore

/// At-a-glance rate-limit gauges. Small family: just the 5h gauge.
/// Medium: 5h + 7d side by side. Both surface the same data the
/// dashboard's PaceChartCard does, just compressed for widget canvas.
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
        case .systemSmall:
            small
        default:
            medium
        }
    }

    private var small: some View {
        VStack(spacing: 4) {
            Text("5-hour")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            gaugeOrPlaceholder(entry.fiveHour, lineWidth: 8, labelSize: 18)
                .frame(width: 70, height: 70)
            Text(resetText(entry.fiveHour?.resetsAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var medium: some View {
        HStack(spacing: 16) {
            gaugeColumn("5-hour", entry.fiveHour)
            Divider()
            gaugeColumn("7-day", entry.sevenDay)
        }
        .padding(12)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func gaugeColumn(_ label: String, _ state: PaceGaugesEntry.WindowState?) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            gaugeOrPlaceholder(state, lineWidth: 8, labelSize: 18)
                .frame(width: 70, height: 70)
            Text(resetText(state?.resetsAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func gaugeOrPlaceholder(
        _ state: PaceGaugesEntry.WindowState?,
        lineWidth: CGFloat,
        labelSize: CGFloat
    ) -> some View {
        if let state {
            WidgetCircularGauge(
                percentage: state.usedPct,
                lineWidth: lineWidth,
                labelFont: .system(size: labelSize, weight: .semibold, design: .rounded)
            )
        } else {
            WidgetCircularGauge(
                percentage: 0,
                lineWidth: lineWidth,
                labelFont: .system(size: labelSize, weight: .semibold, design: .rounded)
            )
            .opacity(0.3)
        }
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "no data" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "resets \(f.localizedString(for: date, relativeTo: Date()))"
    }
}

/// A widget-internal copy of CircularGauge. We can't import App-target
/// views into the widget extension, so we re-declare the small primitive
/// here. Stays in sync with App/Views/Components/CircularGauge.swift —
/// if you change one, change both.
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
        .configurationDisplayName("Rate-limit gauges")
        .description("Current 5-hour and 7-day rate-limit usage.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
