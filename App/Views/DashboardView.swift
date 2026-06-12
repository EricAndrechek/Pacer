import SwiftUI
import SwiftData
import PacerCore
import PacerUI

/// Primary view a user sees when opening Pacer:
///
///   1. Welcome banner (auto-hidden once any data lands).
///   2. Spend strip — Today + This month (with the month-end projection).
///   3. PaceChart card (full width, the two big 5h/7d charts).
///   4. Live activity, today's breakdowns, weekly comparison, 30-day cost.
///
/// Each card is its own `View` and owns its own `@Query` so SwiftData
/// updates stay incremental: a new TokenSample only invalidates the
/// cards that read TokenSample/DailyAggregate, not the rate-limit charts.
struct DashboardView: View {
    @State private var modalRoot: PacerModalDestination?

    var body: some View {
        PageScaffold(
            "Dashboard",
            subtitle: "Realtime view of your Claude Code usage.",
            // Notice badges + the data-source freshness chip live in the
            // header's trailing slot — zero vertical pixels, and both
            // describe the page as a whole rather than any one card.
            trailing: {
                HStack(spacing: 10) {
                    AdvisorBadges()
                    RateLimitSourceChip()
                }
            }
        ) {
            WelcomeCard()
            SpendOverviewStrip(onTodayTap: openToday)
            PaceChartCard(onCompare: { window in
                modalRoot = .projection(window: window)
            })
            LiveActivityCard()
            TodayDetailsCard()
            TodayTimelineCard(onTodayTap: openToday)
            PerModelTodayCard()
            WeeklyComparisonCard()
            DailyCostChartCard(onDayTap: { dayKey in
                modalRoot = .day(date: dayKey)
            })
        }
        .pacerModalNavigation(root: $modalRoot)
    }

    /// Open today's day-detail modal. Pinned to the user's local
    /// timezone via TokenSample.formatDate so the date key matches
    /// what aggregates actually store under.
    private func openToday() {
        let today = TokenSample.formatDate(Date())
        modalRoot = .day(date: today)
    }
}

// MARK: - Header freshness chip

/// "via oauth · just now" — the rate-limit data-source freshness signal,
/// in the page header because it describes the whole dashboard rather
/// than one card. Goes yellow with a warning triangle when an OAuth feed
/// stalls past 15 minutes — commonly an expired Claude Code token.
struct RateLimitSourceChip: View {
    @Query(RateLimitSourceChip.newestSample) private var newest: [RateLimitSample]

    private static let newestSample: FetchDescriptor<RateLimitSample> = {
        var d = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 1
        return d
    }()

    var body: some View {
        if let latest = newest.first {
            // OAuth samples ought to arrive every 5 min; statusline samples
            // are irregular by nature, so the staleness warning is
            // oauth-only. See #3.
            let elapsed = Date().timeIntervalSince(latest.sampledAt)
            let isStaleOAuth = latest.source == RateLimitSource.oauth && elapsed > 15 * 60
            HStack(spacing: 4) {
                if isStaleOAuth {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                }
                Text("via \(latest.source) · \(pacerRelative(latest.sampledAt))")
                    .font(.system(size: 11))
            }
            .foregroundStyle(isStaleOAuth ? Color.yellow : .secondary)
            .help(isStaleOAuth
                ? "Pacer hasn't received fresh data in \(pacerRelative(latest.sampledAt)). The OAuth token may have expired — try launching or quitting/reopening Claude Code to refresh it. See ~/Library/Logs/Pacer/Pacer.err.log for the poller's last outcome."
                : "")
        }
    }
}
