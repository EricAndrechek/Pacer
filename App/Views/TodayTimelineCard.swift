import SwiftUI
import SwiftData
import Charts
import PacerCore

/// 24-hour timeline of today's activity. Shows when during the day you
/// were burning tokens — useful for spotting "I had a 4-hour deep
/// session this afternoon" or "early morning was unusually quiet."
///
/// Buckets `TokenSample` rows by hour-of-day in the user's local zone.
/// Bar height encodes total tokens (input + output + cache reads); the
/// peak hour is highlighted. Skips rendering past hours that have no
/// usage AND haven't yet been reached on the wall clock.
struct TodayTimelineCard: View {
    /// Today's samples. We deliberately don't read the array itself
    /// from `body` — even reading `.count` for an `.onChange` modifier
    /// forces SwiftData to re-evaluate the fetch on every body
    /// refresh, and the body refreshes on every SwiftData save in
    /// the same process. Cache invalidation is driven by a separate
    /// scan-meta query below.
    @Query private var samples: [TokenSample]
    /// Lightweight signal: the `last_incremental_scan_at` meta row
    /// is rewritten on every successful scan cycle. Subscribing to
    /// just this one row gives us a cheap "data probably changed"
    /// trigger for the cache without materializing the whole
    /// TokenSample table.
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

    /// Bucketed today-by-hour state. Recomputed via `.task(id:)` only
    /// when the underlying samples count actually changes — without
    /// this cache, every SwiftData save would re-iterate ~3000 of
    /// today's samples three times in the body computation (hours,
    /// peakHour, totalTokens), and saves fire frequently when Claude
    /// Code is actively writing. With caching, the body is cheap even
    /// when refreshes happen many times per second.
    private struct Cached {
        var hours: [Hour] = (0..<24).map { Hour(hour: $0, tokens: 0, cost: 0) }
        var peakHour: Int?
        var totalTokens: Int64 = 0
        var sampleCount: Int = -1   // sentinel; first refresh always fires
    }

    private var hours: [Hour] { cached.hours }
    private var peakHour: Int? { cached.peakHour }
    private var totalTokens: Int64 { cached.totalTokens }

    private func refreshCache() {
        let cal = Calendar.current
        var byHour: [Int: (tokens: Int64, cost: Double)] = [:]
        var total: Int64 = 0
        for s in samples {
            let h = cal.component(.hour, from: s.sampledAt)
            var v = byHour[h] ?? (0, 0)
            let t = s.inputTokens + s.outputTokens + s.cacheReadTokens
            v.tokens += t
            v.cost += s.sourceCostUSD ?? 0
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today by hour")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let peak = peakHour {
                    Text("peak \(formatHour(peak))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if totalTokens == 0 {
                emptyState
            } else {
                chart
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { refreshCache() }
        // Cache invalidation via the lastIncrementalScanAt meta row —
        // the value changes once per scan cycle, which is the granularity
        // we care about for "did samples change". Reading samples.count
        // here would force a 3000-row materialization on every body
        // refresh (and body refreshes on every save).
        .onChange(of: scanMeta.first?.value) { _, _ in refreshCache() }
    }

    private var emptyState: some View {
        Text("No activity logged today yet.")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(height: 100)
    }

    private var chart: some View {
        Chart(hours) { h in
            BarMark(
                x: .value("Hour", h.hour),
                y: .value("Tokens", h.tokens)
            )
            .foregroundStyle(h.hour == peakHour ? Color.accentColor : Color.accentColor.opacity(0.55))
            .annotation(position: .top, alignment: .center, spacing: 1) {
                if h.hour == peakHour && h.tokens > 0 {
                    Text(formatTokens(h.tokens))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 120)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let h = value.as(Int.self) {
                        Text(formatHour(h))
                            .font(.system(size: 9, design: .monospaced))
                    }
                }
            }
        }
    }

    /// 0-padded 24h `02:00` style; matches the monospaced look.
    private func formatHour(_ h: Int) -> String {
        String(format: "%02d:00", h)
    }

    private func formatTokens(_ count: Int64) -> String {
        let n = Double(count)
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", n / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", n / 1_000_000)
        case 1_000...:         return String(format: "%.0fK", n / 1_000)
        default:               return "\(count)"
        }
    }
}
