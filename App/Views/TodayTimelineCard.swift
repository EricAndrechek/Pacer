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
    @Query private var samples: [TokenSample]

    init() {
        let today = TokenSample.formatDate(Date())
        _samples = Query(
            filter: #Predicate<TokenSample> { $0.date == today },
            sort: \.sampledAt
        )
    }

    private struct Hour: Identifiable {
        let hour: Int
        let tokens: Int64
        let cost: Double
        var id: Int { hour }
    }

    private var hours: [Hour] {
        // Bucket by hour-of-day in current locale.
        let cal = Calendar.current
        var byHour: [Int: (tokens: Int64, cost: Double)] = [:]
        for s in samples {
            let h = cal.component(.hour, from: s.sampledAt)
            var v = byHour[h] ?? (0, 0)
            v.tokens += s.inputTokens + s.outputTokens + s.cacheReadTokens
            v.cost += s.sourceCostUSD ?? 0
            byHour[h] = v
        }
        return (0..<24).map { h in
            let v = byHour[h] ?? (0, 0)
            return Hour(hour: h, tokens: v.tokens, cost: v.cost)
        }
    }

    private var peakHour: Int? {
        let h = hours.max { $0.tokens < $1.tokens }
        guard let h, h.tokens > 0 else { return nil }
        return h.hour
    }

    private var totalTokens: Int64 {
        hours.reduce(0) { $0 + $1.tokens }
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
