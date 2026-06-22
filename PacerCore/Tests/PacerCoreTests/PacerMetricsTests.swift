import Foundation
import Testing
@testable import PacerCore

@Suite("Pacer metrics (Prometheus)")
struct PacerMetricsTests {

    private func sampleSnapshot() -> PacerSnapshotPayload {
        let five = PacerSnapshotPayload.Limits.Window(
            usedPercent: 42, resetsAt: nil, resetsInSeconds: 7200,
            projectedEndPercent: 88, projectedEndLowPercent: 70, projectedEndHighPercent: 100,
            willHitLimit: false, limitEtaAt: nil, limitEtaInSeconds: nil)
        return PacerSnapshotPayload(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            limits: .init(fiveHour: five, sevenDay: nil),
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
}
