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
        // Today-scoped `HourlyAggregate` rows are at most 24 × N_models
        // — typically <100. Previously this card queried every
        // `TokenSample` for today (often 3000+) and re-walked them on
        // every scan tick to bucket by hour, calling
        // `effectiveCostUSD(mode:)` per row. The recomputer applies
        // cost mode once at write time, so the read path here is just
        // sum-by-hour over the prebuilt rollup.
        _hourlyRows = Query(
            filter: #Predicate<HourlyAggregate> { $0.date == today }
        )
    }

    @Query private var hourlyRows: [HourlyAggregate]
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
    }

    @MainActor
    private func refreshCache() {
        // Sum across models per hour. Each HourlyAggregate row is one
        // (today, hour, model) bucket pre-applied with the user's
        // current cost mode, so we just add them up.
        var byHour: [Int: (tokens: Int64, cost: Double)] = [:]
        var total: Int64 = 0
        for row in hourlyRows {
            var v = byHour[row.hour] ?? (0, 0)
            let t = row.inputTokens + row.outputTokens
            v.tokens += t
            v.cost += row.totalCostUSD
            byHour[row.hour] = v
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
            totalTokens: total
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
                    Text(pacerTokens(row.tokens)).help(pacerTokensExact(row.tokens))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if row.cost > 0 {
                        Text(pacerCost(row.cost)).help(pacerCostExact(row.cost))
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
                    .font(.callout)
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
                    Text(pacerTokens(h.tokens)).help(pacerTokensExact(h.tokens))
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
        // Arrow cursor (default) per HIG — clickable charts don't
        // warrant the link cursor.
        .contentShape(Rectangle())
        .onTapGesture {
            if onTodayTap != nil { onTodayTap?() }
        }
        .accessibilityLabel("Today's activity by hour")
        .accessibilityHint(onTodayTap != nil ? "Opens today's detailed breakdown" : "")
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
