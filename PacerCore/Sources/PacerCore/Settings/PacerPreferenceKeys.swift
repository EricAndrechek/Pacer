import Foundation

/// Shared keys + accessors for the App Group `UserDefaults` suite that
/// the app, daemon, and widget extension all read. The App-side
/// `PacerSettings` extends this with SwiftUI-binding convenience and
/// the typed enums (MenuBarStyle, etc.); core types living here let
/// the daemon read prefs without depending on App-target code.
public enum PacerPreferenceKeys {
    public static let menuBarStyle           = "pacer.menuBarStyle"
    public static let menuBarIconStyle       = "pacer.menuBarIconStyle"
    public static let notificationsEnabled   = "pacer.notifications.enabled"
    public static let fiveHourThresholdPct   = "pacer.notifications.fiveHourThreshold"
    public static let sevenDayThresholdPct   = "pacer.notifications.sevenDayThreshold"
    public static let notifyOnDailyCost      = "pacer.notifications.dailyCost"
    public static let dailyCostThresholdUSD  = "pacer.notifications.dailyCostThreshold"
    public static let costMode               = "pacer.display.costMode"
}

/// Convenience accessor for the App Group-suite UserDefaults. Falls
/// back to `.standard` if the suite can't open (test contexts that
/// aren't running with the App Group entitlement).
public enum PacerPreferences {
    nonisolated(unsafe) public static let store: UserDefaults =
        UserDefaults(suiteName: PacerStore.appGroupIdentifier) ?? .standard

    /// Reads the user's cost-mode preference, mapping the string the
    /// Settings UI writes to a typed `CostMode`. Defaults to `.auto`
    /// when the key is absent or unrecognized — the app's
    /// `registerDefaults` writes "auto" on first launch, so this
    /// fallback is mostly for fresh-install daemons that ran before
    /// the app ever opened.
    public static func costMode() -> CostMode {
        let raw = store.string(forKey: PacerPreferenceKeys.costMode) ?? "auto"
        switch raw {
        case "calculate": return .calculate
        case "display":   return .display
        default:          return .auto
        }
    }
}
