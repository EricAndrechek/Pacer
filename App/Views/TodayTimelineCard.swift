import SwiftUI
import SwiftData
import Charts
import PacerCore

/// 24-hour timeline of today's activity. Shows when during the day you
/// were burning tokens — useful for spotting "I had a 4-hour deep
/// session this afternoon" or "early morning was unusually quiet."
///
/// Buckets `TokenSample` rows by hour-of-day in the user's local zone.
/// Bar height encodes total tokens; the peak hour is highlighted.
struct TodayTimelineCard: View {
    /// Today's samples. Body never reads the array — we cache via a
    /// scan-meta tick so a hot save loop doesn't re-iterate ~3000 of
    /// today's samples on every body refresh.
    @Query private var samples: [TokenSample]
    @Query(TodayTimelineCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cached = Cached()

    init() {
        let today = TokenSample.formatDate(Date())
        _samples = Query(
            filter: #Predicate<TokenSample> { $0.date == today },
            sort: \.sampledAt
        )
    }

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

    var body: some View {
        PacerCard("Today by hour", trailing: {
            if let peak = cached.peakHour {
                Chip(
                    text: "peak \(formatHour(peak))",
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
        }
        .frame(height: 130)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let h = value.as(Int.self) {
                        Text(formatHour(h))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func formatHour(_ h: Int) -> String {
        String(format: "%02d:00", h)
    }
}
