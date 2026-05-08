import WidgetKit
import SwiftUI
import SwiftData
import Charts
import PacerCore

/// Cycle-anchored pace chart for the 5-hour and 7-day rate-limit
/// windows. Mirrors `App/Views/PaceChartCard.swift` but compressed for
/// widget canvases:
///   - small : 5h chart only (the cycle a user is most likely to
///             care about during active coding)
///   - medium: 5h + 7d side-by-side, matching the dashboard column
///             layout
///   - large : 5h + 7d stacked with bigger charts, plus the wall-clock
///             reset captions the dashboard surfaces
///
/// The dashboard renders the actual-usage line as multi-colored
/// segments (each i→i+1 colored by the band at point i). For widgets
/// we use a single-colored line tinted by the *current* band — fewer
/// Chart series, less risk under the extension's tighter render budget,
/// and the band color still reads correctly because "where am I now"
/// is the salient question.

private enum K {
    static let fiveHourSeconds: TimeInterval = 5 * 3600
    static let sevenDaySeconds: TimeInterval = 7 * 86400
    /// Refresh every 5 minutes — same cadence as the OAuth poller, so
    /// the widget updates as soon as a new sample lands.
    static let refreshSeconds: TimeInterval = 300
}

// MARK: - Entry

struct PaceChartEntry: TimelineEntry {
    let date: Date
    let fiveHour: WindowState?
    let sevenDay: WindowState?

    /// One window's worth of pace data. `samples` is the raw
    /// (sampledAt, usedPct) trail inside the current cycle, sorted
    /// ascending — already pre-filtered by the provider so the view
    /// just charts what it gets.
    struct WindowState {
        let usedPct: Double
        let resetsAt: Date
        let cycleStart: Date
        let durationSeconds: TimeInterval
        let samples: [Sample]

        struct Sample: Identifiable {
            let time: Date
            let value: Double
            var id: TimeInterval { time.timeIntervalSince1970 }
        }

        var paceEndPct: Double {
            PaceMath.paceFraction(
                now: Date(),
                resetsAt: resetsAt,
                windowDuration: durationSeconds
            ) * 100
        }

