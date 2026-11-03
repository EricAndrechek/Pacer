import Foundation

/// One PostHog event. Build it with the named constructors in
/// `AnalyticsEvents.swift`, which take enums and coarse numbers, never free
/// text; this type only carries the result.
public struct AnalyticsEvent: Sendable, Equatable {
    /// Unique per event, so a batch retried after a lost response is not
    /// counted twice (PostHog deduplicates on `uuid`).
    public let id: UUID
    public let name: String
    public var properties: Analytics.Properties
    /// Person properties (`$set`): the latest value wins.
    public var set: Analytics.Properties
    /// Person properties (`$set_once`): the first value wins.
    public var setOnce: Analytics.Properties
    /// When it happened. Not always now: a CLI run is forwarded later with
    /// the time it ran.
    public var timestamp: Date

    public init(_ name: AnalyticsEventName, properties: Analytics.Properties = [:],
                set: Analytics.Properties = [:], setOnce: Analytics.Properties = [:],
                timestamp: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.name = name.rawValue
        self.properties = properties
        self.set = set
        self.setOnce = setOnce
        self.timestamp = timestamp
    }
}

/// Every event Pacer sends to PostHog. snake_case; the full list with its
/// properties and caps is in docs/telemetry-plan.md ("PostHog").
public enum AnalyticsEventName: String, Sendable, CaseIterable {
    // App
    case appLaunched = "app_launched"
    case appQuit = "app_quit"
    case dashboardOpened = "dashboard_opened"
    case dashboardClosed = "dashboard_closed"
    case tabViewed = "tab_viewed"
    case detailOpened = "detail_opened"
    case controlChanged = "control_changed"
    case exportUsed = "export_used"
    case reportProblemOpened = "report_problem_opened"
    case updateInstalled = "update_installed"
    case settingChanged = "setting_changed"
    // Menu bar
    case menubarOpened = "menubar_opened"
    case menubarItemClicked = "menubar_item_clicked"
    case menubarContextAction = "menubar_context_action"
    // Widgets
    case widgetInventory = "widget_inventory"
    case widgetTapped = "widget_tapped"
    // CLI
    case cliCommand = "cli_command"
    // Other surfaces
    case shortcutRun = "shortcut_run"
    case apiRequest = "api_request"
    case notificationShown = "notification_shown"
    case notificationAction = "notification_action"
    // Daily
    case dailyCheckin = "daily_checkin"
}
