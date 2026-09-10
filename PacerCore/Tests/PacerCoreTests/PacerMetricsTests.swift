import Foundation
import Testing
@testable import PacerCore

@Suite("Pacer metrics (Prometheus)")
struct PacerMetricsTests {

    private func window(identity: String, label: String, group: String,
                        percent: Double, resetsInSeconds: Int? = nil,
                        projectedEnd: Double? = nil,
                        willHit: Bool = false, etaSeconds: Int? = nil)
        -> PacerSnapshotPayload.Limits.Window {
        PacerSnapshotPayload.Limits.Window(
            identity: identity, label: label, group: group,
            usedPercent: percent, resetsAt: nil, resetsInSeconds: resetsInSeconds,
            projectedEndPercent: projectedEnd, projectedEndLowPercent: nil,
            projectedEndHighPercent: nil, willHitLimit: willHit,
            limitEtaAt: nil, limitEtaInSeconds: etaSeconds)
    }

    private func sampleSnapshot(limits: PacerSnapshotPayload.Limits? = nil) -> PacerSnapshotPayload {
        let five = window(identity: "five_hour", label: "5-hour", group: "session",
                          percent: 42, resetsInSeconds: 7200, projectedEnd: 88)
        return PacerSnapshotPayload(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            limits: limits ?? .init(fiveHour: five, sevenDay: nil),
            cost: .init(todayUSD: 3.21, weekUSD: 18.4, monthUSD: 64.1, allTimeUSD: 512.33,
                        projectedTodayUSD: 5.1, projectedTodayLowUSD: 4, projectedTodayHighUSD: 7.2,
                        projectedMonthUSD: nil, projectedMonthLowUSD: nil, projectedMonthHighUSD: nil),
            tokens: .init(todayInput: 100, todayOutput: 200, todayCacheRead: 300, todayTotal: 300),
            pace: .init(percentile: 0.82, status: "running hot"),
            session: nil,
            overageUSD: 0,
            dataSource: .init(source: "oauth", lastSampleAt: nil, ageSeconds: 35, forecastFresh: true))
    }

    @Test func rendersExpositionFormat() {
        let text = PacerMetrics(snapshot: sampleSnapshot(), version: "1.2.3", build: "42").prometheusText()

        // Ratio conversion + integral formatting (no trailing ".0").
        #expect(text.contains("pacer_rate_limit_used_ratio{window=\"five_hour\"} 0.42"))
        #expect(text.contains("pacer_rate_limit_reset_seconds{window=\"five_hour\"} 7200"))
        #expect(text.contains("pacer_rate_limit_will_hit{window=\"five_hour\"} 0"))
        // Cost family with period labels.
        #expect(text.contains("pacer_cost_usd{period=\"today\"} 3.21"))
        #expect(text.contains("pacer_cost_usd{period=\"all_time\"} 512.33"))
        // Pace, tokens, build info.
        #expect(text.contains("pacer_pace_ratio 0.82"))
        #expect(text.contains("pacer_tokens{kind=\"input\"} 100"))
        #expect(text.contains("pacer_build_info{version=\"1.2.3\",build=\"42\"} 1"))
        // HELP/TYPE present.
        #expect(text.contains("# TYPE pacer_cost_usd gauge"))
        #expect(text.contains("# HELP pacer_up "))
    }

    @Test func omitsAbsentSeries() {
        let text = PacerMetrics(snapshot: sampleSnapshot(), version: "1.0", build: "1").prometheusText()
        // seven_day window was nil → no series for it.
        #expect(!text.contains("window=\"seven_day\""))
        // projected month was nil → only the today projection appears.
        #expect(text.contains("pacer_cost_projected_usd{period=\"today\"} 5.1"))
        #expect(!text.contains("pacer_cost_projected_usd{period=\"month\"}"))
    }

    @Test func emitsTypeOncePerFamily() {
        let text = PacerMetrics(snapshot: sampleSnapshot(), version: "1.0", build: "1").prometheusText()
        // pacer_cost_usd has four series but exactly one HELP and one TYPE line.
        let typeCount = text.components(separatedBy: "# TYPE pacer_cost_usd ").count - 1
        let helpCount = text.components(separatedBy: "# HELP pacer_cost_usd ").count - 1
        #expect(typeCount == 1)
        #expect(helpCount == 1)
    }

    // MARK: - Every window, not two