        var band: PaceBand {
            PaceBand(usedPct: usedPct, paceEndPct: paceEndPct)
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
        let inCycle = windowRows
            .filter { $0.sampledAt >= cycleStart && $0.sampledAt <= now }
            .sorted { $0.sampledAt < $1.sampledAt }
        var samples = inCycle.map {
            PaceChartEntry.WindowState.Sample(time: $0.sampledAt, value: $0.usedPercentage)
        }
        // Tail point at now so the line ends where the user is.
        if samples.last?.time != now {
            samples.append(.init(time: now, value: latest.usedPercentage))
        }
        return PaceChartEntry.WindowState(
            usedPct: latest.usedPercentage,
            resetsAt: resetsAt,
            cycleStart: cycleStart,
            durationSeconds: duration,
            samples: samples
        )
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
        let samples = (0..<sampleCount).map { i in
            let t = cycleStart.addingTimeInterval(Double(i) * stepInterval)
            // Mild concave ramp so it doesn't look perfectly linear.
            let frac = Double(i) / Double(max(1, sampleCount - 1))
            return PaceChartEntry.WindowState.Sample(
                time: t,
                value: usedPct * (frac * (1.05 - 0.05 * frac))
            )
        }
        return PaceChartEntry.WindowState(
            usedPct: usedPct,
            resetsAt: resets,
            cycleStart: cycleStart,
            durationSeconds: duration,
            samples: samples
        )
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
                dotColor: entry.fiveHour.map { bandColor($0.band) }
            ) {
                if let s = entry.fiveHour {
                    paceFraction(used: s.usedPct, pace: s.paceEndPct, compact: true)
                }
            }
            if let s = entry.fiveHour {
                PaceLineChart(state: s, compact: true)
                    .frame(maxHeight: .infinity)
                Text(resetCaption(for: s, compact: true))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                WidgetEmptyState(message: "Waiting for the first rate-limit reading.")
            }
        }
        .padding(WidgetStyle.smallPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitleBar(title: "RATE-LIMIT PACE")
            if entry.fiveHour == nil && entry.sevenDay == nil {
                WidgetEmptyState(message: "Waiting for the first rate-limit reading.")
            } else {
                HStack(alignment: .top, spacing: 12) {
                    column(label: "5-hour", state: entry.fiveHour)
                    Divider()
                    column(label: "7-day", state: entry.sevenDay)
                }
            }
        }
        .padding(WidgetStyle.mediumPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
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
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func column(label: String, state: PaceChartEntry.WindowState?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(state.map { bandColor($0.band) } ?? .secondary)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let state {
                paceFraction(used: state.usedPct, pace: state.paceEndPct, compact: true)
                PaceLineChart(state: state, compact: true)
                    .frame(maxHeight: .infinity)
                Text(resetCaption(for: state, compact: true))
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
                    .fill(state.map { bandColor($0.band) } ?? .secondary)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if let state {
                    paceFraction(used: state.usedPct, pace: state.paceEndPct, compact: false)
                }
            }
            if let state {
                PaceLineChart(state: state, compact: false)
                    .frame(maxHeight: .infinity)
                Text(resetCaption(for: state, compact: false))
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
                .foregroundStyle(bandColor(band))
            Text("/")
                .font(.system(size: compact ? 11 : 14))
                .foregroundStyle(.tertiary)
            Text("\(Int(pace.rounded()))%")
                .font(.system(size: compact ? 11 : 14, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func resetCaption(for s: PaceChartEntry.WindowState, compact: Bool) -> String {
        let rel = formatRelative(s.resetsAt)
        if compact {
            return "resets \(rel)"
        }
        // Wall-clock anchor so "in 2h" can be read as "9 PM" too.
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .none
        f.timeStyle = .short
        return "resets \(rel) · \(f.string(from: s.resetsAt))"
    }

    private func bandColor(_ band: PaceBand) -> Color {
        switch band {
        case .green:  return .green
        case .white:  return .primary
        case .yellow: return .yellow
        case .red:    return .red
        }
    }
}

/// The actual line graph: dashed 0→100% pace line, colored
/// actual-usage line, tail dot at "now". Pulled out so all three
/// families instantiate it the same way and the chart never
/// shifts sub-pixel between the two columns at medium.
private struct PaceLineChart: View {
    let state: PaceChartEntry.WindowState
    let compact: Bool

    var body: some View {
        let color: Color = {
            switch state.band {
            case .green:  return .green
            case .white:  return .primary
            case .yellow: return .yellow
            case .red:    return .red
            }
        }()
        Chart {
            // Dashed pace line: cycleStart→0%, resetsAt→100%.
            LineMark(
                x: .value("t", state.cycleStart),
                y: .value("pct", 0.0),
                series: .value("series", "pace")
            )
            .foregroundStyle(.secondary.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            LineMark(
                x: .value("t", state.resetsAt),
                y: .value("pct", 100.0),
                series: .value("series", "pace")
            )
            .foregroundStyle(.secondary.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Actual-usage line, single color tinted by current band.
            ForEach(state.samples) { p in
                LineMark(
                    x: .value("t", p.time),
                    y: .value("pct", p.value),
                    series: .value("series", "actual")
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: compact ? 1.6 : 2, lineCap: .round))
            }
            // Tail dot at the most-recent point.
            if let tail = state.samples.last {
                PointMark(
                    x: .value("t", tail.time),
                    y: .value("pct", tail.value)
                )
                .foregroundStyle(color)
                .symbolSize(compact ? 22 : 36)
            }
        }
        .chartXScale(domain: state.cycleStart...state.resetsAt)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

// MARK: - Configuration

struct PaceChartWidget: Widget {
    let kind: String = "PaceChartWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PaceChartProvider()) { entry in
            PaceChartWidgetView(entry: entry)
        }
        .configurationDisplayName("Pace charts")
        // Literal description — no interpolation; learned the hard way
        // that LocalizedStringKey + interpolation crashes the bundle on
        // launch. See `Widgets/TopProjectsWidget.swift` history.
        .description("Cycle-anchored pace line graphs for the 5-hour and 7-day windows.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
