import Foundation

/// The named constructors for every PostHog event (docs/telemetry-plan.md,
/// "PostHog"). Each one takes enums, our own vocabulary words or coarse
/// numbers, so a call site cannot pass free text by accident: strings that
/// come from the app's own enums go through `AnalyticsVocabulary.token`, and
/// names outside a known list become `other`.
extension AnalyticsEvent {

    // MARK: - App

    public enum LaunchOrigin: String, Sendable, CaseIterable {
        case loginItem = "login_item", manual, afterUpdate = "after_update", other
    }

    public static func appLaunched(origin: LaunchOrigin, set: Analytics.Properties = [:],
                                   setOnce: Analytics.Properties = [:]) -> AnalyticsEvent {
        AnalyticsEvent(.appLaunched, properties: ["origin": .string(origin.rawValue)],
                       set: set, setOnce: setOnce)
    }

    public static func appQuit(uptimeSeconds: TimeInterval) -> AnalyticsEvent {
        AnalyticsEvent(.appQuit, properties: ["uptime_minutes": .int(coarseMinutes(uptimeSeconds))])
    }

    public enum DashboardTrigger: String, Sendable, CaseIterable {
        case menu, hotkey, notification, settings, widget, launch, dock, other
    }

    public static func dashboardOpened(trigger: DashboardTrigger) -> AnalyticsEvent {
        AnalyticsEvent(.dashboardOpened, properties: ["trigger": .string(trigger.rawValue)])
    }

    public static func dashboardClosed(openSeconds: TimeInterval) -> AnalyticsEvent {
        AnalyticsEvent(.dashboardClosed, properties: ["open_seconds": .int(coarseSeconds(openSeconds))])
    }

    /// Sent when the user leaves a tab (or closes the window on it), with how
    /// long they stayed.
    public static func tabViewed(tab: String, dwellSeconds: TimeInterval) -> AnalyticsEvent {
        AnalyticsEvent(.tabViewed, properties: [
            "tab": .string(AnalyticsVocabulary.known(tab, in: AnalyticsVocabulary.tabs)),
            "dwell_seconds": .int(coarseSeconds(dwellSeconds)),
        ])
    }

    /// Every detail sheet, modal and popover the app can open.
    public enum Detail: String, Sendable, CaseIterable {
        /// History / dashboard day detail.
        case day
        case project
        case session
        /// The window forecast sheet: prediction details and the compare-models board.
        case projection
        case aliasManager = "alias_manager"
        case aliasEditor = "alias_editor"
        case collectionsManager = "collections_manager"
        case collectionEditor = "collection_editor"
        case bulkMerge = "bulk_merge"
        case chartShare = "chart_share"
        case projectBudget = "project_budget"
    }

    /// `pushed` is a drill-down inside an open modal (a session from a day).
    public static func detailOpened(_ which: Detail, pushed: Bool = false) -> AnalyticsEvent {
        AnalyticsEvent(.detailOpened, properties: [
            "which": .string(which.rawValue), "pushed": .bool(pushed),
        ])
    }

    /// A control inside a dashboard card. `value` must come from the
    /// control's own fixed set (a `TimeRange` raw value, a column name, a
    /// Bool); it is tokenized, never free text.
    public static func controlChanged(card: String, control: String, value: String?) -> AnalyticsEvent {
        var p: Analytics.Properties = [
            "card": .string(AnalyticsVocabulary.token(card)),
            "control": .string(AnalyticsVocabulary.token(control)),
        ]
        if let value { p["value"] = .string(AnalyticsVocabulary.token(value)) }
        return AnalyticsEvent(.controlChanged, properties: p)
    }

    public enum ExportFlavor: String, Sendable, CaseIterable {
        case dailyTotalsCSV = "daily_totals_csv"
        case dailyByModelCSV = "daily_by_model_csv"
        case projectTotalsCSV = "project_totals_csv"
        case chartImageCopy = "chart_image_copy"
        case chartImageSave = "chart_image_save"
        case chartImageShare = "chart_image_share"
    }

    public static func exportUsed(_ flavor: ExportFlavor) -> AnalyticsEvent {
        AnalyticsEvent(.exportUsed, properties: ["flavor": .string(flavor.rawValue)])
    }

    public enum ReportProblemSource: String, Sendable, CaseIterable {
        case helpMenu = "help_menu", statusMenu = "status_menu", settings
    }

    public static func reportProblemOpened(from source: ReportProblemSource) -> AnalyticsEvent {
        AnalyticsEvent(.reportProblemOpened, properties: ["from": .string(source.rawValue)])
    }

