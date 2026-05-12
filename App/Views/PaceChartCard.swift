import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Pace charts for the 5-hour and 7-day rate-limit windows. The chart
/// itself lives in `PacerUI.PaceChartView` so the widget extension and
/// (eventually) the menu-bar popover render the exact same SwiftUI
/// view. This card just sources the data from SwiftData and arranges
/// the two columns.
struct PaceChartCard: View {
    /// 8-day window of rate-limit samples. Body never reads the array
    /// — pre-bucketed by window in `bucketed` so neither column does
    /// its own filter pass.
    @Query private var samples: [RateLimitSample]

    init() {
        let cutoff = Date().addingTimeInterval(-8 * 86400)
        _samples = Query(
            filter: #Predicate<RateLimitSample> { $0.sampledAt >= cutoff },
            sort: \.sampledAt,
            order: .reverse
        )
    }

    private struct Bucketed {
        var fiveHour: [RateLimitSample] = []
        var sevenDay: [RateLimitSample] = []
        var latest: RateLimitSample?
    }

    /// Derived synchronously from `samples` so the first render already
    /// has the real layout — the previous @State + .onAppear pattern
    /// rendered the empty state for one frame, then reflowed all cards
    /// below this one when the cache populated.
    private var bucketed: Bucketed {
        var b = Bucketed()
        for s in samples {
            if s.window == "five_hour" { b.fiveHour.append(s) }
            else if s.window == "seven_day" { b.sevenDay.append(s) }
            if b.latest == nil || s.sampledAt > b.latest!.sampledAt { b.latest = s }
        }
        return b
    }

    var body: some View {
        let b = bucketed
        PacerCard("Rate-limit pace", trailing: { trailingChip(latest: b.latest) }) {
            if b.latest == nil {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 24) {
                    PaceChartColumn(
                        title: "5-hour",
                        duration: 5 * 3600,
                        windowSamples: b.fiveHour
                    )
                    Divider()
                        .frame(height: 110)
                    PaceChartColumn(
                        title: "7-day",
                        duration: 7 * 86400,
                        windowSamples: b.sevenDay
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func trailingChip(latest: RateLimitSample?) -> some View {
        if let latest {
            Text("via \(latest.source) · \(pacerRelative(latest.sampledAt))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
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
                Text("Pacer checks Anthropic every 5 minutes. If you're signed into Claude Code, the 5-hour and 7-day pace will appear here shortly.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .frame(minHeight: 96, alignment: .topLeading)
    }
}

/// One window's column inside `PaceChartCard`. Renders the title,
/// hero used%/pace% line, and the shared `PaceChartView`. The view
/// itself is in PacerUI so the widget extension renders the same
/// chart pixel-for-pixel.
private struct PaceChartColumn: View {
    let title: String
    let duration: TimeInterval
    /// Already filtered to this column's window and pre-sorted reverse-
    /// chronological by the parent.
    let windowSamples: [RateLimitSample]

    private var latest: RateLimitSample? { windowSamples.first }

    /// Build the `PaceChartView.Data` snapshot — same shape the widget
    /// will pass in. Synthesizes a "now" tail point so the line tracks
    /// to current time even if the most-recent sample is older.
    private var chartData: PaceChartView.Data? {
        guard let latest, let resets = latest.resetsAt else { return nil }
        let cycleStart = resets.addingTimeInterval(-duration)
        let now = Date()
        var points = windowSamples
            .filter { $0.sampledAt >= cycleStart && $0.sampledAt <= now }
            .sorted { $0.sampledAt < $1.sampledAt }
            .map { PaceChartView.Data.Point(time: $0.sampledAt, value: $0.usedPercentage) }
        if points.last?.time != now {
            points.append(.init(time: now, value: latest.usedPercentage))
        }
        return PaceChartView.Data(
            cycleStart: cycleStart,
            resetsAt: resets,
            durationSeconds: duration,
            points: points,
            usedPct: latest.usedPercentage
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            heroLine
            if let chartData {
                PaceChartView(data: chartData, style: .detailed)
                    .frame(height: 96)
            } else {
                Text("collecting…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(height: 96)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Eyebrow(text: title)
            Spacer()
            if let resets = latest?.resetsAt {
                Text(pacerResetCaption(resetsAt: resets, durationSeconds: duration))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("resets unknown")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var heroLine: some View {
        if let latest, let resets = latest.resetsAt {
            let paceFraction = PaceMath.paceFraction(
                now: Date(),
                resetsAt: resets,
                windowDuration: duration
            )
            let paceEndPct = paceFraction * 100
            let band = PaceBand(usedPct: latest.usedPercentage, paceEndPct: paceEndPct)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(latest.usedPercentage.rounded()))%")
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
        } else {
            Text("--")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }
}
