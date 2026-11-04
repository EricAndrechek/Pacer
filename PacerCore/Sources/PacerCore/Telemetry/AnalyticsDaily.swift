import Foundation

/// The once-a-day PostHog events (`daily_checkin`, `widget_inventory`) and
/// the CLI runs the app forwards (`cli_command`). Pure, so their mapping is
/// tested; the app gathers the inputs (`DailyCheckIn`).
extension AnalyticsEvent {

    /// The check-in snapshot (the approved field list the Sentry
    /// `checkin.snapshot` carried until 2026-11) as one event, plus the
    /// person properties PostHog groups people by.
    public static func dailyCheckin(attributes: Telemetry.Attributes, person: Analytics.Properties,
                                    setOnce: Analytics.Properties) -> AnalyticsEvent {
        var p: Analytics.Properties = [:]
        for (key, value) in attributes { p[key] = value.analyticsValue }
        return AnalyticsEvent(.dailyCheckin, properties: p, set: person, setOnce: setOnce)
    }

    // MARK: - CLI

    /// At most this many `cli_command` events a day; agents run `pacer`
    /// thousands of times. Runs are thinned evenly and each sent run carries
    /// `sample_weight` (runs per sent event), so totals add back up.
    public static let cliDailyLimit = 100

    public static func cliCommands(_ runs: [CLIRunLog.Run], limit: Int = cliDailyLimit) -> [AnalyticsEvent] {
        let kept = TelemetryBands.thinned(runs, limit: limit)
        guard !kept.isEmpty else { return [] }
        let weight = Double(runs.count) / Double(kept.count)
        return kept.map { run in
            var p: Analytics.Properties = [
                "subcommand": .string(AnalyticsVocabulary.token(run.subcommand)),
                "flags": .list(run.flags.map { .string(AnalyticsVocabulary.token($0)) }),
                "outcome": .string(run.outcome.rawValue),
                "sample_weight": .double((weight * 100).rounded() / 100),
            ]
            if let code = run.exitCode { p["exit_code"] = .int(Int(code)) }
            if let ms = run.milliseconds { p["duration_bucket"] = .string(cliDurationBucket(ms: ms)) }
            if let src = run.source { p["source"] = .string(AnalyticsVocabulary.known(src, in: ["api", "offline", "none"])) }
            return AnalyticsEvent(.cliCommand, properties: p, timestamp: run.at)
        }
    }

    /// Coarser at the top than `TelemetryBands.durationBucket`, because
    /// `gate` and `wait` can run for minutes.
    public static func cliDurationBucket(ms: Int) -> String {
        switch ms {
        case ..<1_000: TelemetryBands.durationBucket(ms: ms)
        case ..<2_000: "1000_2000"
        case ..<5_000: "2000_5000"
        case ..<30_000: "5s_30s"
        case ..<300_000: "30s_5m"
        default: "gt5m"
        }
    }
}

/// Installed widgets, from `WidgetCenter.getCurrentConfigurations`, as the
/// `widget_inventory` event and the `widgets.*` person properties.
public enum WidgetInventory {

    /// One placed widget. `fields` are its configuration as our own words:
    /// window kinds (`five_hour`, `seven_day`, `scoped`), a lookback range,
    /// whether a project is pinned. Never an account id, a project or a
    /// scoped window's identity.
    public struct Item: Sendable, Equatable {
        public let kind: String
        public let family: String
        public let fields: [String: String]

        public init(kind: String, family: String, fields: [String: String] = [:]) {
            self.kind = kind; self.family = family; self.fields = fields
        }
    }

    /// The config field names that may be sent.
    public static let fieldNames: Set<String> = ["primary_window", "secondary_window", "range", "pinned_project"]
    static let ranges: Set<String> = ["days7", "days14", "days30", "days90"]

