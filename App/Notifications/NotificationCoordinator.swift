import Foundation
import SwiftData
import UserNotifications
import PacerCore

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
    /// notification if it crossed the user's threshold this cycle.
    /// `previousPct` is the percentage we observed last time we
    /// checked — passing it lets us detect "crossed upward" rather
    /// than firing every time we observe a sample above the line.
    public func handleRateLimitUpdate(
        window: String,
        currentPct: Double,
        previousPct: Double?,
        resetsAt: Date?,
        context: ModelContext
    ) async {
        let defaults = PacerSettings.store
        guard defaults.bool(forKey: PacerSettings.Key.notificationsEnabled) else { return }
        let key: String
        switch window {
        case "five_hour": key = PacerSettings.Key.fiveHourThresholdPct
        case "seven_day": key = PacerSettings.Key.sevenDayThresholdPct
        default: return
        }
        let threshold = Double(defaults.integer(forKey: key))
        guard threshold > 0 else { return }
        // We only notify on a fresh upward crossing — the prior reading
        // was below the threshold and the new one is at or above.
        let previous = previousPct ?? 0
        guard previous < threshold && currentPct >= threshold else { return }

        let cycleKey = "notif.\(window).\(Int(threshold)).\(resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "noreset")"
        if alreadyNotified(key: cycleKey, in: context) {
            return
        }

        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Pacer rate-limit warning"
        let label: String = window == "five_hour" ? "5-hour" : "7-day"
        content.body = "\(label) usage hit \(Int(currentPct.rounded()))% (threshold \(Int(threshold))%)."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: cycleKey,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
        markNotified(key: cycleKey, in: context)
    }

    /// Posts a one-shot banner when the user quits Pacer. Without it,
    /// a user with launch-at-login on but the menu bar hidden has no
    /// visible signal that data collection has stopped — Pacer goes
    /// silent and the next time they open it they'd see a gap with no
    /// idea why. Best-effort: if notifications haven't been authorized
    /// the post is silently dropped (we don't surface a permission
    /// prompt during quit, that'd be bad UX).
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
            identifier: "pacer.collection.paused",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
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

        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        try? await center.add(request)
        markNotified(key: key, in: context)
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
