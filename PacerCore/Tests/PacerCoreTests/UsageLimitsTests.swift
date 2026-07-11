import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// Tests for the adaptive `limits[]` support: the tolerant parser, the
/// stable composite identity, the severity/percent color blend, generic
/// persistence, and the "latest batch" (disappearing-limit) semantics.
///
/// The through-line is *adaptivity*: none of these tests hard-code the
/// current model list, kinds, groups, or severities — they assert that a
/// brand-new one flows through unchanged and a removed one drops out.
@Suite struct UsageLimitsTests {

    // The live-captured sample from the ground-truth brief.
    private static let realSample = #"""
    [
      { "kind": "session",       "group": "session", "percent": 39, "severity": "normal",
        "resets_at": "2026-07-11T14:19:59+00:00", "scope": null, "is_active": false },
      { "kind": "weekly_all",    "group": "weekly",  "percent": 71, "severity": "normal",
        "resets_at": "2026-07-13T09:59:59+00:00", "scope": null, "is_active": true },
      { "kind": "weekly_scoped", "group": "weekly",  "percent": 49, "severity": "normal",
        "resets_at": "2026-07-13T09:59:59+00:00",
        "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null }, "is_active": false }
    ]
    """#

    private func parse(_ json: String) -> [UsageLimit] {
        let raw = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        return UsageLimit.parse(raw)
    }

    // MARK: - Real sample

    @Test func parsesRealSample() {
        let limits = parse(Self.realSample)
        #expect(limits.count == 3)

        let session = limits[0]
        #expect(session.kind == "session")
        #expect(session.group == "session")
        #expect(session.percent == 39)
        #expect(session.isActive == false)
        #expect(session.scope == nil)            // account-wide
        #expect(session.resetsAt != nil)
        #expect(session.label == "All models")

        let weeklyAll = limits[1]
        #expect(weeklyAll.kind == "weekly_all")
        #expect(weeklyAll.group == "weekly")
        #expect(weeklyAll.isActive == true)      // the binding limit
        #expect(weeklyAll.scope == nil)

        let scoped = limits[2]
        #expect(scoped.kind == "weekly_scoped")
        #expect(scoped.group == "weekly")
        #expect(scoped.percent == 49)
        #expect(scoped.scope?.model?.displayName == "Fable")
        #expect(scoped.scope?.model?.id == nil)
        #expect(scoped.label == "Fable")         // scoped row reads as its model
    }

    @Test func realSampleThroughOAuthDecode() async {
        // End-to-end: the full endpoint body (top-level windows + limits[])
        // decodes into a snapshot carrying the parsed limits.
        let body = """
        {
          "five_hour": {"utilization": 39, "resets_at": "2026-07-11T14:19:59Z"},
          "seven_day": {"utilization": 71, "resets_at": "2026-07-13T09:59:59Z"},
          "limits": \(Self.realSample)
        }
        """
        let snap = try! OAuthClientTestSupport.decode(body: body)
        #expect(snap.limits.count == 3)
        #expect(snap.limits.contains { $0.label == "Fable" })
        // Superset check from the brief: session≈five_hour, weekly_all≈seven_day.
        #expect(snap.fiveHour?.usedPercentage == 39)
        #expect(snap.limits.first { $0.kind == "session" }?.percent == 39)
    }

    // MARK: - New / unknown kind + model (renders + persists generically)

    @Test func unknownKindAndModelFlowThrough() {
        // A kind, group, model, and surface Pacer has NEVER seen. Nothing
        // is hard-coded, so they parse into a fully-formed limit.
        let json = #"""
        [
          { "kind": "monthly_scoped", "group": "monthly", "percent": 12, "severity": "normal",
            "resets_at": "2026-08-01T00:00:00Z",
            "scope": { "model": { "id": "mdl_neptune", "display_name": "Neptune" }, "surface": "api" },
            "is_active": false }
        ]
        """#
        let limits = parse(json)
        #expect(limits.count == 1)
        let l = limits[0]
        #expect(l.kind == "monthly_scoped")
        #expect(l.group == "monthly")            // brand-new group buckets fine
        #expect(l.scope?.model?.id == "mdl_neptune")
        #expect(l.scope?.surface == "api")
        // Identity prefers model id and folds in the surface axis.
        #expect(l.identity == "monthly_scoped|mdl_neptune|api")
        // Label carries the surface so a per-surface split stays legible.
        #expect(l.label == "Neptune · api")
    }

    @Test func identityPrefersModelIdThenDisplayName() {
        let withId = UsageLimit(
            kind: "weekly_scoped", group: "weekly", percent: 10,
            severity: UsageLimitSeverity("normal"), resetsAt: nil,
            scope: UsageLimitScope(model: .init(id: "mdl_x", displayName: "X"), surface: nil),
            isActive: false
        )
        #expect(withId.identity == "weekly_scoped|mdl_x|")

        let nameOnly = UsageLimit(
            kind: "weekly_scoped", group: "weekly", percent: 10,
            severity: UsageLimitSeverity("normal"), resetsAt: nil,
            scope: UsageLimitScope(model: .init(id: nil, displayName: "Fable"), surface: nil),
            isActive: false
        )
        #expect(nameOnly.identity == "weekly_scoped|Fable|")

        let accountWide = UsageLimit(
            kind: "session", group: "session", percent: 10,
            severity: UsageLimitSeverity("normal"), resetsAt: nil,
            scope: nil, isActive: false
        )
        #expect(accountWide.identity == "session||")
    }

    // MARK: - Unknown severity → safe default

    @Test func unknownSeverityIsSafeDefault() {
        // A severity word we've never seen must not crash, hide, or false-
        // alarm: it contributes NO escalation floor, so a calm percent stays
        // green.
        let calm = UsageLimit(
            kind: "session", group: "session", percent: 20,
            severity: UsageLimitSeverity("chartreuse"), resetsAt: nil,
            scope: nil, isActive: false
        )
        #expect(calm.severity.floor == .green)
        #expect(calm.severity.isElevated == false)
        #expect(calm.displayBand == .green)
    }

    @Test func percentStillEscalatesUnderNormalSeverity() {
        // Severity may say "normal" while the window is nearly exhausted —
        // percent must still drive the color to red.
        let hot = UsageLimit(
            kind: "weekly_all", group: "weekly", percent: 96,
            severity: UsageLimitSeverity("normal"), resetsAt: nil,
            scope: nil, isActive: true
        )
        #expect(hot.displayBand == .red)
    }

    @Test func knownElevatedSeverityRaisesFloor() {
        // A low percent but a "warning"/"critical" severity escalates.
        let warned = UsageLimit(
            kind: "session", group: "session", percent: 5,
            severity: UsageLimitSeverity("warning"), resetsAt: nil,
            scope: nil, isActive: false
        )
        #expect(warned.displayBand == .orange)

        let crit = UsageLimit(
            kind: "session", group: "session", percent: 5,
            severity: UsageLimitSeverity("critical"), resetsAt: nil,
            scope: nil, isActive: false
        )
        #expect(crit.displayBand == .red)
        #expect(crit.severity.isElevated == true)
    }

    // MARK: - Null / absent tolerance

    @Test func toleratesNullScopeAndResetsAt() {
        let json = #"""
        [
          { "kind": "session", "group": "session", "percent": 8, "severity": "normal",
            "resets_at": null, "scope": null, "is_active": false }
        ]
        """#
        let limits = parse(json)
        #expect(limits.count == 1)
        #expect(limits[0].resetsAt == nil)
        #expect(limits[0].scope == nil)
        #expect(limits[0].label == "All models")
    }

    @Test func toleratesMissingFieldsAndDropsUnparseableItems() {
        // Item 1: missing group → falls back to kind; missing severity →
        // normal; missing is_active → false. Item 2: no numeric percent →
        // dropped (nothing to draw) without failing the batch.
        let json = #"""
        [
          { "kind": "session", "percent": 30 },
          { "kind": "broken", "group": "weekly", "percent": "lots" }
        ]
        """#
        let limits = parse(json)
        #expect(limits.count == 1)
        #expect(limits[0].kind == "session")
        #expect(limits[0].group == "session")     // fell back to kind
        #expect(limits[0].severity.floor == .green)
        #expect(limits[0].isActive == false)
    }

    @Test func nonArrayInputYieldsEmpty() {
        #expect(UsageLimit.parse(nil).isEmpty)
        #expect(UsageLimit.parse("not an array").isEmpty)
        #expect(UsageLimit.parse(["kind": "session"]).isEmpty)   // dict, not array
    }

    @Test func integerAndDoublePercentBothParse() {
        #expect(parse(#"[{"kind":"a","group":"a","percent":50}]"#)[0].percent == 50)
        #expect(parse(#"[{"kind":"a","group":"a","percent":49.5}]"#)[0].percent == 49.5)
    }

    // MARK: - Persistence (generic columns) + disappearing limit

    @MainActor
    @Test func usageLimitSampleRoundTrips() throws {
        let container = try ModelContainer(
            for: UsageLimitSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let limits = parse(Self.realSample)
        let sampledAt = Date(timeIntervalSince1970: 1_752_000_000)
        for l in limits {
            context.insert(UsageLimitSample(from: l, sampledAt: sampledAt, source: "oauth"))
        }
        try context.save()

        let rows = try context.fetch(FetchDescriptor<UsageLimitSample>())
        #expect(rows.count == 3)
        let fable = rows.first { $0.modelDisplayName == "Fable" }
        #expect(fable != nil)
        #expect(fable?.kind == "weekly_scoped")
        #expect(fable?.identity == "weekly_scoped|Fable|")
        #expect(fable?.label == "Fable")
        // Persisted row colors identically to the live value.
        #expect(fable?.displayBand == UsageBand(percentage: 49))
    }

    @MainActor
    @Test func latestBatchDropsDisappearedLimit() throws {
        // Poll 1 carries 3 limits; poll 2 (later) carries only 2 — the
        // per-model "Fable" window vanished. `latestBatch` must reflect the
        // latest poll only, so the removed limit disappears with no code
        // change.
        let container = try ModelContainer(
            for: UsageLimitSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let t0 = Date(timeIntervalSince1970: 1_752_000_000)
        for l in parse(Self.realSample) {
            context.insert(UsageLimitSample(from: l, sampledAt: t0, source: "oauth"))
        }
        let t1 = t0.addingTimeInterval(300)
        let shrunk = #"""
        [
          { "kind": "session",    "group": "session", "percent": 41, "severity": "normal",
            "resets_at": null, "scope": null, "is_active": false },
          { "kind": "weekly_all", "group": "weekly",  "percent": 73, "severity": "normal",
            "resets_at": null, "scope": null, "is_active": true }
        ]
        """#
        for l in parse(shrunk) {
            context.insert(UsageLimitSample(from: l, sampledAt: t1, source: "oauth"))
        }
        try context.save()

        let all = try context.fetch(FetchDescriptor<UsageLimitSample>())
        #expect(all.count == 5)                    // full history retained

        let latest = all.latestBatch()
        #expect(latest.count == 2)                 // only the latest poll
        #expect(latest.allSatisfy { $0.sampledAt == t1 })
        #expect(latest.contains { $0.kind == "weekly_all" })
        #expect(!latest.contains { $0.modelDisplayName == "Fable" })  // gone
        // Binding limit sorts first.
        #expect(latest.first?.isActive == true)
    }

    @MainActor
    @Test func latestBatchEmptyWhenNoRows() throws {
        let empty: [UsageLimitSample] = []
        #expect(empty.latestBatch().isEmpty)
    }
}

/// Test hook onto `OAuthClient`'s private decode so a raw endpoint body can
/// be exercised without a keychain/transport round-trip.
enum OAuthClientTestSupport {
    static func decode(body: String) throws -> RateLimitSnapshot {
        try OAuthClient.decodeForTesting(body: Data(body.utf8), sampledAt: Date())
    }
}
