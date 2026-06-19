import Foundation

/// Shared keys + accessors for the App Group `UserDefaults` suite that
/// the app, daemon, and widget extension all read. The App-side
/// `PacerSettings` extends this with SwiftUI-binding convenience and
/// the typed enums (MenuBarStyle, etc.); core types living here let
/// the daemon read prefs without depending on App-target code.
public enum PacerPreferenceKeys {
    /// Legacy single-style key. Kept for migration only — new code
    /// reads/writes `menuBarChips`, which lets the user pick any combo
    /// of icon + 5h% + 7d% + cost + tokens + active model and reorder
    /// them. Migration runs at app launch when the chips key is absent:
    /// we seed it from the legacy style so returning users keep what
    /// they had.
    public static let menuBarStyle           = "pacer.menuBarStyle"
    public static let menuBarIconStyle       = "pacer.menuBarIconStyle"
    /// CSV of `MenuBarChip` ids in display order, e.g.
    /// `"icon,five_hour_pct"`. Empty string = hide the status item
    /// entirely (the user toggled every chip off). Absent key = run
    /// the legacy-style migration on first launch with this build.
    public static let menuBarChips           = "pacer.menuBarChips"
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
    /// Fire a banner when a rate-limit window resets (utilization drops
    /// from a meaningful level to near-zero and the resetsAt boundary
    /// moves forward). Useful for users who pace work around the 5-hour
    /// window — they can be told "OK, you can keep going."
    public static let notifyOnReset          = "pacer.notifications.reset"
    /// Fire a banner when Anthropic resets rate limits *early* — an
    /// off-schedule global reset where utilization collapses to near-zero
    /// but the `resetsAt` cycle anchor does NOT move forward (distinct
    /// from `notifyOnReset`, which is the on-schedule rollover). Pacer
    /// confirms the drop holds across several minutes of polling before
    /// firing so a transient blip doesn't trigger it. Opt-in.
    public static let notifyGlobalReset      = "pacer.notifications.globalReset"
    /// Warn when the *rate* you're burning a window will hit the limit
    /// before it resets — i.e. on slope, not just the fixed-percent level
    /// the threshold alerts use. Tiered per cycle (heads-up → imminent) via
    /// `BurnWarningPolicy`. Opt-in.
    public static let notifyBurnRate         = "pacer.notifications.burnRate"
    /// Re-send the burn warning when the projected hit moves materially
    /// earlier within the same cycle (`BurnWarningPolicy.rearmFraction`).
    /// Default on — a projection that got dramatically worse is news.
    public static let notifyBurnRateRearm    = "pacer.notifications.burnRateRearm"
    /// Minutes-to-projected-hit below which the warning escalates to the
    /// "imminent" tier (time-sensitive, second notification allowed).
    public static let burnRateImminentMinutes = "pacer.notifications.burnRateImminentMinutes"
    /// Once-a-day "you spent X today" banner. Independent of the
    /// daily-cost ceiling above — that one fires when the threshold
    /// is exceeded; this one is purely informational at a chosen
    /// time of day (default 9 PM local).
    public static let notifyDailySummary     = "pacer.notifications.dailySummary"
    public static let dailySummaryHour       = "pacer.notifications.dailySummaryHour"
    public static let costMode               = "pacer.display.costMode"
    /// Time-range selector shared by Projects, Models, and any future
    /// "rolling N-day" view. Persisted so the user's last-chosen window
    /// is remembered across launches — the prior local-state @State
    /// reset to "90 days" every time the app reopened.
    public static let timeRange              = "pacer.view.timeRange"
    /// Sort field used by the Projects view. Persists across launches
    /// so reopening the app doesn't snap back to "by cost descending".
    public static let projectsSort           = "pacer.view.projectsSort"
    /// Manual OAuth access-token override. When non-empty, the OAuth
    /// poller uses this token instead of reading the access token out
    /// of the `Claude Code-credentials` keychain entry. Workaround for
    /// Claude Code 2.x not persisting refreshed tokens back to the
    /// keychain (see #6). Stored as a plain string; lives in the App
    /// Group UserDefaults suite alongside the rest of Pacer's prefs.
    public static let oauthTokenOverride     = "pacer.oauth.tokenOverride"
    /// Opt-in: also read Claude Desktop's credential (decrypting its
    /// `safeStorage` token cache) and use whichever of it / the Claude Code
    /// keychain token is freshest. Off by default — it decrypts another
    /// app's credential store and triggers a one-time keychain approval, so
    /// the user turns it on deliberately. Read-only; never refreshes.
    public static let desktopCredentialsEnabled = "pacer.desktop.credentialsEnabled"
    /// Set when the user dismisses the first-run "Also track Claude Desktop"
    /// nudge with "Not now" — so it never reappears. The feature itself stays
    /// reachable in Settings → Authentication; this only silences the banner.
    public static let desktopOnboardingDismissed = "pacer.desktop.onboardingDismissed"
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

    /// Trimmed OAuth token override. Returns nil for an absent or
    /// whitespace-only value so callers can `if let` straight through
    /// to the "use keychain" path. See #6 for why this exists.
    public static func oauthTokenOverride(from store: UserDefaults = store) -> String? {
        let raw = store.string(forKey: PacerPreferenceKeys.oauthTokenOverride) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the user opted in to reading Claude Desktop's credential.
    /// Defaults to `false` (key absent → off) so a fresh daemon never
    /// touches the Desktop keychain item without explicit consent.
    public static func desktopCredentialsEnabled(from store: UserDefaults = store) -> Bool {
        store.bool(forKey: PacerPreferenceKeys.desktopCredentialsEnabled)
    }
}
