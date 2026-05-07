import SwiftUI
import SwiftData
import PacerCore

/// Invisible view that observes RateLimitSample inserts and dispatches
/// to NotificationCoordinator. Mounted alongside the main window so it
/// stays alive as long as the app is open.
///
/// We carry a small `lastSeen` dict in @State to detect upward
/// crossings — without it, we'd post a banner every render while a
/// sample sits above the threshold.
struct NotificationsHost: View {
    @Query(sort: \RateLimitSample.sampledAt, order: .reverse)
    private var samples: [RateLimitSample]

    @Query private var todayAggregates: [DailyAggregate]

    @Environment(\.modelContext) private var context

    @State private var lastSeenFiveHour: Double?
    @State private var lastSeenSevenDay: Double?
    @State private var lastSeenDailyCost: Double?

    init() {
        let today = TokenSample.formatDate(Date())
        _todayAggregates = Query(filter: #Predicate<DailyAggregate> { $0.date == today })
    }

    var body: some View {
        // Genuinely empty — this view has no UI. Its job is just to
        // hold @Query subscriptions so the onChange handlers fire.
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: samples.first { $0.window == "five_hour" }?.persistentModelID) {
                handleFiveHour()
            }
            .onChange(of: samples.first { $0.window == "seven_day" }?.persistentModelID) {
                handleSevenDay()
            }
            .onChange(of: todayAggregates.map(\.totalCostUSD).reduce(0, +)) {
                handleDailyCost()
            }
            .task {
                // Seed lastSeen from existing data so we don't fire a
                // notification just because the app launched while
                // already over threshold.
                if let f = samples.first(where: { $0.window == "five_hour" }) {
                    lastSeenFiveHour = f.usedPercentage
                }
                if let s = samples.first(where: { $0.window == "seven_day" }) {
                    lastSeenSevenDay = s.usedPercentage
                }
                lastSeenDailyCost = todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
                await NotificationCoordinator.shared.requestAuthorizationIfNeeded()
            }
    }

    private func handleFiveHour() {
        guard let latest = samples.first(where: { $0.window == "five_hour" }) else { return }
        let prev = lastSeenFiveHour
        lastSeenFiveHour = latest.usedPercentage
        Task { @MainActor in
            await NotificationCoordinator.shared.handleRateLimitUpdate(
                window: "five_hour",
                currentPct: latest.usedPercentage,
                previousPct: prev,
                resetsAt: latest.resetsAt,
                context: context
            )
        }
    }

    private func handleSevenDay() {
        guard let latest = samples.first(where: { $0.window == "seven_day" }) else { return }
        let prev = lastSeenSevenDay
        lastSeenSevenDay = latest.usedPercentage
        Task { @MainActor in
            await NotificationCoordinator.shared.handleRateLimitUpdate(
                window: "seven_day",
                currentPct: latest.usedPercentage,
                previousPct: prev,
                resetsAt: latest.resetsAt,
                context: context
            )
        }
    }

    private func handleDailyCost() {
        let current = todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
        let prev = lastSeenDailyCost
        lastSeenDailyCost = current
        // Only fire on upward crossing relative to last observation, so
        // an already-over-threshold today doesn't re-notify on
        // re-launch.
        guard let prev, current > prev else { return }
        let today = TokenSample.formatDate(Date())
        Task { @MainActor in
            await NotificationCoordinator.shared.handleDailyCostUpdate(
                currentCost: current,
                date: today,
                context: context
            )
        }
    }
}
