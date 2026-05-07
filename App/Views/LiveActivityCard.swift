import SwiftUI
import SwiftData
import PacerCore

/// "What's happening right now" — token & cost burn rate over the last
/// hour, plus a projection for end-of-day. Helps you catch a runaway
/// session early ("oh I just burned through $5 in 20 minutes").
///
/// Reads `TokenSample` rows from the last hour. With cursor-based
/// scanning the daemon writes near-realtime, so this card moves
/// visibly as Claude Code is actively running.
struct LiveActivityCard: View {
    @Query private var recentSamples: [TokenSample]
    @Query private var todayAggregates: [DailyAggregate]
    /// Lightweight signal that the scan loop just ran; drives cache
    /// invalidation without forcing a fetch of recentSamples on every
    /// body refresh.
    @Query(LiveActivityCard.scanMetaProbe) private var scanMeta: [ClaudeCodeMeta]
    @State private var cachedStats = LiveStats()

    init() {
        let cutoff = Date().addingTimeInterval(-3600)  // 1h
        _recentSamples = Query(
            filter: #Predicate<TokenSample> { $0.sampledAt >= cutoff },
            sort: \.sampledAt,
            order: .reverse
        )
        let today = TokenSample.formatDate(Date())
        _todayAggregates = Query(
            filter: #Predicate<DailyAggregate> { $0.date == today }
        )
    }

    private static let scanMetaProbe: FetchDescriptor<ClaudeCodeMeta> = {
        let key = ClaudeCodeMetaKey.lastIncrementalScanAt
        return FetchDescriptor<ClaudeCodeMeta>(
            predicate: #Predicate<ClaudeCodeMeta> { $0.key == key }
        )
    }()

    private struct LiveStats {
        var tokensLastHour: Int64 = 0
        var costLastHour: Double = 0
        var sampleCount: Int = 0
        var lastSampleAt: Date?
        var hasFreshActivity: Bool { lastSampleAt.map { Date().timeIntervalSince($0) < 600 } ?? false }
    }

    /// Cached read of `recentSamples`. Recomputed only when the
    /// sample count changes — without caching, the body re-iterates
    /// hundreds of last-hour samples on every SwiftData save, and
    /// scans save many times per second when Claude Code is writing.
    private var stats: LiveStats { cachedStats }

    private func refreshStats() {
        var s = LiveStats()
        for sample in recentSamples {
            s.tokensLastHour += sample.inputTokens + sample.outputTokens + sample.cacheReadTokens
            s.costLastHour += sample.sourceCostUSD ?? 0
            s.sampleCount += 1
            if s.lastSampleAt == nil || sample.sampledAt > s.lastSampleAt! {
                s.lastSampleAt = sample.sampledAt
            }
        }
        cachedStats = s
    }

    private var todayCostSoFar: Double {
        todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
    }

    /// "If you maintain this hourly rate, end-of-day will land at X."
    /// Bounded by the wall-clock fraction of the day already elapsed —
    /// the cleaner alternative would be "(hourly rate) × (hours left
    /// in day)", which we use here.
    private var projectedEndOfDay: Double {
        let now = Date()
        let cal = Calendar.current
        let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        let hoursLeft = max(0, endOfDay.timeIntervalSince(now) / 3600.0)
        return todayCostSoFar + stats.costLastHour * hoursLeft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: stats.hasFreshActivity ? "bolt.fill" : "bolt.slash")
                    .foregroundStyle(stats.hasFreshActivity ? .yellow : .secondary)
                Text("Live activity")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let last = stats.lastSampleAt {
                    Text("last sample \(relative(last))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if stats.sampleCount == 0 {
                emptyState
            } else {
                row
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { refreshStats() }
        .onChange(of: scanMeta.first?.value) { _, _ in refreshStats() }
    }

    private var emptyState: some View {
        Text("No samples in the last hour. The card will light up as Claude Code activity hits the store.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 32) {
            metric(
                label: "last hour cost",
                value: formatCost(stats.costLastHour),
                hint: "\(stats.sampleCount) sample\(stats.sampleCount == 1 ? "" : "s")"
            )
            metric(
                label: "last hour tokens",
                value: formatTokens(stats.tokensLastHour),
                hint: nil
            )
            metric(
                label: "today so far",
                value: formatCost(todayCostSoFar),
                hint: nil
            )
            metric(
                label: "projected end-of-day",
                value: formatCost(projectedEndOfDay),
                hint: "if rate holds"
            )
            Spacer()
        }
    }

    @ViewBuilder
    private func metric(label: String, value: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func formatCost(_ usd: Double) -> String {
        if usd >= 1_000 { return String(format: "$%.0f", usd) }
        if usd >= 100   { return String(format: "$%.0f", usd) }
        if usd >= 10    { return String(format: "$%.1f", usd) }
        return String(format: "$%.2f", usd)
    }

    private func formatTokens(_ count: Int64) -> String {
        let n = Double(count)
        switch n {
        case 1_000_000_000...: return String(format: "%.2fB", n / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", n / 1_000_000)
        case 1_000...:         return String(format: "%.1fK", n / 1_000)
        default:               return "\(count)"
        }
    }
}
