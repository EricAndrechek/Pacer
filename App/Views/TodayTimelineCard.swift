import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

/// 24-hour timeline of today's activity. Shows when during the day you
/// were burning tokens — useful for spotting "I had a 4-hour deep
/// session this afternoon" or "early morning was unusually quiet."
///
/// Buckets `TokenSample` rows by hour-of-day in the user's local zone.
/// Bar height encodes total tokens; the peak hour is highlighted.
struct TodayTimelineCard: View {
    /// Optional click handler — clicking any hour with traffic drills
    /// into today's day modal. Wired by DashboardView; nil for any
    /// other surface.
    let onTodayTap: (() -> Void)?

    init(onTodayTap: (() -> Void)? = nil) {
        self.onTodayTap = onTodayTap
        let today = TokenSample.formatDate(Date())
        _samples = Query(
            filter: #Predicate<TokenSample> { $0.date == today },
            sort: \.sampledAt
        )
    }

    /// Today's samples. Body never reads the array — we cache via a
    /// scan-meta tick so a hot save loop doesn't re-iterate ~3000 of
    /// today's samples on every body refresh.
    @Query private var samples: [TokenSample]
    @Query(TodayTimelineCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cached = Cached()

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private struct Hour: Identifiable {
        let hour: Int
        let tokens: Int64
        let cost: Double
        var id: Int { hour }
    }

    private struct Cached {
        var hours: [Hour] = (0..<24).map { Hour(hour: $0, tokens: 0, cost: 0) }
        var peakHour: Int?
        var totalTokens: Int64 = 0
        var sampleCount: Int = -1
    }

    @MainActor
    private func refreshCache() {
        let cal = Calendar.current
        var byHour: [Int: (tokens: Int64, cost: Double)] = [:]
        var total: Int64 = 0
        let mode = PacerPreferences.costMode()
        for s in samples {
            let h = cal.component(.hour, from: s.sampledAt)
            var v = byHour[h] ?? (0, 0)
            let t = s.inputTokens + s.outputTokens + s.cacheReadTokens
            v.tokens += t
            // Use the shared sample-cost helper. Bug parity with
            // DayDetail / LiveActivity: prior `sourceCostUSD ?? 0`
            // hand-roll silently dropped the calculate/auto-mode
            // fallback to tokens × pricing.
            v.cost += s.effectiveCostUSD(mode: mode)
            byHour[h] = v
            total += t
        }
        let bucketed = (0..<24).map { h -> Hour in
            let v = byHour[h] ?? (0, 0)
            return Hour(hour: h, tokens: v.tokens, cost: v.cost)
        }
        let peak = bucketed.max { $0.tokens < $1.tokens }
        cached = Cached(
            hours: bucketed,
            peakHour: (peak?.tokens ?? 0) > 0 ? peak?.hour : nil,
            totalTokens: total,
            sampleCount: samples.count
        )
    }

    @State private var hoveredHour: Int?

    var body: some View {
        PacerCard("Today by hour", trailing: {
            // Hover swaps the trailing slot to "11 AM • 32K tokens · $1.20"
            // — same pattern other charts use. Falls back to the peak
            // chip when nothing is hovered. Click on the chart drills
            // into today's day modal (handler wired by parent view).
            if let h = hoveredHour, let row = cached.hours.first(where: { $0.hour == h }), row.tokens > 0 {
                HStack(spacing: 8) {
                    Text(hourLabel(h, style: .regular))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(pacerTokens(row.tokens))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if row.cost > 0 {
                        Text(pacerCost(row.cost))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            } else if let peak = cached.peakHour {
                Chip(
                    text: "peak \(hourLabel(peak, style: .compact))",
                    systemImage: "chart.bar.fill",
                    tint: .accentColor,
                    size: .compact
                )
            }
        }) {
            if cached.totalTokens == 0 {
                Text("No activity logged today yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(height: 100)
            } else {
                chart
            }
        }
        .onAppear { refreshCache() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    private var chart: some View {
        Chart(cached.hours) { h in
            BarMark(
                x: .value("Hour", h.hour),
                y: .value("Tokens", h.tokens)
            )
            .foregroundStyle(
                h.hour == cached.peakHour
                    ? Color.accentColor
                    : Color.accentColor.opacity(0.55)
            )
            .cornerRadius(2)
            .annotation(position: .top, alignment: .center, spacing: 2) {
                if h.hour == cached.peakHour && h.tokens > 0 {
                    Text(pacerTokens(h.tokens))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if hoveredHour == h.hour && h.tokens > 0 {
                RuleMark(x: .value("Selected", h.hour))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(height: 130)
        .chartXSelection(value: $hoveredHour)
        .chartYAxis(.hidden)
        .chartXAxis {
            // Locale-aware ticks. 24h: 0/6/12/18/23. 12h: 12a/6a/12p/6p/11p.
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let h = value.as(Int.self) {
                        Text(hourLabel(h, style: .compact))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // Tap anywhere on the chart drills into today's day modal —
        // same pattern as DailyCostChartCard. The chartXSelection
        // binding is already tracking hover state; tap commits.
        .contentShape(Rectangle())
        .onTapGesture {
            if onTodayTap != nil { onTodayTap?() }
        }
        .pointerStyle(onTodayTap != nil ? .link : .default)
    }

    /// Wrapper that builds a Date for hour-of-day h on today, then
    /// runs it through the shared `pacerHour` helper. Lets the chart
    /// pick up the locale's clock format without re-implementing it.
    private func hourLabel(_ h: Int, style: PacerHourStyle) -> String {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = h
        components.minute = 0
        let date = Calendar.current.date(from: components) ?? Date()
        return pacerHour(date, style: style)
    }
}