    /// A widget's window parameter (an entity id: a fixed window key or a
    /// scoped identity), as its kind; `default` when unset.
    public static func windowField(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "default" }
        return AnalyticsVocabulary.windowKind(id)
    }

    public static func rangeField(_ raw: String?) -> String {
        guard let raw else { return "default" }
        return ranges.contains(raw) ? raw : "other"
    }

    /// The event. `refreshes` is yesterday's granted timeline refreshes per
    /// kind, from `WidgetRefreshLog`.
    public static func event(_ items: [Item], refreshes: [String: Int]) -> AnalyticsEvent {
        let sorted = items.sorted { ($0.kind, $0.family) < ($1.kind, $1.family) }
        let list: [Analytics.Value] = sorted.map { item in
            var o: [String: Analytics.Value] = [
                "kind": .string(AnalyticsVocabulary.known(item.kind, in: AnalyticsVocabulary.widgetKinds)),
                "family": .string(AnalyticsVocabulary.known(item.family, in: AnalyticsVocabulary.widgetFamilies)),
            ]
            for (k, v) in item.fields where fieldNames.contains(k) {
                o[k] = .string(AnalyticsVocabulary.token(v))
            }
            return .object(o)
        }
        var p: Analytics.Properties = ["widgets": .list(list), "count": .int(items.count)]
        for kind in AnalyticsVocabulary.widgetKinds.sorted() {
            if let n = refreshes[kind] { p["refreshes.\(WidgetRefreshLog.shortName(kind))"] = .int(n) }
        }
        return AnalyticsEvent(.widgetInventory, properties: p, set: personProperties(items))
    }

    /// `widgets.count`, `widgets.kinds` (distinct short names, sorted,
    /// `+`-joined, `none`) and `widgets.families`.
    public static func personProperties(_ items: [Item]) -> Analytics.Properties {
        let kinds = Set(items.map { AnalyticsVocabulary.known($0.kind, in: AnalyticsVocabulary.widgetKinds) })
            .map { $0 == "other" ? $0 : WidgetRefreshLog.shortName($0) }.sorted()
        let families = Set(items.map { AnalyticsVocabulary.known($0.family, in: AnalyticsVocabulary.widgetFamilies) }).sorted()
        return [
            "widgets.count": .int(items.count),
            "widgets.kinds": .string(kinds.isEmpty ? "none" : kinds.joined(separator: "+")),
            "widgets.families": .string(families.isEmpty ? "none" : families.joined(separator: "+")),
        ]
    }

    /// Granted timeline refreshes per kind in `[since, until)`.
    public static func refreshCounts(_ entries: [WidgetRefreshLog.Entry], since: Date, until: Date) -> [String: Int] {
        var out: [String: Int] = [:]
        for e in entries where e.event == .timeline && e.at >= since && e.at < until {
            out[e.kind, default: 0] += 1
        }
        return out
    }
}

/// Which `TelemetryCounters` keys are usage (PostHog only, since 2026-11)
/// rather than health or performance (still Sentry metrics too).
public enum CounterRouting {
    /// Usage: which tabs, menus, modals, alerts, Shortcuts and API routes
    /// were used. Not usage: click delay, stalls, data health, OAuth,
    /// credentials, capping, API snapshot build times.
    public static func isUsage(_ key: String) -> Bool {
        if key.hasPrefix("ui.click.") { return false }
        return key.hasPrefix("ui.") || key.hasPrefix("intent.") || key.hasPrefix("api.route.")
            || key.hasPrefix("api.request.")
    }
}

/// The URL a widget opens when tapped: `pacer://widget?kind=<kind>&family=<family>`.
/// The app opens the dashboard and records `widget_tapped` (kind and family
/// only). Without a URL a tap only activated the app, and the app could not
/// tell a widget tap from any other launch.
public enum WidgetTapURL {
    public static let scheme = "pacer"
    public static let host = "widget"

    public static func make(kind: String, family: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.queryItems = [URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "family", value: family)]
        return c.url
    }

    /// Kind and family of a widget tap URL; nil for any other URL.
    public static func parse(_ url: URL) -> (kind: String, family: String)? {
        guard url.scheme == scheme, url.host == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let kind = items.first { $0.name == "kind" }?.value ?? "other"
        let family = items.first { $0.name == "family" }?.value ?? "other"
        return (kind, family)
    }
}
