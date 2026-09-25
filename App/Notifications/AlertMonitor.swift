import Foundation
import Observation
import SwiftData
import PacerCore
import PacerUI

/// Evaluates every threshold alert from the background service, whether or not
/// a window exists.
///
/// This used to be `NotificationsHost`, an invisible view inside the dashboard
/// window. A login launch closes the window, so a menu-bar-only session
/// evaluated no alerts at all, and reopening the window re-seeded its memory
/// from current data, silently swallowing anything that had crossed in between
/// (#143). Now it lives as long as the process, and what it remembers
/// (`AlertCrossingState`) is persisted, so each reading is judged exactly once.
///
/// What it decides is unchanged: the same `NotificationCoordinator` calls with
/// the same arguments, so banner wording and dedup keys are identical.
///
/// Reads run off the main thread on their own `ModelContext` and come back as
/// values. The view held six `@Query`s, which re-fetch on every store save;
/// this reads only when something relevant was written.
@MainActor
final class AlertMonitor {
    private let container: ModelContainer
    /// The coordinator records what it has notified (`ClaudeCodeMeta`) here.
    private lazy var context = ModelContext(container)
    private var state: AlertCrossingState
    private var scanObserver: NSObjectProtocol?
    private var tasks: [Task<Void, Never>] = []
    private var limitsInFlight = false, limitsAgain = false
    private var costsInFlight = false, costsAgain = false
    /// A daily summary asked for while an evaluation was already running.
    private var summaryPending = false

    private static let stateKey = "alerts.crossingState"
    /// Also how often the daily summary is considered: fast enough to land
    /// close to the configured hour, and the coordinator dedups per date.
    private static let tick: Duration = .seconds(300)

    init(container: ModelContainer) {
        self.container = container
        state = AlertCrossingState(data: UserDefaults.standard.data(forKey: Self.stateKey))
    }

