import SwiftUI
import SwiftData
import PacerCore

/// Primary view a user sees when opening Pacer. Composes the cards
/// that answer "what's my Claude Code usage right now" — today's
/// totals, current rate-limit windows, recent history, per-model
/// breakdown.
///
/// Each card is its own `View` and reads its own `@Query` results.
/// That keeps SwiftData updates incremental: a new `TokenSample` row
/// only invalidates the cards that query `TokenSample`/`DailyAggregate`,
/// not the rate-limit gauges.
struct DashboardView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DashboardHeader()

                WelcomeCard()
                TodaySummaryCard()
                LiveActivityCard()
                TodayTimelineCard()
                PaceChartCard()
                DailyCostChartCard()
                PerModelTodayCard()
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 600)
    }
}

/// Title row + a "live status" sub-line. Shows the freshest known
/// activity timestamp (most-recent TokenSample sampledAt OR
/// most-recent RateLimitSample sampledAt, whichever is newer) so the
/// user has at-a-glance confirmation that data is flowing without
/// having to dig into the Debug tab.
private struct DashboardHeader: View {
    @Query(sort: \TokenSample.sampledAt, order: .reverse) private var tokens: [TokenSample]
    @Query(sort: \RateLimitSample.sampledAt, order: .reverse) private var rateLimits: [RateLimitSample]

    init() {
        // Cap the @Query to the most-recent row only — we only need
        // .first. fetchLimit on the SortDescriptor approach won't apply
        // here, so just drop the underlying SwiftData query if the
        // result set ever became surprisingly large. For RateLimitSamples
        // this is at most a few thousand rows; for TokenSamples ~1M
        // rows for a heavy user. The sort + .first short-circuits in
        // practice but we should evaluate with Instruments at v1.1.
    }

    private var lastActivity: Date? {
        let candidates = [tokens.first?.sampledAt, rateLimits.first?.sampledAt].compactMap { $0 }
        return candidates.max()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pacer")
                .font(.largeTitle.weight(.semibold))
            statusLine
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let last = lastActivity {
            HStack(spacing: 6) {
                Circle()
                    .fill(freshness(of: last))
                    .frame(width: 6, height: 6)
                Text("last update \(relative(last))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let model = recentModelInUse {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(shortModel(model))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                Text("no data yet — start the daemon to begin tracking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The model that wrote the most-recent token sample, if that
    /// sample is fresh enough (last 2 minutes) to be considered
    /// "currently in use." Older than that, the user has stopped, so
    /// we omit the chip.
    private var recentModelInUse: String? {
        guard let latest = tokens.first,
              Date().timeIntervalSince(latest.sampledAt) < 120
        else { return nil }
        return latest.model
    }

    private func shortModel(_ name: String) -> String {
        if let lastSlash = name.lastIndex(of: "/") {
            return String(name[name.index(after: lastSlash)...])
        }
        return name
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Green if data is < 2min old, yellow if < 10min, secondary
    /// otherwise. The thresholds align with: OAuth poller fires every
    /// 5min so 10min would be "we missed one"; JSONL writes are
    /// near-realtime so 2min is "still active".
    private func freshness(of date: Date) -> Color {
        let age = Date().timeIntervalSince(date)
        if age < 120 { return .green }
        if age < 600 { return .yellow }
        return .secondary
    }
}
