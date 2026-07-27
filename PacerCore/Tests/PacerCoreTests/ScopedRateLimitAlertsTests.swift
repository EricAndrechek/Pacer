import Foundation
import Testing
@testable import PacerCore

/// Coverage for the scoped per-model rate-limit alert policy: a scoped window
/// fires on threshold exactly like 5h/7d, stays dormant (never evaluated) when
/// its window is absent, and defaults to no alert until the user adds one.
struct ScopedRateLimitAlertsTests {

    private func rule(
        _ identity: String, _ pct: Double, enabled: Bool = true,
        metric: String = AlertRuleMetric.rateLimitPct
    ) -> AlertRule {
        AlertRule(name: identity, metric: metric, thresholdValue: pct,
                  scopedWindow: identity, enabled: enabled)
    }

    // MARK: - Default: no alert

    @Test func scopedWindowsDefaultToNoAlert() {
        // No rules at all ⇒ every window has an empty threshold set and nothing
        // is configured. This is the "each scoped window defaults to NO alert"
        // behavior.
        #expect(ScopedRateLimitAlerts.thresholds(forIdentity: "weekly_scoped|Fable|", in: []).isEmpty)
        #expect(ScopedRateLimitAlerts.configuredIdentities(in: []).isEmpty)
    }

    // MARK: - Fires on threshold

    @Test func firesOnUpwardCrossing() {
        let rules = [rule("weekly_scoped|Fable|", 75)]
        let thresholds = ScopedRateLimitAlerts.thresholds(forIdentity: "weekly_scoped|Fable|", in: rules)
        #expect(thresholds == [75])

        // 70% → 80% crosses 75 upward ⇒ fires.
        #expect(RateLimitThresholdPolicy.crossedThresholds(
            previous: 70, current: 80, thresholds: thresholds) == [75])
        // Cold start (nil previous) treated as 0 ⇒ an 80% first reading fires.
        #expect(RateLimitThresholdPolicy.crossedThresholds(
            previous: nil, current: 80, thresholds: thresholds) == [75])
        // Already above the line ⇒ no re-fire.
        #expect(RateLimitThresholdPolicy.crossedThresholds(
            previous: 80, current: 85, thresholds: thresholds).isEmpty)
        // Below the line ⇒ nothing.
        #expect(RateLimitThresholdPolicy.crossedThresholds(
            previous: 10, current: 40, thresholds: thresholds).isEmpty)
    }

    @Test func multipleThresholdsSortedDedupedAndClamped() {
        let rules = [
            rule("id|A|", 90),
            rule("id|A|", 50),
            rule("id|A|", 50),                 // duplicate ⇒ collapses
            rule("id|A|", 150),                // out of range ⇒ dropped
            rule("id|A|", 60, enabled: false), // disabled ⇒ excluded
        ]
        #expect(ScopedRateLimitAlerts.thresholds(forIdentity: "id|A|", in: rules) == [50, 90])

        // One sample crossing several lines fires them ascending.
        #expect(RateLimitThresholdPolicy.crossedThresholds(
            previous: 40, current: 95, thresholds: [50, 90]) == [50, 90])
    }

    @Test func onlyRateLimitRulesForThisIdentityCount() {
        let rules = [
            rule("id|A|", 75),
            rule("id|B|", 80),                                   // other window
            rule("id|A|", 30, metric: AlertRuleMetric.weeklyCost), // cost rule, not rate-limit
        ]
        #expect(ScopedRateLimitAlerts.thresholds(forIdentity: "id|A|", in: rules) == [75])
    }

    // MARK: - Dormant when absent

    @Test func dormantWhenWindowAbsent() {
        let rules = [rule("weekly_scoped|Fable|", 75)]
        // Fable configured, but the current poll only has Opus ⇒ Fable dormant.
        let dormant = ScopedRateLimitAlerts.dormantIdentities(
            in: rules, present: ["weekly_scoped|Opus|"])
        #expect(dormant == ["weekly_scoped|Fable|"])

        // The window reappears ⇒ no longer dormant (reactivates).
        let live = ScopedRateLimitAlerts.dormantIdentities(
            in: rules, present: ["weekly_scoped|Fable|", "weekly_scoped|Opus|"])
        #expect(live.isEmpty)
    }

    @Test func configuredKeepsDisabledAndDormantRules() {
        // A window whose only rule is disabled is still "configured" (kept, not
        // deleted) so it stays visible/dormant rather than vanishing.
        let rules = [rule("id|A|", 75, enabled: false)]
        #expect(ScopedRateLimitAlerts.configuredIdentities(in: rules) == ["id|A|"])
        // But it contributes no fireable thresholds while disabled.
        #expect(ScopedRateLimitAlerts.thresholds(forIdentity: "id|A|", in: rules).isEmpty)
    }

    // MARK: - Scoped-vs-account-wide classification

    @Test func onlyModelOrSurfaceRowsAreScoped() {
        let accountWide = UsageLimitSample(
            sampledAt: Date(), identity: "weekly_all||", kind: "weekly_all", group: "weekly",
            label: "All models", percent: 71, resetsAt: nil, severity: "normal",
            isActive: false, modelId: nil, modelDisplayName: nil, surface: nil, source: "oauth")
        #expect(ScopedRateLimitAlerts.isModelOrSurfaceScoped(accountWide) == false)

        let perModel = UsageLimitSample(
            sampledAt: Date(), identity: "weekly_scoped|Fable|", kind: "weekly_scoped", group: "weekly",
            label: "Fable", percent: 49, resetsAt: nil, severity: "normal",
            isActive: false, modelId: nil, modelDisplayName: "Fable", surface: nil, source: "oauth")
        #expect(ScopedRateLimitAlerts.isModelOrSurfaceScoped(perModel) == true)
    }
}
