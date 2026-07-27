import Foundation
import SwiftData

/// User-defined notification rule. Complements the built-in
/// rate-limit-threshold and daily-cost ceiling — those cover the
/// common 90% of needs without per-rule UI; this table covers the
/// long tail (weekly spend cap, token budgets, future per-model
/// caps).
///
/// Stored separately from `ProjectBudget` because:
///   - Project budgets are inherently per-project (one row per
///     project); alert rules are global with arbitrary names.
///   - The settings UI surfaces them differently — projects edit
///     budgets inline in the project drill-down, while custom
///     rules live in a Settings card.
///
/// The `metric` field is a stringly-typed enum (string for SwiftData
/// stability across future enum case additions). The notification
/// host knows how to evaluate each known metric; unknown metrics
/// are silently skipped (forward-compatibility with a future build
/// that emits new metric types).
@Model
public final class AlertRule {
    @Attribute(.unique) public var id: String
    public var name: String
    public var metric: String
    public var thresholdValue: Double
    public var enabled: Bool
    public var createdAt: Date

    /// Optional scoped rate-limit window this rule targets, as a
    /// `UsageLimitSample.identity` (`kind|model|surface`). Used by
    /// `metric == AlertRuleMetric.rateLimitPct` rules to alert on a per-model /
    /// per-surface window (e.g. a "Fable" weekly cap) exactly like the fixed
    /// 5h/7d windows — one row per configured threshold. `nil` for the existing
    /// account-wide cost/token rules, which don't target a window.
    ///
    /// Additive + optional ⇒ a SwiftData lightweight-migration-safe change: old
    /// rows decode this as `nil` with no store reset (same pattern as
    /// `UsageLimitSample.accountId`). When the targeted window disappears from
    /// the poll the row is simply kept and not evaluated (dormant); it resumes
    /// if the window returns. See `ScopedRateLimitAlerts`.
    public var scopedWindow: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        metric: String,
        thresholdValue: Double,
        scopedWindow: String? = nil,
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.metric = metric
        self.thresholdValue = thresholdValue
        self.scopedWindow = scopedWindow
        self.enabled = enabled
        self.createdAt = createdAt
    }
}

/// Known metric identifiers. New metrics: add a case here, teach the
/// notification host how to evaluate it, and (if needed) extend the
/// Settings picker. Old builds will silently skip metrics they don't
/// recognize — string storage is forward-compatible.
public enum AlertRuleMetric {
    /// Total spend today (sum of today's `DailyAggregate.totalCostUSD`),
    /// USD. Threshold compared in USD.
    public static let todayCost = "today_cost"
    /// Total spend over the last 7 calendar days (rolling). USD.
    public static let weeklyCost = "weekly_cost"
    /// Total tokens today (input + output + cache_read).
    public static let todayTokens = "today_tokens"

    /// Rate-limit window utilization (0–100%). Unlike the cost/token metrics
    /// above, a `rateLimitPct` rule targets a specific window via
    /// `AlertRule.scopedWindow` and is evaluated against the latest
    /// `UsageLimitSample` for that scoped identity — the scoped-window
    /// equivalent of the fixed 5h/7d threshold alerts. Deliberately **not** in
    /// `all`: it isn't a user-pickable "custom rule" metric (the Notifications
    /// section auto-lists windows instead), and older builds silently skip it.
    public static let rateLimitPct = "rate_limit_pct"

    /// The user-pickable *custom* metrics (the Settings "Custom alerts" picker).
    /// `rateLimitPct` is intentionally excluded — scoped-window alerts are added
    /// per-window from the auto-listed rate-limit section, not here.
    public static let all: [String] = [todayCost, weeklyCost, todayTokens]

    /// Human-readable label for the Settings picker.
    public static func label(for metric: String) -> String {
        switch metric {
        case todayCost:    return "Today's cost (USD)"
        case weeklyCost:   return "Weekly cost (USD)"
        case todayTokens:  return "Today's tokens"
        case rateLimitPct: return "Rate-limit usage (%)"
        default:           return metric
        }
    }

    /// Formatter hint for the threshold input — `.currency` for cost
    /// metrics, `.number` for token counts.
    public static func isCurrency(_ metric: String) -> Bool {
        metric == todayCost || metric == weeklyCost
    }
}
