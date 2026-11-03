import Foundation

/// Which preference keys become `setting_changed` and `control_changed`
/// events, and which of their values may be sent.
///
/// **Why a watch list over the defaults, not a call in every view.** Settings
/// and card controls all persist to `PacerPreferences.store` (`@AppStorage`),
/// so one observer that diffs these keys catches every change, from every
/// screen, without touching the views. Only listed keys are ever read, so
/// secrets (`oauthTokenOverride`, `apiToken`), paths and hosts can never
/// leave: they are simply not here. A value is sent only when it comes from a
/// fixed set; numbers (thresholds, ports, hours) send the key alone.
public enum AnalyticsSettings {

    public enum Values: Sendable, Equatable {
        /// Key only.
        case none
        case bool
        /// One of these raw values, else `other`.
        case fixed(Set<String>)
        /// Our own enum raw values (sort columns): tokenized.
        case identifier
        /// A window key, as its kind (`five_hour`, `seven_day`, `scoped`).
        case window
        /// `all` when empty, else `one`: the account scope, whose value is an
        /// account id and is never sent.
        case presence
        /// Menu bar chips: the built-in ones, sorted and `+`-joined, or
        /// `hidden` when there are none (the bar item is removed).
        case chips
    }

    public enum Kind: Sendable, Equatable {
        case setting(name: String)
        case control(card: String, control: String)
    }

    public struct Watched: Sendable, Equatable {
        public let key: String
        public let kind: Kind
        public let values: Values
    }

    static let timeRanges: Set<String> = ["7d", "30d", "90d", "1y", "all"]
    public static let iconStyles: Set<String> = ["gauge_needle", "ring_fill", "dot", "activity_rings"]
    public static let builtInChips: Set<String> = [
        "icon", "five_hour_pct", "seven_day_pct", "today_cost", "today_tokens", "active_model",
    ]

    public static let watched: [Watched] = {
        typealias K = PacerPreferenceKeys
        func s(_ key: String, _ name: String, _ v: Values) -> Watched { Watched(key: key, kind: .setting(name: name), values: v) }
        func c(_ key: String, _ card: String, _ control: String, _ v: Values) -> Watched {
            Watched(key: key, kind: .control(card: card, control: control), values: v)
        }
        return [
            s(K.menuBarIconStyle, "menu_bar_icon_style", .fixed(iconStyles)),
            s(K.menuBarIconDriver, "menu_bar_icon_driver", .window),
            s(K.menuBarRingWindows, "menu_bar_ring_windows", .none),
            s(K.menuBarChips, "menu_bar_chips", .chips),
            s(K.notificationsEnabled, "notifications", .bool),
            s(K.fiveHourThresholdsCSV, "notifications_five_hour_thresholds", .none),
            s(K.sevenDayThresholdsCSV, "notifications_seven_day_thresholds", .none),
            s(K.notifyOnDailyCost, "notifications_daily_cost", .bool),
            s(K.dailyCostThresholdUSD, "notifications_daily_cost_threshold", .none),
            s(K.notifyOnReset, "notifications_reset", .bool),
            s(K.alertSource, "notifications_alert_source", .fixed(Set(RateLimitAlertSource.allCases.map(\.rawValue)))),
            s(K.notifyGlobalReset, "notifications_global_reset", .bool),
            s(K.notifyBurnRate, "notifications_burn_rate", .bool),
            s(K.notifyBurnRateRearm, "notifications_burn_rate_rearm", .bool),
            s(K.burnRateImminentMinutes, "notifications_burn_rate_minutes", .none),
            s(K.notifyDailySummary, "notifications_daily_summary", .bool),
            s(K.dailySummaryHour, "notifications_daily_summary_hour", .none),
            s(K.costMode, "cost_mode", .fixed(["auto", "calculate", "display"])),
            s(K.timeRange, "time_range", .fixed(timeRanges)),
            s(K.desktopCredentialsEnabled, "desktop_credentials", .bool),
            s(K.switcherCredentialsEnabled, "switcher_credentials", .bool),
            s(K.telemetryCrashReports, "crash_reports", .bool),
            s(K.telemetryUsageData, "usage_data", .bool),
            s(K.apiEnabled, "api_server", .bool),
            s(K.apiPort, "api_port", .none),
            c("pacer.history.range", "history", "range", .fixed(timeRanges)),
            c("pacer.history.topDaysSort", "history_top_days", "sort", .identifier),
            c("pacer.heatmap.metric", "heatmap", "metric", .fixed(["cost", "tokens", "sessions"])),
            c("pacer.models.grouping", "models", "grouping", .fixed(["none", "family"])),
            c("pacer.models.range", "models", "range", .fixed(timeRanges)),
            c("pacer.models.sortField", "models", "sort", .identifier),
            c("pacer.models.metric", "models_share", "metric", .identifier),
            c("pacer.projects.range", "projects", "range", .fixed(timeRanges)),
            c("pacer.projects.topSort", "projects_top", "sort", .identifier),
            c(K.projectsSort, "projects", "sort", .identifier),
            c("pacer.todayByModel.sortField", "today_by_model", "sort", .identifier),
            c(UsageScope.key, "toolbar", "account_scope", .presence),
        ]
    }()

    /// The watched keys as plain strings, for diffing. Stays on the Mac.
    public static func snapshot(_ store: UserDefaults) -> [String: String] {
        var out: [String: String] = [:]
        for w in watched {
            if let v = store.object(forKey: w.key) { out[w.key] = "\(v)" }
        }
        return out
    }

    /// One event per watched key whose value differs between the snapshots.
    public static func changes(from old: [String: String], to new: [String: String]) -> [AnalyticsEvent] {
        watched.compactMap { w -> AnalyticsEvent? in
            let before = old[w.key], after = new[w.key]
            guard before != after else { return nil }
            let value = sendable(after, policy: w.values)
            switch w.kind {
            case .setting(let name): return .settingChanged(key: name, value: value)
            case .control(let card, let control): return .controlChanged(card: card, control: control, value: value)
            }
        }
    }

    /// The value as it may be sent, or nil for key-only.
    public static func sendable(_ raw: String?, policy: Values) -> String? {
        switch policy {
        case .none: return nil
        case .bool:
            guard let raw else { return nil }
            return raw == "1" || raw.lowercased() == "true" ? "true" : "false"
        case .fixed(let set):
            guard let raw else { return nil }
            return set.contains(raw) ? raw : "other"
        case .identifier:
            guard let raw else { return nil }
            let ok = raw.count <= 24 && raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            return ok ? raw : "other"
        case .window:
            return raw.map(AnalyticsVocabulary.windowKind) ?? "five_hour"
        case .presence:
            return (raw ?? "").isEmpty ? "all" : "one"
        case .chips:
            return chipsSummary(raw ?? "")
        }
    }

    public static func chipsSummary(_ csv: String) -> String {
        let chips = csv.split(separator: ",").map(String.init)
        if chips.isEmpty { return "hidden" }
        let builtIn = Set(chips.filter { builtInChips.contains($0) }).sorted()
        let scoped = chips.count - builtIn.count
        var parts = builtIn
        if scoped > 0 { parts.append("scoped") }
        return parts.joined(separator: "+")
    }
}
