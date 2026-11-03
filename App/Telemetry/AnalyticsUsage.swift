import AppKit
import Foundation
import PacerCore

/// The app-side state a few usage events need: how long the dashboard has
/// been open, which tab is showing and since when, what opened the window,
/// the app's version at the last launch (for `update_installed`), and the
/// settings watcher. Everything here runs on a user action, a window change
/// or a defaults write, never on a timer, a scan cycle or a frame.
///
/// All of it is a no-op while `Analytics` has no sink (tests, diagnostic
/// modes, builds without a PostHog token), and the sink checks the toggle.
@MainActor
final class AnalyticsUsage {

    static let shared = AnalyticsUsage()

    private let launchedAt = Date()
    private var dashboardOpenedAt: Date?
    private var tab: (name: String, since: Date)?
    /// What the next dashboard open is attributed to; reset after use.
    var nextDashboardTrigger: AnalyticsEvent.DashboardTrigger = .launch
    private var settingsSnapshot: [String: String] = [:]
    private var settingsObserver: NSObjectProtocol?

    static let lastVersionKey = "pacer.analytics.lastVersion"

    // MARK: - Launch and quit

    /// Once per launch, after `AnalyticsController` started.
    func appLaunched(loginOrigin: LaunchOrigin) {
        guard AnalyticsController.shared.isRunning else { return }
        let store = PacerPreferences.store
        let version = AnalyticsController.appVersion
        let previous = store.string(forKey: Self.lastVersionKey)
        store.set(version, forKey: Self.lastVersionKey)
        let updated = previous != nil && previous != version
        if updated, let previous {
            Analytics.capture(.updateInstalled(from: previous, to: version))
        }
        let origin: AnalyticsEvent.LaunchOrigin = updated ? .afterUpdate
            : (loginOrigin == .login ? .loginItem : .manual)
        Analytics.capture(.appLaunched(origin: origin, set: Self.personProperties()))
        startSettingsWatch()
    }

    func appQuit() {
        endDashboard()
        Analytics.capture(.appQuit(uptimeSeconds: Date().timeIntervalSince(launchedAt)))
    }

    /// Person properties that are cheap to read at any time (`$set`). The
    /// daily check-in adds accounts, install age and widgets.
    static func personProperties() -> Analytics.Properties {
        let store = PacerPreferences.store
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let consent = TelemetryConsent.state(store: store)
        let chips = store.string(forKey: PacerPreferenceKeys.menuBarChips) ?? ""
        return [
            "version": .string(AnalyticsController.appVersion),
            "build.config": .string(TelemetryController.buildConfig),
            "macos": .string("\(os.majorVersion).\(os.minorVersion)"),
            "menu_bar.shown": .bool(!chips.split(separator: ",").isEmpty),
            "menu_bar.chips": .string(AnalyticsSettings.chipsSummary(chips)),
            "menu_bar.icon_style": .string(AnalyticsSettings.sendable(
                store.string(forKey: PacerPreferenceKeys.menuBarIconStyle),
                policy: .fixed(AnalyticsSettings.iconStyles)) ?? "default"),
            "menu_bar.icon_driver": .string(AnalyticsSettings.sendable(
                store.string(forKey: PacerPreferenceKeys.menuBarIconDriver), policy: .window) ?? "five_hour"),
            "toggles.crash_reports": .bool(consent.crashes),
            "toggles.performance": .bool(consent.performance),
            "toggles.usage_data": .bool(consent.usage),
        ]
    }

    // MARK: - Dashboard and tabs

    /// The dashboard window became visible. Idempotent while it stays open.
    func dashboardShown() {
        guard dashboardOpenedAt == nil else { return }
        dashboardOpenedAt = Date()
        Analytics.capture(.dashboardOpened(trigger: nextDashboardTrigger))
        nextDashboardTrigger = .other
    }

    /// Closed, or hidden by the hotkey.
    func endDashboard() {
        endTab()
        guard let opened = dashboardOpenedAt else { return }
        dashboardOpenedAt = nil
        Analytics.capture(.dashboardClosed(openSeconds: Date().timeIntervalSince(opened)))
    }

    /// The tab now showing. Sends the previous one with its dwell time.
    func tabShown(_ name: String) {
        if tab?.name == name { return }
        endTab()
        tab = (name, Date())
    }

    private func endTab() {
        guard let tab else { return }
        self.tab = nil
        Analytics.capture(.tabViewed(tab: tab.name, dwellSeconds: Date().timeIntervalSince(tab.since)))
    }

    // MARK: - Settings and card controls

    /// One observer for every setting and card control (`AnalyticsSettings`
    /// lists the keys and which values may be sent). Defaults changes are
    /// rare and the diff reads ~40 keys, so this costs nothing measurable.
    private func startSettingsWatch() {
        guard settingsObserver == nil else { return }
        let store = PacerPreferences.store
        settingsSnapshot = AnalyticsSettings.snapshot(store)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsDidChange() }
        }
    }

    private func settingsDidChange() {
        let now = AnalyticsSettings.snapshot(PacerPreferences.store)
        guard now != settingsSnapshot else { return }
        let events = AnalyticsSettings.changes(from: settingsSnapshot, to: now)
        settingsSnapshot = now
        for event in events { Analytics.capture(event) }
    }
}
