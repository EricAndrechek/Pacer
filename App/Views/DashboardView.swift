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
    /// Most-recent token + rate-limit samples. We only ever read
    /// `.first` of each, so cap the fetch at 1 — without the limit,
    /// SwiftData materializes every TokenSample (40k+ on a populated
    /// install) on every body re-evaluation, which becomes a hot
    /// loop now that data collection runs in-process and @Query
    /// subscribers re-fire on every save.
    @Query(DashboardHeader.tokenProbe) private var tokens: [TokenSample]
    @Query(DashboardHeader.rateLimitProbe) private var rateLimits: [RateLimitSample]
    /// `last_incremental_scan_at` is updated on every scan cycle
    /// whether or not new data was inserted, so it's the
    /// authoritative "background service is alive" signal. Reading it
    /// as a Query (vs a one-shot fetch) means the indicator updates
    /// the moment a scan-meta row is written.
    @Query private var scanMeta: [ClaudeCodeMeta]

    init() {
        // Filter `scanMeta` to the single ClaudeCodeMeta row whose
        // key is `last_incremental_scan_at`. Filter at the predicate
        // level so we don't materialize every row just to find one.
        let scanKey = ClaudeCodeMetaKey.lastIncrementalScanAt
        _scanMeta = Query(filter: #Predicate<ClaudeCodeMeta> { $0.key == scanKey })
    }

    private static let tokenProbe: FetchDescriptor<TokenSample> = {
        var d = FetchDescriptor<TokenSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 1
        return d
    }()

    private static let rateLimitProbe: FetchDescriptor<RateLimitSample> = {
        var d = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 1
        return d
    }()

    private var lastDaemonScan: Date? {
        guard let raw = scanMeta.first?.value else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }

    private var lastActivity: Date? {
        let candidates = [
            tokens.first?.sampledAt,
            rateLimits.first?.sampledAt,
            lastDaemonScan,
        ].compactMap { $0 }
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