    /// The gap this closed: the engine has driven N dynamic windows since
    /// v0.4.0 and the dashboard charts a "Fable · weekly" cap, but `window=`
    /// was one of two hard-coded words, so a scrape could not see it at all.
    @Test func scopedWindowsGetTheirOwnSeriesKeyedByIdentity() {
        let limits = PacerSnapshotPayload.Limits(
            fiveHour: window(identity: "five_hour", label: "5-hour", group: "session", percent: 66),
            sevenDay: window(identity: "seven_day", label: "7-day", group: "weekly", percent: 21),
            scoped: [window(identity: "weekly_scoped|Fable|", label: "Fable", group: "weekly",
                            percent: 16, resetsInSeconds: 3600)])
        let text = PacerMetrics(snapshot: sampleSnapshot(limits: limits),
                                version: "1.0", build: "1").prometheusText()

        #expect(text.contains("pacer_rate_limit_used_ratio{window=\"five_hour\"} 0.66"))
        #expect(text.contains("pacer_rate_limit_used_ratio{window=\"seven_day\"} 0.21"))
        #expect(text.contains("pacer_rate_limit_used_ratio{window=\"weekly_scoped|Fable|\"} 0.16"))
        #expect(text.contains("pacer_rate_limit_reset_seconds{window=\"weekly_scoped|Fable|\"} 3600"))
        // One family, one HELP/TYPE pair, three series.
        #expect(text.components(separatedBy: "# TYPE pacer_rate_limit_used_ratio ").count - 1 == 1)
    }

    /// A window whose identity contains a `"` or `\` (the composite key is
    /// built from server strings, which are an open set) must not break out of
    /// the label value.
    @Test func windowIdentityIsEscapedIntoTheLabelValue() {
        let limits = PacerSnapshotPayload.Limits(
            fiveHour: nil, sevenDay: nil,
            scoped: [window(identity: "weekly_scoped|say \"hi\"|", label: "x", group: "weekly", percent: 5)])
        let text = PacerMetrics(snapshot: sampleSnapshot(limits: limits),
                                version: "1.0", build: "1").prometheusText()
        #expect(text.contains("{window=\"weekly_scoped|say \\\"hi\\\"|\"} 0.05"))
    }

    // MARK: - Per-account limits

    @Test func perAccountLimitsLabelEverySeriesWithItsLogin() {
        let work = PacerMetrics.AccountLimits(
            accountId: "org-work",
            limits: .init(fiveHour: window(identity: "five_hour", label: "5-hour",
                                           group: "session", percent: 37),
                          sevenDay: nil,
                          scoped: [window(identity: "weekly_scoped|Fable|", label: "Fable",
                                          group: "weekly", percent: 16)]))
        let home = PacerMetrics.AccountLimits(
            accountId: "org-home",
            limits: .init(fiveHour: nil, sevenDay: nil,
                          scoped: [window(identity: "weekly_scoped|Fable|", label: "Fable",
                                          group: "weekly", percent: 0)]))
        let text = PacerMetrics(snapshot: sampleSnapshot(), limits: [work, home],
                                version: "1.0", build: "1").prometheusText()

        #expect(text.contains("pacer_rate_limit_used_ratio{account=\"org-work\",window=\"five_hour\"} 0.37"))
        #expect(text.contains("pacer_rate_limit_used_ratio{account=\"org-work\",window=\"weekly_scoped|Fable|\"} 0.16"))
        #expect(text.contains("pacer_rate_limit_used_ratio{account=\"org-home\",window=\"weekly_scoped|Fable|\"} 0"))
        // The same window for two logins is two series, not one overwriting
        // the other — which is the whole reason the label exists.
        #expect(text.components(separatedBy: "window=\"weekly_scoped|Fable|\"").count - 1 >= 2)
    }

    /// The snapshot's own limits are ignored once per-account sets are passed:
    /// the active login is one of them, and emitting both would publish its
    /// windows twice — once labelled, once not.
    @Test func perAccountLimitsReplaceTheUnlabelledSeries() {
        let work = PacerMetrics.AccountLimits(
            accountId: "org-work",
            limits: .init(fiveHour: window(identity: "five_hour", label: "5-hour",
                                           group: "session", percent: 37),
                          sevenDay: nil))
        let text = PacerMetrics(snapshot: sampleSnapshot(), limits: [work],
                                version: "1.0", build: "1").prometheusText()
        #expect(!text.contains("pacer_rate_limit_used_ratio{window=\"five_hour\"}"))
        #expect(text.contains("pacer_rate_limit_used_ratio{account=\"org-work\",window=\"five_hour\"} 0.37"))
    }

    /// Before the first poll there are no `Account` rows to label with, and a
    /// scrape must still report the windows it has.
    @Test func noAccountsFallsBackToUnlabelledSeries() {
        let text = PacerMetrics(snapshot: sampleSnapshot(), limits: [],
                                version: "1.0", build: "1").prometheusText()
        #expect(text.contains("pacer_rate_limit_used_ratio{window=\"five_hour\"} 0.42"))
        #expect(!text.contains("account="))
    }
}
