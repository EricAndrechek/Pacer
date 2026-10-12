import Foundation
import SwiftData
import Testing
@testable import PacerCore
@testable import PacerPace

@Suite("pace: reading /metrics")
struct PaceMetricsTextTests {

    @Test("names, labels and values; comments and junk skipped")
    func parsesTheExposition() {
        let points = PaceMetricsText.parse("""
        # HELP pacer_up 1 when serving.
        # TYPE pacer_up gauge
        pacer_up 1

        pacer_rate_limit_used_ratio{account="org-work",window="weekly_scoped|Fable|"} 0.95
        pacer_account_info{account="a",name="Acme \\"Labs\\"",note="two\\nlines",path="C:\\\\x"} 1
        not a metric line {
        pacer_rate_limit_reset_seconds{account="org-work",window="five_hour"} -5
        """)
        #expect(points.map(\.name) == ["pacer_up", "pacer_rate_limit_used_ratio",
                                       "pacer_account_info", "pacer_rate_limit_reset_seconds"])
        #expect(points[1].label("window") == "weekly_scoped|Fable|")
        #expect(points[1].raw == "0.95")
        #expect(points[2].label("name") == "Acme \"Labs\"")
        #expect(points[2].label("note") == "two\nlines")
        #expect(points[2].label("path") == "C:\\x")
        #expect(points[3].value == -5)
    }

    /// The store source (PR 2) feeds `PacerMetrics.points` straight in, while
    /// the API source parses their text. Both must give the same points, so a
    /// gate cannot depend on which one answered.
    @MainActor
    @Test("what Pacer renders parses back to the points it rendered")
    func roundTrip() throws {
        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (id, five, seven, active) in [("org-work", 37.5, 21.0, true), ("org-home", 2.25, 5.0, false)] {
            context.insert(Account(id: id, organizationId: id, displayName: "Acme \(id)",
                                   isActive: active, firstSeenAt: .distantPast, lastSeenAt: now))
            context.insert(RateLimitSample(
                sampledAt: now.addingTimeInterval(-60), window: RateLimitWindowName.fiveHour,
                usedPercentage: five, resetsAt: now.addingTimeInterval(3_600),
                source: RateLimitSource.oauth, accountId: id))
            context.insert(RateLimitSample(
                sampledAt: now.addingTimeInterval(-60), window: RateLimitWindowName.sevenDay,
                usedPercentage: seven, resetsAt: now.addingTimeInterval(90_000),
                source: RateLimitSource.oauth, accountId: id))
        }
        context.insert(AccountActivation(accountId: "org-work", startedAt: .distantPast,
                                         source: AccountActivation.sourceObserved))
        try context.save()

        let snapshot = try PacerAPISnapshot.build(container: container, activeAccountId: "org-work", now: now)
        let metrics = snapshot.metrics(account: nil, now: now, version: "1.0", build: "1")
        // The text groups samples by family, in the order each family first
        // appears; the points interleave them. Same samples, that order.
        var families: [String] = []
        for p in metrics.points where !families.contains(p.name) { families.append(p.name) }
        let structured = families.flatMap { name in
            metrics.points.filter { $0.name == name }.map(PaceMetricPoint.init)
        }
        let parsed = PaceMetricsText.parse(metrics.prometheusText())
        #expect(parsed == structured)
        #expect(parsed.contains { $0.name == "pacer_rate_limit_used_ratio" && $0.label("account") == "org-home" })

        // And the rows a gate reads come out the same either way.
        #expect(PaceRun.rows(from: parsed, want: "") == PaceRun.rows(from: structured, want: ""))
        #expect(!PaceRun.rows(from: parsed, want: "").isEmpty)
    }
}
