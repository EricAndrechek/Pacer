import Foundation

/// Pure, view-agnostic policy for **rate-limit threshold alerts** — the "usage
/// hit N%" banners. Both the fixed 5h/7d windows and the scoped per-model
/// windows fire through the identical crossing rule; this type is the single
/// definition of that rule so the two paths can't drift, and so it's unit-
/// testable without the App target (which owns the actual `UNNotification`
/// posting).
public enum RateLimitThresholdPolicy {

    /// The thresholds a fresh sample just crossed **upward** since the previous
    /// reading — the exact set that should fire a banner this tick. `previous`
    /// is treated as 0 when unknown (cold start), matching the fixed-window
    /// behaviour. Returned ascending so multi-threshold banners arrive in the
    /// order the user crossed them (50 before 75 before 90).
    ///
    /// A threshold fires iff `previous < t <= current`, so a sample sitting
    /// above a line doesn't re-fire every tick — only the upward crossing does.
    public static func crossedThresholds(
        previous: Double?,
        current: Double,
        thresholds: [Int]
    ) -> [Int] {
        let prev = previous ?? 0
        return thresholds.sorted().filter { prev < Double($0) && current >= Double($0) }
    }
}

/// Pure helpers for **scoped** (per-model / per-surface) rate-limit alerts.
///
/// A scoped-window threshold alert is persisted as an `AlertRule` row with
/// `metric == AlertRuleMetric.rateLimitPct` and `scopedWindow == <identity>`
/// (the `UsageLimitSample.identity`). Multiple rows for one identity are the
/// multiple thresholds for that window — the SwiftData equivalent of the fixed
/// windows' CSV threshold list. Because the rows are ordinary persisted
/// records, a window that later disappears from the poll simply goes **dormant**
/// (its rows are kept, never evaluated while absent) and resumes when the window
/// returns — see `dormantIdentities`.
public enum ScopedRateLimitAlerts {

    /// Whether a scoped `UsageLimitSample` is a genuine per-model / per-surface
    /// window (vs. an account-wide `session` / `weekly_all` row that the fixed
    /// 5h/7d hero windows already own). Mirrors the dashboard's scoped-column
    /// filter (`PaceChartCard.scopedRows`) so Settings, the notifier, and the
    /// dashboard agree on exactly which windows are "scoped".
    public static func isModelOrSurfaceScoped(_ sample: UsageLimitSample) -> Bool {
        (sample.modelId?.isEmpty == false)
            || (sample.modelDisplayName?.isEmpty == false)
            || (sample.surface?.isEmpty == false)
    }

    /// The enabled threshold percentages configured for one scoped window,
    /// sorted ascending, deduped, and clamped to 1...99 — the same shape
    /// `PacerSettings.thresholds(forWindow:)` returns for the fixed windows, so
    /// the evaluation path is uniform. Empty ⇒ the window has no alert (the
    /// default for every scoped window until the user adds one).
    public static func thresholds(forIdentity identity: String, in rules: [AlertRule]) -> [Int] {
        let values = rules
            .filter { $0.enabled
                && $0.metric == AlertRuleMetric.rateLimitPct
                && $0.scopedWindow == identity }
            .map { Int($0.thresholdValue.rounded()) }
            .filter { (1...99).contains($0) }
        return Array(Set(values)).sorted()
    }

    /// Every scoped-window identity that has at least one rate-limit alert rule
    /// (enabled or not) — the set of windows the user has "configured". Used to
    /// surface dormant windows in Settings and to decide reactivation.
    public static func configuredIdentities(in rules: [AlertRule]) -> Set<String> {
        var out: Set<String> = []
        for rule in rules where rule.metric == AlertRuleMetric.rateLimitPct {
            if let id = rule.scopedWindow, !id.isEmpty { out.insert(id) }
        }
        return out
    }

    /// Configured scoped windows that are **absent** from the current poll —
    /// their alert rules are dormant: kept, not deleted, and never fired while
    /// the window is gone. If the window reappears in `present` it evaluates
    /// again with zero extra bookkeeping.
    public static func dormantIdentities(in rules: [AlertRule], present: Set<String>) -> Set<String> {
        configuredIdentities(in: rules).subtracting(present)
    }
}
