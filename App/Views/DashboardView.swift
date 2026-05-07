import SwiftUI
import SwiftData
import PacerCore

/// Primary view a user sees when opening Pacer. Tightened from the
/// pre-redesign 7-card stack into:
///
///   1. Welcome banner (auto-hidden once any data lands).
///   2. Hero strip — Today / 5-hour pace / 7-day pace.
///   3. PaceChart card (full width, 2-column visualization inside).
///   4. Live activity (full width).
///   5. Today by hour (full width).
///   6. Today by model (full width).
///   7. 30-day cost (full width).
///
/// Each card is its own `View` and owns its own `@Query` so SwiftData
/// updates stay incremental: a new TokenSample only invalidates the
/// cards that read TokenSample/DailyAggregate, not the rate-limit hero.
struct DashboardView: View {
    @State private var selectedDay: SelectedDay?

    private struct SelectedDay: Identifiable {
        let date: String
        var id: String { date }
    }

    var body: some View {
        PageScaffold(
            "Dashboard",
            subtitle: "Realtime view of your Claude Code usage."
        ) {
            WelcomeCard()
            HeroStripCard(onTodayTap: openToday)
            PaceChartCard()
            LiveActivityCard()
            TodayDetailsCard()
            TodayTimelineCard()
            PerModelTodayCard()
            DailyCostChartCard(onDayTap: { dayKey in
                selectedDay = SelectedDay(date: dayKey)
            })
        }
        .dismissibleModal(item: $selectedDay) { sel in
            DayDetailView(date: sel.date)
        }
    }

    /// Open today's day-detail modal. Pinned to the user's local
    /// timezone via TokenSample.formatDate so the date key matches
    /// what aggregates actually store under.
    private func openToday() {
        let today = TokenSample.formatDate(Date())
        selectedDay = SelectedDay(date: today)
    }
}
