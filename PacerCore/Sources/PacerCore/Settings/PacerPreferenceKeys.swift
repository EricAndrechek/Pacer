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
    /// Single-threshold legacy keys. Kept for migration only — new code
    /// reads/writes the `*ThresholdsCSV` keys below, which support
    /// multiple thresholds per window. Migration runs at app launch
    /// when the CSV key is absent: we seed the CSV from the legacy
    /// Int so existing users don't lose their threshold.
    public static let fiveHourThresholdPct   = "pacer.notifications.fiveHourThreshold"
    public static let sevenDayThresholdPct   = "pacer.notifications.sevenDayThreshold"
    /// New multi-threshold storage. Comma-separated ints (e.g.
    /// "50,75,90"). UserDefaults arrays would also work but CSV is
    /// trivial to migrate and round-trip across types.
    public static let fiveHourThresholdsCSV  = "pacer.notifications.fiveHourThresholds"
    public static let sevenDayThresholdsCSV  = "pacer.notifications.sevenDayThresholds"
    public static let notifyOnDailyCost      = "pacer.notifications.dailyCost"
    public static let dailyCostThresholdUSD  = "pacer.notifications.dailyCostThreshold"
    public static let costMode               = "pacer.display.costMode"
    /// Time-range selector shared by Projects, Models, and any future
    /// "rolling N-day" view. Persisted so the user's last-chosen window
    /// is remembered across launches — the prior local-state @State
    /// reset to "90 days" every time the app reopened.
    public static let timeRange              = "pacer.view.timeRange"
    /// Sort field used by the Projects view. Persists across launches
    /// so reopening the app doesn't snap back to "by cost descending".
    public static let projectsSort           = "pacer.view.projectsSort"
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
    ///
    /// The `store` parameter lets tests inject an isolated suite so
    /// they don't race the live App Group store. Defaults to the
    /// shared store for production callers.
    public static func costMode(from store: UserDefaults = store) -> CostMode {
        let raw = store.string(forKey: PacerPreferenceKeys.costMode) ?? "auto"
        switch raw {
        case "calculate": return .calculate
        case "display":   return .display
        default:          return .auto
        }
    }
}
