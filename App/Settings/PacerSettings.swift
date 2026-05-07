import Foundation
import SwiftUI
import PacerCore

/// User-facing preferences. Stored in the App Group's shared
/// `UserDefaults` so future daemon/widget reads can pick up the same
/// values without an IPC round-trip. SwiftUI views bind with
/// `@AppStorage(key, store: PacerSettings.store)`.
///
/// Additive only — never remove or rename keys. If a key needs to
/// change semantics, add a new key alongside and migrate.
public enum PacerSettings {
    /// App Group-suite UserDefaults so the daemon, the app, the widget
    /// extension, and any future statusline tap can all read the same
    /// values. Falls back to `.standard` if the suite can't open
    /// (test contexts where the app group entitlement isn't present).
    /// `UserDefaults` is documented thread-safe, so the Swift 6
    /// non-Sendable concern is a false-positive here.
    nonisolated(unsafe) public static let store: UserDefaults =
        UserDefaults(suiteName: PacerStore.appGroupIdentifier) ?? .standard

    /// What the menu bar item shows. Hiding it entirely is a real
    /// use case for users who want the dashboard but not the
    /// status-bar icon, so we model "hidden" as a first-class mode.
    public enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
        case hidden            = "hidden"
        case iconOnly          = "icon"
        case percentOnly       = "percent"
        case iconAndPercent    = "icon_percent"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .hidden:           return "Hidden"
            case .iconOnly:         return "Icon only"
            case .percentOnly:      return "Percentage only"
            case .iconAndPercent:   return "Icon + percentage"
            }
        }

        public var defaultRaw: String { Self.iconAndPercent.rawValue }
    }

    public enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
        case gaugeNeedle  = "gauge_needle"
        case ringFill     = "ring_fill"
        case dot          = "dot"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .gaugeNeedle:  return "Gauge needle"
            case .ringFill:     return "Ring fill"
            case .dot:          return "Status dot"
            }
        }
    }

    // MARK: - Storage keys (centralized so we never typo at call sites)

    public enum Key {
        public static let menuBarStyle           = "pacer.menuBarStyle"
        public static let menuBarIconStyle       = "pacer.menuBarIconStyle"
        public static let notificationsEnabled   = "pacer.notifications.enabled"
        public static let fiveHourThresholdPct   = "pacer.notifications.fiveHourThreshold"
        public static let sevenDayThresholdPct   = "pacer.notifications.sevenDayThreshold"
        public static let notifyOnDailyCost      = "pacer.notifications.dailyCost"
        public static let dailyCostThresholdUSD  = "pacer.notifications.dailyCostThreshold"
        public static let costMode               = "pacer.display.costMode"
    }

    // MARK: - Defaults

    nonisolated(unsafe) public static let defaults: [String: Any] = [
        Key.menuBarStyle:          MenuBarStyle.iconAndPercent.rawValue,
        Key.menuBarIconStyle:      MenuBarIconStyle.gaugeNeedle.rawValue,
        Key.notificationsEnabled:  false,
        Key.fiveHourThresholdPct:  75,
        Key.sevenDayThresholdPct:  75,
        Key.notifyOnDailyCost:     false,
        Key.dailyCostThresholdUSD: 50.0,
        Key.costMode:              "auto",
    ]

    /// Register the defaults dict on first launch — `@AppStorage`'s
    /// own default-value parameter only kicks in when the key is
    /// totally absent, so we register here to make sure the suite
    /// has the right shape from launch one.
    public static func registerDefaults() {
        store.register(defaults: defaults)
    }
}
