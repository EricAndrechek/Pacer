import SwiftUI
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
                Text("Pacer")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)

                TodaySummaryCard()
                PaceChartCard()
                DailyCostChartCard()
                PerModelTodayCard()
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 600)
    }
}