    public static func updateInstalled(from: String, to: String) -> AnalyticsEvent {
        AnalyticsEvent(.updateInstalled, properties: [
            "from_version": .string(AnalyticsVocabulary.version(from)),
            "to_version": .string(AnalyticsVocabulary.version(to)),
        ])
    }

    /// `value` only when the setting's values are a fixed set
    /// (`AnalyticsSettings` decides).
    public static func settingChanged(key: String, value: String?) -> AnalyticsEvent {
        var p: Analytics.Properties = ["setting": .string(AnalyticsVocabulary.token(key))]
        if let value { p["value"] = .string(AnalyticsVocabulary.token(value)) }
        return AnalyticsEvent(.settingChanged, properties: p)
    }

    // MARK: - Menu bar

    public static func menubarOpened() -> AnalyticsEvent { AnalyticsEvent(.menubarOpened) }

    public enum MenubarItem: String, Sendable, CaseIterable {
        case openPacer = "open_pacer", settings, reportProblem = "report_problem", quit
    }

    public static func menubarItemClicked(_ item: MenubarItem) -> AnalyticsEvent {
        AnalyticsEvent(.menubarItemClicked, properties: ["item": .string(item.rawValue)])
    }

    public static func menubarContextAction(_ item: MenubarItem) -> AnalyticsEvent {
        AnalyticsEvent(.menubarContextAction, properties: ["item": .string(item.rawValue)])
    }

    // MARK: - Widgets

    public static func widgetTapped(kind: String, family: String) -> AnalyticsEvent {
        AnalyticsEvent(.widgetTapped, properties: [
            "kind": .string(AnalyticsVocabulary.known(kind, in: AnalyticsVocabulary.widgetKinds)),
            "family": .string(AnalyticsVocabulary.known(family, in: AnalyticsVocabulary.widgetFamilies)),
        ])
    }

    // MARK: - Other surfaces

    public static func shortcutRun(intent: String) -> AnalyticsEvent {
        AnalyticsEvent(.shortcutRun, properties: [
            "intent": .string(AnalyticsVocabulary.known(intent, in: AnalyticsVocabulary.intents)),
        ])
    }

    /// One per endpoint and client family per day (the local API can be
    /// polled every second, so requests are tallied, not sent one by one).
    public static func apiRequest(endpoint: String, client: String, count: Int, day: Date) -> AnalyticsEvent {
        AnalyticsEvent(.apiRequest, properties: [
            "endpoint": .string(AnalyticsVocabulary.known(endpoint, in: AnalyticsVocabulary.apiEndpoints)),
            "client": .string(AnalyticsVocabulary.known(client, in: AnalyticsVocabulary.apiClients)),
            "count": .int(count),
        ], timestamp: day)
    }

    public enum NotificationKind: String, Sendable, CaseIterable {
        case threshold, reset, burnRate = "burn_rate", globalReset = "global_reset"
        case dailyCost = "daily_cost", projectBudget = "project_budget", customRule = "custom_rule"
        case dailySummary = "daily_summary", collectionPaused = "collection_paused", test
    }

    /// `window` is the window kind only (`five_hour`, `seven_day`, `scoped`),
    /// never the account part of a scoped key.
    public static func notificationShown(_ kind: NotificationKind, window: String?) -> AnalyticsEvent {
        var p: Analytics.Properties = ["kind": .string(kind.rawValue)]
        if let window { p["window"] = .string(AnalyticsVocabulary.windowKind(window)) }
        return AnalyticsEvent(.notificationShown, properties: p)
    }

    public enum NotificationAction: String, Sendable, CaseIterable { case mute, open, click, dismiss }

    public static func notificationAction(_ action: NotificationAction, window: String?) -> AnalyticsEvent {
        var p: Analytics.Properties = ["action": .string(action.rawValue)]
        if let window { p["window"] = .string(AnalyticsVocabulary.windowKind(window)) }
        return AnalyticsEvent(.notificationAction, properties: p)
    }

    // MARK: - Forecast models

    /// What happened to the compare sheet's speed-up (`ArenaSpeedUp`): the
    /// user turned it on or off, or it ended on its own.
    public enum SpeedUpAction: String, Sendable, CaseIterable {
        case start, stop, caughtUp = "caught_up", timeUp = "time_up"
    }

    /// What the arena's budget was held to when the speed-up started
    /// (`ArenaBudgetPolicy`): in use, on battery, or already the full core.
    public enum SpeedUpFrom: String, Sendable, CaseIterable {
        case inUse = "in_use", battery, lowPower = "low_power", thermal, full, unknown
    }