    func start() {
        guard scanObserver == nil else { return }
        Log.write("Alerts", "evaluating from the background service, with or without a window")
        // New samples and alias re-bucketing move today's, the week's and each
        // project's cost. Rate-limit rows come through the write signal below.
        scanObserver = NotificationCenter.default.addObserver(
            forName: .pacerScanCycleDidComplete, object: nil, queue: .main
        ) { [weak self] note in
            let summary = note.object as? ScanCycleSummary
            guard summary?.samplesChanged == true || summary?.projectAttributionChanged == true
            else { return }
            MainActor.assumeIsolated { self?.evaluateCosts() }
        }
        tasks.append(Task { [weak self] in
            await NotificationCoordinator.shared.requestAuthorizationIfNeeded()
            await self?.followRateLimitWrites()
        })
        // The daily summary, the day rolling over, and a safety net under the
        // two signals: any reading they missed is judged here.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.evaluateLimits()
                self?.evaluateCosts(summary: true)
                try? await Task.sleep(for: Self.tick)
            }
        })
    }

    func stop() {
        if let scanObserver { NotificationCenter.default.removeObserver(scanObserver) }
        scanObserver = nil
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    // MARK: - Rate-limit windows

    /// Every rate-limit write, from every account's poll, bumps
    /// `RateLimitWriteSignal`, after the rows are saved.
    private func followRateLimitWrites() async {
        while !Task.isCancelled {
            await Self.nextRateLimitWrite()
            evaluateLimits()
        }
    }

    /// Returns at the next `RateLimitWriteSignal` bump. A write landing
    /// between one bump and re-arming is picked up by the periodic pass.
    private static func nextRateLimitWrite() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = RateLimitWriteSignal.shared.generation
            } onChange: {
                continuation.resume()
            }
        }
    }

    private func evaluateLimits() {
        guard !limitsInFlight else { limitsAgain = true; return }
        limitsInFlight = true
        let container = self.container
        let fallbackAccount = UsageScope.storedActiveAccountId
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                Self.readLimits(container: container, fallbackAccount: fallbackAccount)
            }.value
            await judge(snapshot)
            limitsInFlight = false
            if limitsAgain { limitsAgain = false; evaluateLimits() }
        }
    }

    struct LimitsSnapshot: Sendable {
        struct Scoped: Sendable { let row: ScopedWindowRow; let thresholds: [Int] }
        /// What a banner calls each account; nil while only one exists, so a
        /// single-account machine's wording is unchanged.
        var labels: [String: String] = [:]
        var fixed: [String: [LimitSamplePoint]] = [:]
        var scoped: [String: [Scoped]] = [:]
    }

    /// Every account's windows, not just the active login's: the account you
    /// are not signed into still has a 7-day window, and hitting its cap is
    /// exactly what you want to hear about. Scoped to *some* account, though:
    /// an unscoped "newest 8" interleaves logins and reads the gap between
    /// them as a crossing.
    nonisolated static func readLimits(
        container: ModelContainer, fallbackAccount: String?
    ) -> LimitsSnapshot {
        let context = ModelContext(container)
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        // A store with no `Account` rows yet (a first launch before the first
        // poll resolves an org) still gets its alerts.
        let ids = accounts.isEmpty ? fallbackAccount.map { [$0] } ?? [] : accounts.map(\.id)
        let rules = (try? context.fetch(FetchDescriptor<AlertRule>())) ?? []
        var out = LimitsSnapshot()
        if accounts.count > 1 {
            for account in accounts { out.labels[account.id] = account.shortLabel }
        }
        for id in ids {
            out.fixed[id] = ((try? context.fetch(
                LimitScope.rateLimits(account: id, limit: 8))) ?? []).map(\.limitPoint)
            // Already model/surface-scoped: the account-wide `session` /
            // `weekly_all` identities have no per-model rules.
            let rows = ((try? context.fetch(
                LimitScope.modelScopedLimits(account: id, limit: 64))) ?? []).map(\.scopedWindowRow)
            out.scoped[id] = rows.latestBatch().map {
                .init(row: $0, thresholds: ScopedRateLimitAlerts.thresholds(
                    forIdentity: $0.identity, account: id, in: rules))
            }
        }
        return out
    }

    private func judge(_ snapshot: LimitsSnapshot) async {
        let coordinator = NotificationCoordinator.shared
        for (account, rows) in snapshot.fixed {
            let label = snapshot.labels[account]
            for window in [RateLimitWindowName.fiveHour, RateLimitWindowName.sevenDay] {
                guard let latest = rows.first(where: { $0.window == window }),
                      let step = state.advance("\(account)|\(window)",
                                               percent: latest.usedPercentage,
                                               resetsAt: latest.resetsAt,
                                               sampledAt: latest.sampledAt)
                else { continue }
                save()
                await coordinator.handleRateLimitUpdate(
                    window: window, account: account, accountLabel: label,
                    currentPct: latest.usedPercentage, previousPct: step.previousPercent,
                    resetsAt: latest.resetsAt, context: context)
                await coordinator.handleRateLimitReset(
                    window: window, account: account, accountLabel: label,
                    currentPct: latest.usedPercentage, previousPct: step.previousPercent,
                    resetsAt: latest.resetsAt, previousResetsAt: step.previousResetsAt,
                    context: context)
            }
        }
        // Dormancy falls out naturally: only identities in an account's current
        // batch are looked at, so a window that vanished isn't evaluated (its
        // rules are kept) and resumes the moment it reappears.
        for (account, rows) in snapshot.scoped {
            let accountLabel = snapshot.labels[account]
            for scoped in rows {
                let row = scoped.row
                // Advanced even with no rule, so a rule added later judges the
                // next reading against a real previous one.
                guard let step = state.advance("\(account)|\(row.identity)",
                                               percent: row.percent, resetsAt: row.resetsAt,
                                               sampledAt: row.sampledAt)
                else { continue }
                save()
                guard !scoped.thresholds.isEmpty else { continue }
                await coordinator.handleScopedRateLimitUpdate(
                    identity: row.identity, account: account, accountLabel: accountLabel,
                    label: row.label, thresholds: scoped.thresholds,
                    currentPct: row.percent, previousPct: step.previousPercent,
                    resetsAt: row.resetsAt, context: context)
                await coordinator.handleRateLimitReset(
                    window: row.identity, account: account, accountLabel: accountLabel,
                    currentPct: row.percent, previousPct: step.previousPercent,
                    resetsAt: row.resetsAt, previousResetsAt: step.previousResetsAt,
                    labelOverride: row.label, context: context)
            }
        }
    }

    // MARK: - Spend

    private func evaluateCosts(summary: Bool = false) {
        summaryPending = summaryPending || summary
        guard !costsInFlight else { costsAgain = true; return }
        costsInFlight = true
        let summary = summaryPending
        summaryPending = false
        let container = self.container
        // Worked out per evaluation, so "today" follows the clock. The view's
        // `@Query` predicates fixed it at construction and read yesterday's
        // rows after midnight.
        let now = Date()
        let today = TokenSample.formatDate(now)
        let weekAgo = TokenSample.formatDate(
            Calendar.current.date(byAdding: .day, value: -6, to: now) ?? now)
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                Self.readCosts(container: container, today: today, weekAgo: weekAgo)
            }.value
            await judge(snapshot, summary: summary)
            costsInFlight = false
            if costsAgain { costsAgain = false; evaluateCosts() }
        }
    }

    struct CostsSnapshot: Sendable {
        struct Budget: Sendable { let path: String; let daily: Double?; let weekly: Double? }
        struct Rule: Sendable {
            let id: String, name: String, metric: String, threshold: Double, accountId: String?
        }
        struct Totals: Sendable { var todayCost = 0.0, weekCost = 0.0, todayTokens: Int64 = 0 }
        var today = ""
        var all = Totals()
        var topModel: String?
        var modelCount = 0
        var projectToday: [String: Double] = [:]
        var projectWeek: [String: Double] = [:]
        var budgets: [Budget] = []
        var rules: [Rule] = []
        var byAccount: [String: Totals] = [:]
    }

    /// Spend alerts are **deliberately global**, unlike every display surface.
    /// A view shows what you asked to see; an alert tells you something you
    /// did not ask about. A budget alarm that a display filter could silence is
    /// a footgun, so these always evaluate across every account. Per-account
    /// rules name their account explicitly.
    nonisolated static func readCosts(
        container: ModelContainer, today: String, weekAgo: String
    ) -> CostsSnapshot {
        let context = ModelContext(container)
        var out = CostsSnapshot()
        out.today = today

        let days = (try? context.fetch(FetchDescriptor<DailyAggregate>(
            predicate: #Predicate { $0.date >= weekAgo && $0.date <= today }))) ?? []
        var todayByModel: [String: Double] = [:]
        for row in days {
            out.all.weekCost += row.totalCostUSD
            guard row.date == today else { continue }
            out.all.todayCost += row.totalCostUSD
            out.all.todayTokens += row.inputTokens + row.outputTokens
            todayByModel[row.model, default: 0] += row.totalCostUSD
        }
        out.topModel = todayByModel.max { $0.value < $1.value }?.key
        out.modelCount = todayByModel.count

        let projects = (try? context.fetch(FetchDescriptor<ProjectDailyAggregate>(
            predicate: #Predicate { $0.date >= weekAgo && $0.date <= today }))) ?? []
        for row in projects {
            out.projectWeek[row.projectPath, default: 0] += row.totalCostUSD
            if row.date == today { out.projectToday[row.projectPath, default: 0] += row.totalCostUSD }
        }

        out.budgets = ((try? context.fetch(FetchDescriptor<ProjectBudget>())) ?? [])
            .filter(\.isActive)
            .map { .init(path: $0.projectPath, daily: $0.dailyLimitUSD, weekly: $0.weeklyLimitUSD) }
        out.rules = ((try? context.fetch(FetchDescriptor<AlertRule>())) ?? [])
            .filter(\.enabled)
            .map { .init(id: $0.id, name: $0.name, metric: $0.metric,
                         threshold: $0.thresholdValue, accountId: $0.accountId) }

        // Only paid for when a rule targets an account.
        if out.rules.contains(where: { !($0.accountId ?? "").isEmpty }) {
            let rows = (try? context.fetch(FetchDescriptor<AccountDailyAggregate>(
                predicate: #Predicate { $0.date >= weekAgo && $0.date <= today }))) ?? []
            for row in rows {
                var totals = out.byAccount[row.accountId] ?? .init()
                totals.weekCost += row.totalCostUSD
                if row.date == today {
                    totals.todayCost += row.totalCostUSD
                    totals.todayTokens += row.inputTokens + row.outputTokens
                }
                out.byAccount[row.accountId] = totals
            }
        }
        return out
    }

    private func judge(_ s: CostsSnapshot, summary: Bool) async {
        let coordinator = NotificationCoordinator.shared

        // Only on a rise, so the first sight of a day already over its
        // threshold doesn't fire.
        let rose = state.advanceDailyCost(s.all.todayCost, date: s.today)
        save()
        if rose {
            await coordinator.handleDailyCostUpdate(
                currentCost: s.all.todayCost, date: s.today, context: context)
        }

        // Level-triggered; the coordinator's per-(project, period, date) dedup
        // is what stops a project over budget re-firing every scan.
        for budget in s.budgets {
            let name = pacerShortPath(budget.path)
            // The week-end (today) is the weekly dedup date, so the banner can
            // fire again on a later day the rolling window crosses.
            for (period, limit, cost) in [("day", budget.daily, s.projectToday[budget.path]),
                                          ("week", budget.weekly, s.projectWeek[budget.path])] {
                guard let limit, let cost, cost >= limit else { continue }
                await coordinator.handleProjectBudgetUpdate(
                    projectPath: budget.path, displayName: name, currentCost: cost,
                    limit: limit, period: period, date: s.today, context: context)
            }
        }

        for rule in s.rules {
            let totals: CostsSnapshot.Totals
            if let target = rule.accountId, !target.isEmpty {
                // A rule naming an account that no longer exists is dormant,
                // not zero: "spend is $0, under your cap" for a login that is
                // gone would be worse than silence.
                guard let scoped = s.byAccount[target] else { continue }
                totals = scoped
            } else {
                totals = s.all
            }
            let value: Double
            switch rule.metric {
            case AlertRuleMetric.todayCost:   value = totals.todayCost
            case AlertRuleMetric.weeklyCost:  value = totals.weekCost
            case AlertRuleMetric.todayTokens: value = Double(totals.todayTokens)
            default: continue   // unknown metric: a newer build's, skip it
            }
            await coordinator.handleCustomRuleUpdate(
                ruleId: rule.id, ruleName: rule.name, metric: rule.metric,
                currentValue: value, threshold: rule.threshold, date: s.today, context: context)
        }

        if summary {
            await coordinator.handleDailySummary(
                currentCost: s.all.todayCost, topModel: s.topModel, modelCount: s.modelCount,
                date: s.today, context: context)
        }
    }

    private func save() {
        UserDefaults.standard.set(state.encoded(), forKey: Self.stateKey)
    }
}
