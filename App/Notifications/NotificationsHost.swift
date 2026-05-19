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
    /// Cap the fetch to the most-recent N samples. The host only ever
    /// looks at `.first` for each of two windows, so a limit of 8 is
    /// more than enough to find both newest entries while bounding the
    /// per-save refetch cost. Without the cap, every `@Query`
    /// invalidation materialized every `RateLimitSample` row in the
    /// store just to read one float — the same kind of cost
    /// MenuBarLabel already addressed.
    @Query(NotificationsHost.recentRateLimitDescriptor)
    private var samples: [RateLimitSample]

    @Query private var todayAggregates: [DailyAggregate]

    @Environment(\.modelContext) private var context

    @State private var lastSeenFiveHour: Double?
    @State private var lastSeenSevenDay: Double?
    @State private var lastSeenDailyCost: Double?
    /// Most recent `resetsAt` we saw for each window. Reset detection
    /// fires when the new sample's `resetsAt` is strictly later than
    /// this — strong signal the cycle actually rolled over (vs the
    /// utilization just dipping mid-cycle from a server-side rollup
    /// recompute).
    @State private var lastSeenFiveHourResetsAt: Date?
    @State private var lastSeenSevenDayResetsAt: Date?
    /// `persistentModelID` of the most recent sample we already
    /// considered for each window. The `onChange` predicates below
    /// use this to short-circuit when SwiftData re-notifies with no
    /// new sample (e.g., because some unrelated row in the table
    /// changed). Avoids the `handleFiveHour`/`handleSevenDay` round
    /// trip when there's literally nothing new to react to.
    @State private var lastConsideredFiveHourId: PersistentIdentifier?
    @State private var lastConsideredSevenDayId: PersistentIdentifier?

    private static let recentRateLimitDescriptor: FetchDescriptor<RateLimitSample> = {
        var d = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)]
        )
        d.fetchLimit = 8
        return d
    }()

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
                    lastSeenFiveHourResetsAt = f.resetsAt
                }
                if let s = samples.first(where: { $0.window == "seven_day" }) {
                    lastSeenSevenDay = s.usedPercentage
                    lastSeenSevenDayResetsAt = s.resetsAt
                }
                lastSeenDailyCost = todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
                await NotificationCoordinator.shared.requestAuthorizationIfNeeded()
                // Daily-summary watchdog: tick every five minutes and
                // post the once-a-day banner when the user-configured
                // hour has been reached. Five minutes is fast enough
                // to land within a tight window of "9:00 PM" without
                // burning cycles. The coordinator's per-date dedup
                // makes redundant ticks no-ops.
                while !Task.isCancelled {
                    handleDailySummary()
                    try? await Task.sleep(for: .seconds(300))
                }
            }
    }

    private func handleFiveHour() {
        guard let latest = samples.first(where: { $0.window == "five_hour" }) else { return }
        // Short-circuit if we already evaluated this exact sample.
        // `@Query.onChange` can re-fire when an unrelated row changes
        // and our `.first(where:)` happens to resolve to the same
        // entity — without this guard we'd round-trip to the
        // NotificationCoordinator on every such re-fire.
        if latest.persistentModelID == lastConsideredFiveHourId { return }
        lastConsideredFiveHourId = latest.persistentModelID
        let prevPct = lastSeenFiveHour
        let prevResetsAt = lastSeenFiveHourResetsAt
        lastSeenFiveHour = latest.usedPercentage
        lastSeenFiveHourResetsAt = latest.resetsAt
        Task { @MainActor in
            await NotificationCoordinator.shared.handleRateLimitUpdate(
                window: "five_hour",
                currentPct: latest.usedPercentage,
                previousPct: prevPct,
                resetsAt: latest.resetsAt,
                context: context
            )
            await NotificationCoordinator.shared.handleRateLimitReset(
                window: "five_hour",
                currentPct: latest.usedPercentage,
                previousPct: prevPct,
                resetsAt: latest.resetsAt,
                previousResetsAt: prevResetsAt,
                context: context
            )
        }
    }

    private func handleSevenDay() {
        guard let latest = samples.first(where: { $0.window == "seven_day" }) else { return }
        if latest.persistentModelID == lastConsideredSevenDayId { return }
        lastConsideredSevenDayId = latest.persistentModelID
        let prevPct = lastSeenSevenDay
        let prevResetsAt = lastSeenSevenDayResetsAt
        lastSeenSevenDay = latest.usedPercentage
        lastSeenSevenDayResetsAt = latest.resetsAt
        Task { @MainActor in
            await NotificationCoordinator.shared.handleRateLimitUpdate(
                window: "seven_day",
                currentPct: latest.usedPercentage,
                previousPct: prevPct,
                resetsAt: latest.resetsAt,
                context: context
            )
            await NotificationCoordinator.shared.handleRateLimitReset(
                window: "seven_day",
                currentPct: latest.usedPercentage,
                previousPct: prevPct,
                resetsAt: latest.resetsAt,
                previousResetsAt: prevResetsAt,
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

    private func handleDailySummary() {
        let current = todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
        // Top model by cost. Multiple aggregate rows per (date, model)
        // shouldn't exist, but `max(by:)` is safe either way.
        let top = todayAggregates.max(by: { $0.totalCostUSD < $1.totalCostUSD })
        let modelCount = Set(todayAggregates.map(\.model)).count
        let today = TokenSample.formatDate(Date())
        Task { @MainActor in
            await NotificationCoordinator.shared.handleDailySummary(
                currentCost: current,
                topModel: top?.model,
                modelCount: modelCount,
                date: today,
                context: context
            )
        }
    }
}
