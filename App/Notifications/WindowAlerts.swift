import AppKit
@preconcurrency import UserNotifications
import PacerCore

extension Notification.Name {
    /// An alert's "Open Pacer" button, or a click on the alert itself.
    static let pacerOpenMainWindow = Notification.Name("PacerOpenMainWindow")
}

/// How Pacer's alerts behave once posted: one slot per account's window
/// (`AlertSlot`), cleared when that window resets, with "Mute until reset" and
/// "Open Pacer" buttons, shown even while Pacer is the app in front.
extension NotificationCoordinator {

    /// Category identifiers. A window alert gets both buttons; every other
    /// alert (spend, budgets, rules, summaries) only "Open Pacer", since there
    /// is no reset to mute it until.
    static let windowCategory = "pacer.window"
    static let generalCategory = "pacer.alert"
    static let muteAction = "pacer.mute"
    static let openAction = "pacer.open"

    /// Install the delegate and the buttons. The delegate "must be set before
    /// the application returns from application:didFinishLaunching…"
    /// (`UNUserNotificationCenter.h`), or a click that launched Pacer is lost.
    func installAlertHandling() {
        let center = UNUserNotificationCenter.current()
        center.delegate = AlertResponder.shared
        let open = UNNotificationAction(
            identifier: Self.openAction, title: "Open Pacer", options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "gauge.with.dots.needle.33percent"))
        let mute = UNNotificationAction(
            identifier: Self.muteAction, title: "Mute until reset", options: [],
            icon: UNNotificationActionIcon(systemImageName: "bell.slash"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.windowCategory, actions: [mute, open],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.generalCategory, actions: [open],
                                   intentIdentifiers: [], options: []),
        ])
    }

    // MARK: - Slots

    /// Post `content` into its window's slot, replacing whatever that
    /// account's window showed before. `dedupKey` is only for the log line,
    /// which used to be the identifier and so said which threshold and cycle
    /// fired; it still should.
    func postWindowAlert(_ content: UNMutableNotificationContent, windowKey: String,
                         resetsAt: Date?, dedupKey: String) async {
        content.categoryIdentifier = Self.windowCategory
        content.userInfo = AlertSlot.userInfo(windowKey: windowKey, window: Self.window(of: windowKey),
                                              resetsAt: resetsAt)
        let request = UNNotificationRequest(
            identifier: AlertSlot.identifier(windowKey: windowKey), content: content, trigger: nil)
        await post(request, logAs: dedupKey)
    }

    /// Take a window's alert down and end its mute: the window reset, so
    /// neither is true any more.
    func windowDidReset(windowKey: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [AlertSlot.identifier(windowKey: windowKey)])
        var mutes = Self.loadMutes()
        if mutes.until[windowKey] != nil {
            mutes.unmute(windowKey)
            Self.storeMutes(mutes)
        }
    }

    /// Remove every delivered window alert whose window has reset since.
    ///
    /// The reset detector needs two readings either side of the rollover
    /// (`RateLimitAlertRules.isReset`); this only needs the clock, so a
    /// window that reset while Pacer was closed, or at 0% where the server
    /// sends no reset instant afterwards, is cleared all the same.
    func sweepStaleWindowAlerts(now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let stale = delivered
                .filter { $0.request.identifier.hasPrefix(AlertSlot.prefix) }
                .filter { AlertSlot.isStale(resetsAt: AlertSlot.resetsAt(from: $0.request.content.userInfo), now: now) }
                .map(\.request.identifier)
            guard !stale.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: stale)
            Log.write("Notify", "cleared \(stale.count) alert(s) whose window reset: \(stale.joined(separator: ", "))")
        }
    }

    // MARK: - Mute until reset

    /// Whether `windowKey`'s warnings are muted now. A muted warning is still
    /// marked notified, so it does not fire later in the same cycle either.
    func isMuted(windowKey: String, now: Date = Date()) -> Bool {
        Self.loadMutes().isMuted(windowKey, now: now)
    }

    func mute(windowKey: String, resetsAt: Date?, now: Date = Date()) {
        var mutes = Self.loadMutes()
        mutes.prune(now: now)
        let window = Self.window(of: windowKey)
        mutes.mute(windowKey, resetsAt: resetsAt,
                   fallback: PaceMath.windowDuration(for: window) ?? 5 * 3600, now: now)
        Self.storeMutes(mutes)
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [AlertSlot.identifier(windowKey: windowKey)])
        Log.write("Notify", "muted \(windowKey) until \(mutes.until[windowKey].map { "\($0)" } ?? "?")")
    }

    private static func loadMutes() -> AlertMutes {
        AlertMutes(plist: PacerSettings.store.object(forKey: PacerSettings.Key.alertMutes))
    }

    private static func storeMutes(_ mutes: AlertMutes) {
        PacerSettings.store.set(mutes.plist, forKey: PacerSettings.Key.alertMutes)
    }

    /// `five_hour#<account>` → `five_hour`.
    static func window(of windowKey: String) -> String {
        windowKey.split(separator: "#", maxSplits: 1).first.map(String.init) ?? windowKey
    }
}

/// The notification centre's delegate. Stateless, so `Sendable`; every
/// decision hops to the main actor, where the coordinator lives.
final class AlertResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = AlertResponder()

    /// Show alerts while Pacer is the app in front too (owner, 2026-10-29).
    /// Without this method macOS does not present them at all: "If the
    /// method is not implemented … the notification will not be presented"
    /// (`UNUserNotificationCenter.h`).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        // Read everything off the response here: it is not Sendable.
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let windowKey = info[AlertSlot.windowKeyInfo] as? String
        let resetsAt = AlertSlot.resetsAt(from: info)
        await MainActor.run {
            switch action {
            case NotificationCoordinator.muteAction:
                // The test alert carries no window: nothing to mute.
                if let windowKey { NotificationCoordinator.shared.mute(windowKey: windowKey, resetsAt: resetsAt) }
            case NotificationCoordinator.openAction, UNNotificationDefaultActionIdentifier:
                NotificationCenter.default.post(name: .pacerOpenMainWindow, object: nil)
            default:
                break
            }
        }
    }
}
