import Foundation

/// What each Settings → Privacy toggle allows, and the one-time migration
/// from the first telemetry release's meaning of the toggles.
///
/// **The two toggles** (decided 2026-11-03):
/// - "Crash reports and performance" (`telemetryCrashReports`, Sentry):
///   crashes, hangs, MetricKit, performance metrics and spans, forecast
///   accuracy, release-health sessions, and a minimal daily check-in
///   (version, macOS, Mac model, build config) so crash rates per version
///   have a denominator.
/// - "Usage data" (`telemetryUsageData`, PostHog): which features are used.
///
/// **Migration.** In the first release, "Share usage data" also covered
/// Sentry's performance metrics, spans, sessions and check-in. Someone who
/// turned it off refused those, so after this release they must stay off
/// even though they now live under the other toggle. `migrate` runs once per
/// install (flag `telemetryMigrated`): if the old usage toggle was explicitly
/// off it sets `telemetryPerformanceHeld`, which keeps Sentry to crashes,
/// hangs and MetricKit only. PostHog stays off because it reads the same
/// usage key. The hold lifts the first time the user changes either toggle
/// (`userChangedToggle`), because then they have seen the new pair. Nothing a
/// user refused is ever turned on by an upgrade.
public enum TelemetryConsent {

    public struct State: Sendable, Equatable {
        /// Crashes, hangs, MetricKit, problem reports (Sentry).
        public let crashes: Bool
        /// Performance metrics and spans, sessions, forecast accuracy and
        /// the minimal check-in (Sentry).
        public let performance: Bool
        /// Product usage events (PostHog).
        public let usage: Bool
    }

    /// Runs once per install. Call before the first read of `state`.
    public static func migrate(store: UserDefaults) {
        guard !store.bool(forKey: PacerPreferenceKeys.telemetryMigrated) else { return }
        if (store.object(forKey: PacerPreferenceKeys.telemetryUsageData) as? Bool) == false {
            store.set(true, forKey: PacerPreferenceKeys.telemetryPerformanceHeld)
        }
        store.set(true, forKey: PacerPreferenceKeys.telemetryMigrated)
    }

    /// The Settings toggles call this when the user flips either one: the
    /// migration hold ends once they have chosen under the new pair.
    public static func userChangedToggle(store: UserDefaults) {
        store.removeObject(forKey: PacerPreferenceKeys.telemetryPerformanceHeld)
    }

    /// Read on every send (toggles apply at once).
    public static func state(store: UserDefaults) -> State {
        let crashes = PacerPreferences.telemetryCrashReportsEnabled(from: store)
        let held = store.bool(forKey: PacerPreferenceKeys.telemetryPerformanceHeld)
        return State(crashes: crashes,
                     performance: crashes && !held,
                     usage: PacerPreferences.telemetryUsageDataEnabled(from: store))
    }
}
