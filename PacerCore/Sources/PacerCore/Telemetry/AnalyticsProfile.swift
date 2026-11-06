import Foundation
import Synchronization

/// The install's descriptive, slow-changing profile (Mac model, plan tiers,
/// account and client counts, install date, widgets, settings summaries,
/// toggles, version), carried on every PostHog event as `$set`.
///
/// Why: person data used to arrive only through `daily_checkin`, sent within
/// about 30 s of the first launch of a day or version. An event sent before
/// that check-in landed, or on an install whose check-in was delayed or
/// dropped, described nobody. The check-in stays the backstop and the only
/// carrier of everything that must not repeat.
///
/// **Only these keys, never more** (`keys`). Per-day tallies, counters,
/// forecast accuracy, usage bands, `cli.*` and `refreshes.*` stay on the
/// check-in: repeated on every event they would double count, and most need
/// store reads that must never run per click (AGENTS.md, "Hot paths stay
/// hot"). Every key here is already sent by the check-in, so no new kind of
/// data leaves.
///
/// **Cost per event**: the saved profile is read from disk once and cached in
/// memory; a stamp is a dictionary merge. The check-in refreshes it through
/// `save`, which is the only writer.
public final class AnalyticsProfile: Sendable {

    /// Read cheaply at any time (defaults, bundle, constants): the app
    /// recomputes these for every event, and they win over the saved copy.
    public static let liveKeys: Set<String> = [
        "version", "build.config", "macos",
        "menu_bar.shown", "menu_bar.chips", "menu_bar.icon_style", "menu_bar.icon_driver",
        "toggles.crash_reports", "toggles.performance", "toggles.usage_data",
        "env.model", "env.model_name",
    ]

    /// Known only once the check-in has gathered them (store, accounts,
    /// widgets, clients, install date): saved by it, replayed from disk.
    public static let savedKeys: Set<String> = [
        "accounts.count", "accounts.plans",
        "install.first_seen", "install.age_days",
        "clients.cli_count", "clients.desktop_count", "clients.profile_count",
        "widgets.count", "widgets.installed",
        "settings.menu_bar_chips", "settings.menu_bar_scoped_chips", "settings.menu_bar_icon_style",
        "settings.api_server_on", "settings.notifications_on", "settings.cost_mode",
        "settings.desktop_credentials_on", "settings.switcher_on", "settings.skill_installed",
        "lifecycle.login_item",
    ]

    public static let keys: Set<String> = liveKeys.union(savedKeys)

    /// The app's profile; `use(fileURL:)` points it at the App Group at
    /// launch. Without a file it is memory-only (tests, other processes).
    public static let shared = AnalyticsProfile()

    private struct State {
        var fileURL: URL?
        var cache: Analytics.Properties?
    }
    private let state = Mutex(State())

    public init(fileURL: URL? = nil) { state.withLock { $0.fileURL = fileURL } }

    public func use(fileURL: URL?) {
        state.withLock { $0.fileURL = fileURL; $0.cache = nil }
    }

    /// The saved part, loaded from disk on first use and then held in memory.
    public func saved() -> Analytics.Properties {
        state.withLock { s in
            if let cache = s.cache { return cache }
            let loaded = s.fileURL.flatMap(Self.read) ?? [:]
            s.cache = loaded
            return loaded
        }
    }

    /// Replaces the saved profile with the allow-listed part of `person`.
    /// Called by the daily check-in with the person dictionary it computed.
    public func save(_ person: Analytics.Properties) {
        let kept = person.filter { Self.savedKeys.contains($0.key) }
        let url: URL? = state.withLock { s in
            s.cache = kept
            return s.fileURL
        }
        guard let url else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = Self.encode(kept) { try? data.write(to: url, options: .atomic) }
    }

    /// `event` with the profile under its `$set`: saved first, then the live
    /// values, then whatever the event set itself, so the most specific wins.
    public func stamped(_ event: AnalyticsEvent, live: Analytics.Properties) -> AnalyticsEvent {
        var set = saved()
        for (key, value) in live where Self.liveKeys.contains(key) { set[key] = value }
        for (key, value) in event.set { set[key] = value }
        var out = event
        out.set = set
        return out
    }

    // MARK: - Disk

    static func encode(_ properties: Analytics.Properties) -> Data? {
        var object: [String: Any] = [:]
        for (key, value) in properties {
            switch value {
            case .string(let s): object[key] = s
            case .int(let i): object[key] = i
            case .double(let d): if d.isFinite { object[key] = d }
            case .bool(let b): object[key] = b
            case .list, .object: continue
            }
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func read(_ url: URL) -> Analytics.Properties? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: Analytics.Properties = [:]
        for (key, raw) in object where savedKeys.contains(key) {
            if let s = raw as? String { out[key] = .string(s) }
            else if let n = raw as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() { out[key] = .bool(n.boolValue) }
                else if CFNumberIsFloatType(n) { out[key] = .double(n.doubleValue) }
                else { out[key] = .int(n.intValue) }
            }
        }
        return out
    }
}