    /// `from` on a start; `heldSeconds`, sent as coarse minutes, on every end.
    public static func arenaSpeedUp(_ action: SpeedUpAction, from: SpeedUpFrom? = nil,
                                    heldSeconds: TimeInterval? = nil) -> AnalyticsEvent {
        var p: Analytics.Properties = ["action": .string(action.rawValue)]
        if let from { p["from"] = .string(from.rawValue) }
        if let heldSeconds { p["minutes"] = .int(coarseMinutes(heldSeconds)) }
        return AnalyticsEvent(.arenaSpeedUp, properties: p)
    }

    // MARK: - Coarse numbers

    /// Seconds, exact under a minute, then to 10 s under 10 minutes, then to
    /// the minute; capped at a day.
    public static func coarseSeconds(_ s: TimeInterval) -> Int {
        guard s.isFinite, s > 0 else { return 0 }
        let v = min(s, 86_400)
        if v < 60 { return Int(v.rounded()) }
        if v < 600 { return Int((v / 10).rounded()) * 10 }
        return Int((v / 60).rounded()) * 60
    }

    static func coarseMinutes(_ s: TimeInterval) -> Int {
        guard s.isFinite, s > 0 else { return 0 }
        return Int((min(s, 30 * 86_400) / 60).rounded())
    }
}

/// The words analytics properties may contain.
public enum AnalyticsVocabulary {

    public static let tabs: Set<String> = ["dashboard", "history", "projects", "models", "settings"]
    public static let widgetKinds: Set<String> = Set(WidgetKinds.all)
    public static let widgetFamilies: Set<String> = [
        "systemSmall", "systemMedium", "systemLarge", "systemExtraLarge",
        "accessoryCircular", "accessoryRectangular", "accessoryInline",
    ]
    public static let intents: Set<String> = [
        "GetUsageIntent", "GetSevenDayUsageIntent", "GetTodayCostIntent", "GetWeekCostIntent",
        "GetMonthCostIntent", "GetTodayTokensIntent", "GetProjectedTodayCostIntent",
        "GetFiveHourResetIntent", "GetWillHitLimitIntent", "GetPaceStatusIntent",
        "GetPacerSnapshotIntent", "RefreshScanIntent",
    ]
    public static let apiEndpoints: Set<String> = [
        "/healthz", "/", "/v1/snapshot", "/v1/accounts", "/metrics", "/v1/stream", "/v1/session",
        "/v1/usage/daily", "/v1/usage/models", "/v1/sessions", "/v1/limits/history",
        "/v1/predictions/history",
    ]
    public static let apiClients: Set<String> = [
        "curl", "wget", "python", "node", "go", "swift", "prometheus", "grafana", "browser",
        "pacer", "other", "none",
    ]

    /// The client family behind a local API request, from its User-Agent.
    /// Only the family word leaves the Mac; the header itself never does.
    public static func clientFamily(userAgent: String?) -> String {
        guard let ua = userAgent?.lowercased(), !ua.isEmpty else { return "none" }
        let rules: [(String, String)] = [
            ("prometheus", "prometheus"), ("grafana", "grafana"), ("curl", "curl"), ("wget", "wget"),
            ("python", "python"), ("aiohttp", "python"), ("node", "node"), ("axios", "node"),
            ("undici", "node"), ("go-http-client", "go"), ("pacer", "pacer"),
            ("cfnetwork", "swift"), ("darwin", "swift"), ("mozilla", "browser"),
        ]
        return rules.first { ua.contains($0.0) }?.1 ?? "other"
    }

    /// A window key as its kind: the fixed windows by name, any scoped
    /// (per-model or per-account) key as `scoped`.
    public static func windowKind(_ key: String) -> String {
        let base = key.split(separator: "#").first.map(String.init) ?? key
        return base == "five_hour" || base == "seven_day" ? base : "scoped"
    }

    /// `value` if it is one of `known`, else `other`.
    public static func known(_ value: String, in known: Set<String>) -> String {
        known.contains(value) ? value : "other"
    }

    /// Our own identifiers only: lowercased, `[a-z0-9_.:+-]`, at most 80
    /// characters. Anything else becomes `_`, so a stray path or sentence is
    /// mangled rather than sent (the scrubber runs after this as well).
    public static func token(_ raw: String) -> String {
        let mapped = raw.lowercased().map { c -> Character in
            c.isASCII && (c.isLetter || c.isNumber || "_.:+-".contains(c)) ? c : "_"
        }
        let s = String(mapped.prefix(80))
        return s.isEmpty ? "none" : s
    }

    /// A version string: digits and dots only ("0.8.1"), else `other`.
    public static func version(_ raw: String) -> String {
        let ok = !raw.isEmpty && raw.count <= 20 && raw.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
        return ok ? raw : "other"
    }
}
