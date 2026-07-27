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
    /// Which rate-limit window's utilization drives the status-item icon's
    /// band color + gauge level. Stored as a window key: `"five_hour"` /
    /// `"seven_day"` for the fixed blocks, or a scoped `limits[]` identity for
    /// a per-model window. Chosen **explicitly** — the default is the 5-hour
    /// window's key (`"five_hour"`). A legacy empty string ("auto") still
    /// resolves to the 5-hour window for back-compat. When the chosen window
    /// disappears from the latest poll the icon falls back to the 5-hour window.
    /// See `MenuBarWindows.resolveDriver`.
    public static let menuBarIconDriver      = "pacer.menuBarIconDriver"
    /// CSV of up to 3 window keys, **outer → inner**, drawn as concentric
    /// activity rings when the icon style is `.activityRings`. Default
    /// `"five_hour,seven_day"` (the fixed 2-ring icon). A key whose window
    /// vanishes is skipped at render; an empty/all-vanished set falls back to
    /// the 5-hour window. See `MenuBarWindows.resolveRingWindows`.
    public static let menuBarRingWindows     = "pacer.menuBarRingWindows"
    /// CSV of menu-bar chip tokens in display order. Each token is EITHER a
    /// built-in `MenuBarChip` id (`icon`, `five_hour_pct`, …) OR a scoped
    /// per-model window chip encoded `scoped_pct:<identity>`, where `<identity>`
    /// is a `UsageLimit.identity` — so a saved list reads e.g.
    /// `"icon,five_hour_pct,scoped_pct:weekly_scoped|Fable|"`. The `scoped_pct:`
    /// prefix is deliberately opaque to the fixed-chip parser, so an OLDER
    /// client silently skips scoped chips it doesn't understand (no format
    /// break, no migration). Empty string = hide the status item entirely (the
    /// user toggled every chip off). Absent key = run the legacy-style migration
    /// on first launch with this build. Parse/serialize round trip lives in
    /// `MenuBarChipItem` (PacerCore).
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

    // MARK: - Local API / metrics server
    //
    // Opt-in HTTP server that exposes the same `PacerSnapshotPayload` over
    // `GET /v1/snapshot` (JSON), `GET /metrics` (Prometheus), and `GET
    // /v1/stream` (SSE). Off by default; bound to loopback unless the user
    // widens `apiBindHost`. See `PacerHTTPServer` in the App target.

    /// Whether the local API/metrics server runs. Default false.
    public static let apiEnabled  = "pacer.api.enabled"
    /// TCP port to listen on. Default `apiDefaultPort`.
    public static let apiPort     = "pacer.api.port"
    /// Bind address. Default `"127.0.0.1"` (loopback only). Set to `"0.0.0.0"`
    /// to accept connections from other devices on the network.
    public static let apiBindHost = "pacer.api.bindHost"
    /// Optional bearer token. When non-empty, every data endpoint requires
    /// `Authorization: Bearer <token>`. Empty = no auth (fine for loopback).
    public static let apiToken    = "pacer.api.token"
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

    /// Default port for the local API/metrics server. 7223 = "PACE" on a
    /// phone keypad — memorable and clear of common dev/observability ports
    /// (3000, 5000/AirPlay, 8080, 8888, 9090/Prometheus, 9100/node_exporter,
    /// 4317-4318/OTLP).
    public static let apiDefaultPort = 7223

    /// Resolved configuration for the local API/metrics server. Read by the
    /// App target's `PacerHTTPServer` on launch and whenever settings change.
    public struct APIServerConfig: Sendable, Equatable {
        public let enabled: Bool
        public let port: Int
        public let bindHost: String
        /// Trimmed; `nil` when the user left it blank (no auth required).
        public let token: String?

        public var isLoopback: Bool {
            bindHost == "127.0.0.1" || bindHost == "::1" || bindHost == "localhost"
        }
    }

    public static func apiServerConfig(from store: UserDefaults = store) -> APIServerConfig {
        let port = store.object(forKey: PacerPreferenceKeys.apiPort) != nil
            ? store.integer(forKey: PacerPreferenceKeys.apiPort) : apiDefaultPort
        let host = (store.string(forKey: PacerPreferenceKeys.apiBindHost) ?? "127.0.0.1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (store.string(forKey: PacerPreferenceKeys.apiToken) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return APIServerConfig(
            enabled: store.bool(forKey: PacerPreferenceKeys.apiEnabled),
            port: (1...65535).contains(port) ? port : apiDefaultPort,
            bindHost: host.isEmpty ? "127.0.0.1" : host,
            token: token.isEmpty ? nil : token)
    }
}
