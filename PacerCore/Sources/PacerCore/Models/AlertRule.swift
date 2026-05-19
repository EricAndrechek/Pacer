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

    public init(
        id: String = UUID().uuidString,
        name: String,
        metric: String,
        thresholdValue: Double,
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.metric = metric
        self.thresholdValue = thresholdValue
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

    public static let all: [String] = [todayCost, weeklyCost, todayTokens]

    /// Human-readable label for the Settings picker.
    public static func label(for metric: String) -> String {
        switch metric {
        case todayCost:   return "Today's cost (USD)"
        case weeklyCost:  return "Weekly cost (USD)"
        case todayTokens: return "Today's tokens"
        default:          return metric
        }
    }

    /// Formatter hint for the threshold input — `.currency` for cost
    /// metrics, `.number` for token counts.
    public static func isCurrency(_ metric: String) -> Bool {
        metric == todayCost || metric == weeklyCost
    }
}
