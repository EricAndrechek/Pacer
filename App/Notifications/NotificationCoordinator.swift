import Foundation
import SwiftData
import UserNotifications
import PacerCore
import PacerUI

/// Posts local notifications when rate-limit usage or daily cost crosses
/// user-configured thresholds. The actual posting only happens while the
/// app is running — daemons inside the app bundle can't reliably post
/// banners, and the menu bar icon already gives at-a-glance escalation.
/// For "always-on push warnings" we'd need a separate UNNotification
/// extension or a helper LaunchAgent app; this is the v1 path.
///
/// Cycle dedup: we record `(window, threshold, resetsAt)` in
/// `ClaudeCodeMeta` after posting, so the same notification doesn't
/// fire twice in the same rate-limit cycle. Crossing 90% twice in one
/// 5h window posts once. A new cycle (different `resetsAt`) clears the
/// dedup naturally.
@MainActor
public final class NotificationCoordinator {
    public static let shared = NotificationCoordinator()

    private let center = UNUserNotificationCenter.current()
    private var authorizationRequested = false

    public init() {}

    /// Ask the system for authorization. No-op if already requested in
    /// this process. Safe to call from app launch even if the user
    /// hasn't enabled notifications yet — the actual posting is gated
    /// on `notificationsEnabled` further down.
    public func requestAuthorizationIfNeeded() async {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    public enum TestOutcome: Sendable {
        case delivered
        case denied
        case failed(String)
    }

    /// User-initiated dry-run from Settings. Posts a one-shot banner
    /// labeled "test" so the user can verify the auth flow + delivery
    /// without waiting for a real threshold crossing. Returns a typed
    /// outcome so the UI can render the right state.
    public func sendTestNotification() async -> TestOutcome {
        // Force-request auth even if we asked before — covers the
        // "user denied last time, then changed mind in System
        // Settings, now wants to retest" path.
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
            authorizationRequested = true
        } catch {
            return .failed(error.localizedDescription)
        }
        if !granted {
            return .denied
        }

        let content = UNMutableNotificationContent()
        content.title = "Pacer test notification"
        content.body = "Notifications are working. Real warnings fire when a window crosses your threshold."
        content.sound = .default
        // .timeSensitive lets the banner break through Focus modes and
        // — more importantly here — increases the odds that macOS
        // displays it as a popup rather than silently routing it to
        // Notification Center. Users still need "Banners" or "Alerts"
        // selected in System Settings → Notifications → Pacer; the
        // Settings UI now points at that with a helper button.
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: "pacer.test.\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return .delivered
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Inspect the latest `RateLimitSample` for a window and post a
    /// notification for every configured threshold the sample just
    /// crossed upward. `previousPct` is what we observed last time —
    /// passing it lets us detect "crossed upward" so we don't fire
    /// every time the sample sits above the line.
    ///
    /// Multi-threshold: a user with 50/75/90 configured for 5-hour
    /// gets up to three banners per cycle (one each as the line is
    /// crossed). Cycle dedup is keyed on `(window, threshold,
    /// resetsAt)` so re-launching mid-cycle doesn't re-fire any
    /// banner that's already been delivered.
    public func handleRateLimitUpdate(
        window: String,
        currentPct: Double,
        previousPct: Double?,
        resetsAt: Date?,
        context: ModelContext
    ) async {
        let defaults = PacerSettings.store
        guard defaults.bool(forKey: PacerSettings.Key.notificationsEnabled) else { return }
        let thresholds = PacerSettings.thresholds(forWindow: window)
        guard !thresholds.isEmpty else { return }
        let previous = previousPct ?? 0
        // Ascending iteration — banners arrive in the order the user
        // crossed them (50% before 75% before 90%) when a single
        // sample crosses multiple thresholds at once.
        for threshold in thresholds {
            let t = Double(threshold)
            guard previous < t, currentPct >= t else { continue }

            let cycleKey = "notif.\(window).\(threshold).\(resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "noreset")"
            if alreadyNotified(key: cycleKey, in: context) {
                continue
            }

            await requestAuthorizationIfNeeded()
            let content = UNMutableNotificationContent()
            content.title = "Pacer rate-limit warning"
            let label: String = window == "five_hour" ? "5-hour" : "7-day"
            content.body = "\(label) usage hit \(Int(currentPct.rounded()))% (threshold \(threshold)%)."
            content.sound = .default
            content.interruptionLevel = .timeSensitive

            let request = UNNotificationRequest(
                identifier: cycleKey,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
            markNotified(key: cycleKey, in: context)
        }
    }

    /// Identifier for the "Pacer paused" banner. Shared between the
    /// post path (`notifyCollectionPaused`) and the launch-time clear
    /// (`clearCollectionPausedNotification`) so the two stay in sync.
    private static let collectionPausedIdentifier = "pacer.collection.paused"

    /// Posts a one-shot banner when the user quits Pacer. Without it,
    /// a user with launch-at-login on but the menu bar hidden has no
    /// visible signal that data collection has stopped — Pacer goes
    /// silent and the next time they open it they'd see a gap with no
    /// idea why. Best-effort: if notifications haven't been authorized
    /// the post is silently dropped (we don't surface a permission
    /// prompt during quit, that'd be bad UX).
    ///
    /// The trigger is a small delay rather than immediate. A fast
    /// quit→relaunch cycle (e.g. `make install`) gives the new process
    /// time to preempt the still-pending request via
    /// `clearCollectionPausedNotification()` in `applicationDidFinish-
    /// Launching`. A genuine quit with no relaunch sees the banner
    /// land a few seconds later — invisible delay for the user.
    public func notifyCollectionPaused() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Pacer paused"
        content.body = "Reopen Pacer to resume tracking. Historical JSONL gets re-scanned on next launch."
        content.sound = nil // quiet — user just quit, don't be loud
        let request = UNNotificationRequest(
            identifier: Self.collectionPausedIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        )
        try? await center.add(request)
    }

    /// Clears any "Pacer paused" banner — pending or already delivered
    /// — for this bundle. Called from the app's launch path: by
    /// definition the user has reopened Pacer, so the "reopen Pacer"
    /// banner is moot. Also handles the dev-cycle case where the
    /// previous process scheduled but didn't finish delivering the
    /// notification before SIGKILL: the queued request can flush late
    /// once a process for the bundle exists again, and removing the
    /// pending request preempts it.
    public func clearCollectionPausedNotification() {
        let ids = [Self.collectionPausedIdentifier]
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Once-per-day informational summary. Fires at most once per
    /// local date once the configured hour has been reached.
    /// Independent of the daily-cost ceiling banner — that one fires
    /// when the user crosses a threshold; this one is purely
    /// informational ("here's how today went") at a time of the
    /// user's choosing.
    public func handleDailySummary(
        currentCost: Double,
        topModel: String?,
        modelCount: Int,
        date: String,
        context: ModelContext
    ) async {
        let defaults = PacerSettings.store
        guard defaults.bool(forKey: PacerSettings.Key.notifyDailySummary) else { return }
        // Hour gate: only fire once we're at or past the configured
        // hour locally.
        let configuredHour = defaults.integer(forKey: PacerSettings.Key.dailySummaryHour)
        let nowHour = Calendar.current.component(.hour, from: Date())
        guard nowHour >= configuredHour else { return }
        // Don't notify when there's literally nothing to report —
        // gives the user a clean "did Pacer break?" signal: if the
        // banner doesn't fire on a known-active day, something's
        // wrong upstream.
        guard currentCost > 0 else { return }

        let key = "notif.dailySummary.\(date)"
        if alreadyNotified(key: key, in: context) {
            return
        }

        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Pacer daily summary"
        let costStr = String(format: "$%.2f", currentCost)
        if let topModel, modelCount > 0 {
            let modelLabel = topModel
                .split(separator: "/").last.map(String.init) ?? topModel
            content.body = modelCount > 1
                ? "\(costStr) today across \(modelCount) models. Top: \(modelLabel)."
                : "\(costStr) today on \(modelLabel)."
        } else {
            content.body = "\(costStr) today."
        }
        content.sound = nil // quiet — informational, not urgent
        content.interruptionLevel = .passive

        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        try? await center.add(request)
        markNotified(key: key, in: context)
    }

    /// "Your window just reset" detection. Fires when the rolling
    /// window rolled over: previous utilization was meaningful (≥ this
    /// threshold), current utilization is near-zero, AND `resetsAt`
    /// moved forward (proving a real cycle boundary crossed — not just
    /// an unrelated dip in the same cycle).
    ///
    /// Dedup is keyed on the NEW `resetsAt` so we fire at most once
    /// per cycle even when the OAuth poller writes multiple low
    /// samples back-to-back as the new window starts at zero.
    public static let resetPreviousHigh: Double = 50
    public static let resetCurrentLow: Double = 10

    public func handleRateLimitReset(
        window: String,
        currentPct: Double,
        previousPct: Double?,
        resetsAt: Date?,
        previousResetsAt: Date?,
        context: ModelContext
    ) async {
        let defaults = PacerSettings.store
        guard defaults.bool(forKey: PacerSettings.Key.notificationsEnabled) else { return }
        guard defaults.bool(forKey: PacerSettings.Key.notifyOnReset) else { return }
        guard let previousPct, previousPct >= Self.resetPreviousHigh else { return }
        guard currentPct <= Self.resetCurrentLow else { return }
        guard let resetsAt, let previousResetsAt, resetsAt > previousResetsAt else {
            // No reset boundary movement — could be the same cycle's
            // utilization dipping (server-side accounting recompute).
            // Without the resetsAt advance we don't have proof the
            // cycle actually rolled.
            return
        }

        let cycleKey = "notif.reset.\(window).\(ISO8601DateFormatter().string(from: resetsAt))"
        if alreadyNotified(key: cycleKey, in: context) {
            return
        }

        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        let label: String = window == "five_hour" ? "5-hour" : "7-day"
        content.title = "Pacer \(label) limit reset"
        content.body = "You're back to \(Int(currentPct.rounded()))%. Next reset \(Self.formatRelative(resetsAt))."
        content.sound = nil  // informational — no need to startle
        content.interruptionLevel = .passive

        let request = UNNotificationRequest(identifier: cycleKey, content: content, trigger: nil)
        try? await center.add(request)
        markNotified(key: cycleKey, in: context)
    }

    private static func formatRelative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Today's-cost ceiling notification. Fires once per day-and-threshold
    /// pair so re-launching the app doesn't re-notify.
    public func handleDailyCostUpdate(
        currentCost: Double,
        date: String,
        context: ModelContext
    ) async {
        let defaults = PacerSettings.store
        guard defaults.bool(forKey: PacerSettings.Key.notifyOnDailyCost) else { return }
        let threshold = defaults.double(forKey: PacerSettings.Key.dailyCostThresholdUSD)
        guard threshold > 0 else { return }
        guard currentCost >= threshold else { return }

        let key = "notif.dailyCost.\(date).\(Int(threshold))"
        if alreadyNotified(key: key, in: context) {
            return
        }

        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Pacer spend warning"
        content.body = String(format: "Today's cost reached $%.2f (threshold $%.2f).", currentCost, threshold)
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        try? await center.add(request)
        markNotified(key: key, in: context)
    }

    /// Per-project budget breach. Fires once per (project, period,
    /// date) so a sustained over-budget day doesn't re-notify each
    /// time the recomputer touches the project's aggregate. Period
    /// is `"day"` or `"week"` — the caller decides which window the
    /// current cost compares against.
    public func handleProjectBudgetUpdate(
        projectPath: String,
        displayName: String,
        currentCost: Double,
        limit: Double,
        period: String,
        date: String,
        context: ModelContext
    ) async {
        let defaults = PacerSettings.store
        guard defaults.bool(forKey: PacerSettings.Key.notificationsEnabled) else { return }
        guard limit > 0 else { return }
        guard currentCost >= limit else { return }

        // Dedup key includes the date so a new day fresh-fires. Per-
        // period so daily + weekly breaches don't suppress each other
        // when both cross on the same calendar day.
        let key = "notif.projectBudget.\(period).\(projectPath).\(date)"
        if alreadyNotified(key: key, in: context) {
            return
        }

        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Pacer project budget"
        let periodLabel = period == "week" ? "weekly" : "daily"
        content.body = String(
            format: "%@ %@ budget reached %@ (limit %@).",
            displayName,
            periodLabel,
            pacerCost(currentCost),
            pacerCost(limit)
        )
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        try? await center.add(request)
        markNotified(key: key, in: context)
    }

    /// Custom user-defined alert rule. Dedup keyed on rule id + date
    /// so an over-threshold day only notifies once. A new day fresh-
    /// fires the rule.
    public func handleCustomRuleUpdate(
        ruleId: String,
        ruleName: String,
        metric: String,
        currentValue: Double,
        threshold: Double,
        date: String,
        context: ModelContext
    ) async {
        let defaults = PacerSettings.store
        guard defaults.bool(forKey: PacerSettings.Key.notificationsEnabled) else { return }
        guard threshold > 0 else { return }
        guard currentValue >= threshold else { return }

        let key = "notif.customRule.\(ruleId).\(date)"
        if alreadyNotified(key: key, in: context) {
            return
        }

        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Pacer alert: \(ruleName)"
        content.body = Self.formatRuleBody(
            metric: metric,
            currentValue: currentValue,
            threshold: threshold
        )
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        try? await center.add(request)
        markNotified(key: key, in: context)
    }

    private static func formatRuleBody(
        metric: String,
        currentValue: Double,
        threshold: Double
    ) -> String {
        if AlertRuleMetric.isCurrency(metric) {
            return String(
                format: "%@ reached %@ (threshold %@).",
                AlertRuleMetric.label(for: metric),
                pacerCost(currentValue),
                pacerCost(threshold)
            )
        } else {
            return String(
                format: "%@ reached %@ (threshold %@).",
                AlertRuleMetric.label(for: metric),
                pacerTokens(Int64(currentValue)),
                pacerTokens(Int64(threshold))
            )
        }
    }

    // MARK: - Cycle dedup helpers (keyed via ClaudeCodeMeta)

    /// Returns true if we've already notified for this key. Returns
    /// false on read failure rather than throwing so the caller never
    /// silently suppresses a notification because of a transient
    /// SwiftData hiccup.
    private func alreadyNotified(key: String, in context: ModelContext) -> Bool {
        let predicate = #Predicate<ClaudeCodeMeta> { $0.key == key }
        let descriptor = FetchDescriptor<ClaudeCodeMeta>(predicate: predicate)
        guard let rows = try? context.fetch(descriptor) else { return false }
        return rows.first?.value == "1"
    }

    private func markNotified(key: String, in context: ModelContext) {
        let predicate = #Predicate<ClaudeCodeMeta> { $0.key == key }
        let descriptor = FetchDescriptor<ClaudeCodeMeta>(predicate: predicate)
        if let existing = try? context.fetch(descriptor).first {
            existing.value = "1"
        } else {
            context.insert(ClaudeCodeMeta(key: key, value: "1"))
        }
        try? context.save()
    }
}
