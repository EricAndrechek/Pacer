import SwiftUI
import SwiftData
import PacerCore
import PacerUI

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
    /// Loaded on a signal, not through `@Query`.
    ///
    /// These were `@Query`s with an `accountId` predicate, and that combination
    /// is the expensive one: an unpredicated capped fetch is served from
    /// CoreData's row cache, a predicated one is a real fetch — and a `@Query`
    /// re-executes on *every* context change, which for Pacer is every scan
    /// cycle. A profile put `NotificationsHost.body` at the top of main-thread
    /// time with 133 of its 177 samples inside the scoped fetch alone.
    @State private var samples: [LimitSamplePoint] = []

    /// Recent scoped `limits[]` rows for the **active** account, newest first,
    /// bounded. Drives the scoped per-model threshold alerts through the same
    /// crossing logic as the fixed 5h/7d windows.
    @State private var scopedSamples: [ScopedWindowRow] = []
    /// One row, unpredicated — cheap enough to re-run on every save, which is
    /// the point: it is what tells the two loads above that anything changed.
    @Query private var newestSignal: [RateLimitSample]
    @Query private var newestScopedSignal: [UsageLimitSample]

    @Query private var todayAggregates: [DailyAggregate]
    /// Per-project rollups for the last 7 days — covers both the
    /// daily-budget check (today's slice) and weekly-budget check
    /// (whole window). Predicate runs against the indexed
    /// `(projectPath, date)` keys.
    @Query private var projectAggregatesWindow: [ProjectDailyAggregate]
    /// Configured budgets. Small table — typically 0-10 rows.
    @Query private var budgets: [ProjectBudget]
    /// User-defined alert rules. Small table — typically 0-10 rows.
    @Query private var rules: [AlertRule]
    /// Rolling 7-day DailyAggregate window for weekly-cost rule
    /// evaluation. Today's portion is already loaded via
    /// `todayAggregates`; the extra 6 days here are bounded by the
    /// `(date >= weekAgo)` predicate so materialization stays ≤ ~50
    /// rows.
    @Query private var weekAggregates: [DailyAggregate]

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
    @State private var lastConsideredFiveHourId: Date?
    @State private var lastConsideredSevenDayId: Date?

    /// Per-scoped-identity change tracking, mirroring the fixed-window
    /// `lastSeen*` state but keyed by `UsageLimitSample.identity`. Seeded from
    /// the latest batch in `.task` so launching while already over a threshold
    /// doesn't fire.
    @State private var lastSeenScoped: [String: Double] = [:]
    @State private var lastSeenScopedResetsAt: [String: Date] = [:]
    /// Newest scoped-sample id already evaluated — short-circuits `onChange`
    /// re-fires that resolve to the same poll.
    @State private var lastConsideredScopedId: Date?

    /// Both limit queries are scoped to the **active login**, never to the
    /// window's scope — the same rule the spend alerts below already follow,
    /// and for the same reason. A view shows what you asked to see; an alert
    /// tells you what you did not. A threshold a display filter could silence
    /// is a footgun: scope the dashboard to work in the morning and stop
    /// hearing about the other account's cap all day.
    ///
    /// Scoping to *something* is not optional, though. With every account
    /// writing the live table, an unscoped "newest 8" is whichever login polled
    /// last, so the crossing detector would compare one account's utilisation
    /// against the other's and fire on the difference.
    ///
    /// Per-account alert *rules* remain a fine feature; inheriting a display
    /// scope is not the way to get them.

    /// **Deliberately global, unlike every display surface.**
    ///
    /// A view shows what you asked to see; an alert tells you something you
    /// did not ask about. Making a spend threshold conditional on a view
    /// filter means real overspend goes unreported because of an unrelated UI
    /// choice — you scope the dashboard to work in the morning and stop being
    /// told about personal spend for the rest of the day. A budget alarm that
    /// a display preference can silence is a footgun, so these rules always
    /// evaluate across every account.
    ///
    /// Per-account *rules* are a reasonable feature; inheriting the window's
    /// scope is not the way to get them.
    init() {
        let today = TokenSample.formatDate(Date())
        let weekAgo = TokenSample.formatDate(
            Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
        )
        _todayAggregates = Query(filter: #Predicate<DailyAggregate> { $0.date == today })
        _projectAggregatesWindow = Query(
            filter: #Predicate<ProjectDailyAggregate> {
                $0.date >= weekAgo && $0.date <= today
            }
        )
        _weekAggregates = Query(
            filter: #Predicate<DailyAggregate> {
                $0.date >= weekAgo && $0.date <= today
            }
        )
        var signal = FetchDescriptor<RateLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        signal.fetchLimit = 1
        signal.propertiesToFetch = [\.sampledAt]
        _newestSignal = Query(signal)
        var scopedSignal = FetchDescriptor<UsageLimitSample>(
            sortBy: [SortDescriptor(\.sampledAt, order: .reverse)])
        scopedSignal.fetchLimit = 1
        scopedSignal.propertiesToFetch = [\.sampledAt]
        _newestScopedSignal = Query(scopedSignal)
    }

    /// Newest timestamps across both tables — the trigger for a reload.
    private var reloadKey: String {
        let a = newestSignal.first?.sampledAt.timeIntervalSinceReferenceDate ?? 0
        let b = newestScopedSignal.first?.sampledAt.timeIntervalSinceReferenceDate ?? 0
        return "\(Int(a)):\(Int(b))"
    }

    @MainActor
    private func reloadSamples() {
        let account = UsageScope.storedActiveAccountId
        samples = ((try? context.fetch(LimitScope.rateLimits(account: account, limit: 8))) ?? [])
            .map(\.limitPoint)
        scopedSamples = ((try? context.fetch(
            LimitScope.modelScopedLimits(account: account, limit: 64))) ?? [])
            .map(\.scopedWindowRow)
    }

    // Compute the change-detection fingerprints in computed properties
    // — pre-Swift-6 the type inferencer could chew through a long
    // `.onChange` chain in milliseconds; the @Query / SwiftData macros
    // inflated the per-modifier inference cost enough that the same
    // chain now times out. Hoisting the .reduce(0, +) expressions
    // breaks the chain into separate type-checking islands.
    // The fingerprints are `sampledAt` rather than `persistentModelID` now
    // that the rows are values. A poll stamps every row it writes with one
    // timestamp, so it identifies a reading exactly as well as the object id
    // did — and unlike the id it stays meaningful across a reload.
    private var fiveHourFingerprint: Date? {
        samples.first { $0.window == "five_hour" }?.sampledAt
    }
    private var sevenDayFingerprint: Date? {
        samples.first { $0.window == "seven_day" }?.sampledAt
    }
    /// Newest scoped row's timestamp — changes exactly when a new poll lands,
    /// at which point `handleScoped` re-evaluates every identity in that batch.
    private var scopedFingerprint: Date? {
        scopedSamples.first?.sampledAt
    }
    private var todayCostFingerprint: Double {
        todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
    }
    private var projectWindowFingerprint: Double {
        projectAggregatesWindow.reduce(0) { $0 + $1.totalCostUSD }
    }
    private var weekCostFingerprint: Double {
        weekAggregates.reduce(0) { $0 + $1.totalCostUSD }
    }

    @ViewBuilder
    private func rateLimitWatchers(_ base: some View) -> some View {
        base
            .onChange(of: fiveHourFingerprint) { handleFiveHour() }
            .onChange(of: sevenDayFingerprint) { handleSevenDay() }
            .onChange(of: scopedFingerprint) { handleScoped() }
            .onChange(of: todayCostFingerprint) { handleDailyCost() }
            .onChange(of: projectWindowFingerprint) { handleProjectBudgets() }
            .onChange(of: weekCostFingerprint) { handleCustomRules() }
    }

    var body: some View {
        // Genuinely empty — this view has no UI. Its job is just to
        // hold @Query subscriptions so the onChange handlers fire.
        // The chain is split across two `@ViewBuilder` islands on purpose. The
        // type inferencer already struggled with six `.onChange` modifiers plus
        // the `@Query` macros (see the fingerprint comment above); swapping the
        // rate-limit rows for value types tipped it into "unable to type-check
        // in reasonable time". Splitting gives it two small problems.
        rateLimitWatchers(
            Color.clear
                .frame(width: 0, height: 0)
                .task(id: reloadKey) { reloadSamples() }
        )
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
                // Seed scoped windows from the latest batch so an
                // already-over-threshold window at launch doesn't fire.
                for row in scopedSamples.latestBatch() {
                    lastSeenScoped[row.identity] = row.percent
                    lastSeenScopedResetsAt[row.identity] = row.resetsAt
                }
                lastConsideredScopedId = scopedSamples.first?.sampledAt
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
        if latest.sampledAt == lastConsideredFiveHourId { return }
        lastConsideredFiveHourId = latest.sampledAt
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
        if latest.sampledAt == lastConsideredSevenDayId { return }
        lastConsideredSevenDayId = latest.sampledAt
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

    /// Evaluate every scoped per-model window present in the active account's
    /// latest poll against its configured `AlertRule` thresholds, and dispatch
    /// threshold + reset banners through the same coordinator path as 5h/7d.
    ///
    /// Dormancy falls out naturally: only identities in the current batch are
    /// looped, so a window that vanished isn't evaluated (its rules are kept in
    /// the store, untouched) and resumes the moment it reappears.
    private func handleScoped() {
        let batch = scopedSamples.latestBatch()
        guard let newestId = batch.first?.sampledAt else { return }
        // Short-circuit an onChange re-fire that resolves to the same poll.
        if newestId == lastConsideredScopedId { return }
        lastConsideredScopedId = newestId

        // Already model/surface-scoped — the fetch excludes the account-wide
        // `session`/`weekly_all` identities, which have no per-model rules.
        for row in batch {
            let identity = row.identity
            let thresholds = ScopedRateLimitAlerts.thresholds(forIdentity: identity, in: rules)
            let prevPct = lastSeenScoped[identity]
            let prevResetsAt = lastSeenScopedResetsAt[identity]
            lastSeenScoped[identity] = row.percent
            lastSeenScopedResetsAt[identity] = row.resetsAt

            // Skip the coordinator round-trip when this window has no alert
            // (the default) — nothing to fire, and reset alerts still need a
            // configured window to be meaningful here.
            guard !thresholds.isEmpty else { continue }
            let label = row.label
            let pct = row.percent
            let resetsAt = row.resetsAt
            Task { @MainActor [context] in
                await NotificationCoordinator.shared.handleScopedRateLimitUpdate(
                    identity: identity,
                    label: label,
                    thresholds: thresholds,
                    currentPct: pct,
                    previousPct: prevPct,
                    resetsAt: resetsAt,
                    context: context
                )
                await NotificationCoordinator.shared.handleRateLimitReset(
                    window: identity,
                    currentPct: pct,
                    previousPct: prevPct,
                    resetsAt: resetsAt,
                    previousResetsAt: prevResetsAt,
                    labelOverride: label,
                    context: context
                )
            }
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

    /// For every active project budget, sum the matching cost (today
    /// or week-to-date), compare to the configured limit, and dispatch
    /// to NotificationCoordinator on a breach. The coordinator's
    /// per-(project, period, date) dedup is the only thing keeping us
    /// from re-firing on every aggregate update once a project is
    /// over its budget — without it the same breach would notify on
    /// every scan tick.
    private func handleProjectBudgets() {
        let today = TokenSample.formatDate(Date())
        let cal = Calendar.current
        let weekAgo = TokenSample.formatDate(
            cal.date(byAdding: .day, value: -6, to: Date()) ?? Date()
        )

        // Aggregate sum per (projectPath, period). Single pass.
        var todayByProject: [String: Double] = [:]
        var weekByProject: [String: Double] = [:]
        for row in projectAggregatesWindow {
            if row.date == today {
                todayByProject[row.projectPath, default: 0] += row.totalCostUSD
            }
            if row.date >= weekAgo && row.date <= today {
                weekByProject[row.projectPath, default: 0] += row.totalCostUSD
            }
        }

        for budget in budgets where budget.isActive {
            let displayName = pacerShortPath(budget.projectPath)
            if let limit = budget.dailyLimitUSD,
               let cost = todayByProject[budget.projectPath],
               cost >= limit {
                Task { @MainActor [context] in
                    await NotificationCoordinator.shared.handleProjectBudgetUpdate(
                        projectPath: budget.projectPath,
                        displayName: displayName,
                        currentCost: cost,
                        limit: limit,
                        period: "day",
                        date: today,
                        context: context
                    )
                }
            }
            if let limit = budget.weeklyLimitUSD,
               let cost = weekByProject[budget.projectPath],
               cost >= limit {
                // Use the week-end (today) as the dedup date so the
                // banner re-fires next time the rolling 7-day window
                // crosses the limit again on a different day.
                Task { @MainActor [context] in
                    await NotificationCoordinator.shared.handleProjectBudgetUpdate(
                        projectPath: budget.projectPath,
                        displayName: displayName,
                        currentCost: cost,
                        limit: limit,
                        period: "week",
                        date: today,
                        context: context
                    )
                }
            }
        }
    }

    /// Evaluate every active custom alert rule against the current
    /// aggregate snapshot and dispatch on threshold breach. Rule
    /// types we don't recognize are silently skipped (forward-
    /// compatibility with future builds).
    private func handleCustomRules() {
        let today = TokenSample.formatDate(Date())
        let todayCost = todayAggregates.reduce(0) { $0 + $1.totalCostUSD }
        let todayTokens = todayAggregates.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens
        }
        let weekCost = weekAggregates.reduce(0) { $0 + $1.totalCostUSD }

        for rule in rules where rule.enabled {
            let currentValue: Double?
            switch rule.metric {
            case AlertRuleMetric.todayCost:
                currentValue = todayCost
            case AlertRuleMetric.weeklyCost:
                currentValue = weekCost
            case AlertRuleMetric.todayTokens:
                currentValue = Double(todayTokens)
            default:
                currentValue = nil
            }
            guard let value = currentValue else { continue }
            Task { @MainActor [context] in
                await NotificationCoordinator.shared.handleCustomRuleUpdate(
                    ruleId: rule.id,
                    ruleName: rule.name,
                    metric: rule.metric,
                    currentValue: value,
                    threshold: rule.thresholdValue,
                    date: today,
                    context: context
                )
            }
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
