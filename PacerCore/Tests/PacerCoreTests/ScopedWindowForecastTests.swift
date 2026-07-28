import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// Scoped per-model windows (from `limits[]`, e.g. a "Fable" weekly cap) are
/// first-class forecast items driven through the SAME generic window path as
/// the fixed 5h/7d blocks. These tests cover: the scoped-only filter (account-
/// wide rows aren't double-forecast), duration from the group hint, cold-start
/// point-only bands, selection/isolation from the fixed windows, and the
/// staleness guard (a vanished limit goes quiet).
@Suite("Scoped window forecasts")
struct ScopedWindowForecastTests {

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    static let now = utc.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 20, minute: 30))!

    /// Deterministic ramp `ScopedRow`s for one scoped identity over `completed`
    /// prior cycles plus a live one. `inLatestBatch` is stamped on the newest
    /// poll's rows (mirroring `fetchScopedLimits`).
    static func scopedRows(
        identity: String, group: String, label: String,
        modelId: String?, modelDisplayName: String?, surface: String?,
        duration: TimeInterval, completed: Int, stepH: Double, peak: Double, perStep: Double,
        present: Bool = true
    ) -> [EngineFeatures.ScopedRow] {
        var out: [(at: Date, pct: Double)] = []
        for c in 0...completed {
            let cycleStart = now.addingTimeInterval(-Double(completed - c) * duration - duration * 0.5)
            let resetsAt = cycleStart.addingTimeInterval(duration)
            var t = cycleStart
            var pct = 0.0
            while t <= min(resetsAt, now) {
                out.append((t, min(peak, pct)))
                t = t.addingTimeInterval(stepH * 3600)
                pct += perStep
            }
        }
        let newest = out.map(\.at).max() ?? now
        return out.map { row in
            EngineFeatures.ScopedRow(
                identity: identity, group: group, label: label,
                modelId: modelId, modelDisplayName: modelDisplayName, surface: surface,
                at: row.at, usedPercentage: row.pct,
                resetsAt: cycleResets(for: row.at, duration: duration),
                inLatestBatch: present && row.at >= newest.addingTimeInterval(-2),
                isActive: false)
        }
    }

    /// The reset time of the cycle a sample at `at` belongs to, matching the
    /// ramp layout in `scopedRows`.
    static func cycleResets(for at: Date, duration: TimeInterval) -> Date {
        // Cycles start at now - k*duration - 0.5*duration; find which cycle `at`
        // falls in by walking back from a generous horizon.
        var cycleStart = now.addingTimeInterval(-20 * duration - duration * 0.5)
        while cycleStart.addingTimeInterval(duration) < at { cycleStart = cycleStart.addingTimeInterval(duration) }
        return cycleStart.addingTimeInterval(duration)
    }

    static func fableIdentity() -> String { "weekly_scoped|Fable|" }

    /// Scoped **session** (5h) rows for one identity: `completed` moderate cycles
    /// (peak ~60) plus a steep live cycle at ~75% climbing ~25pp/hr → the engine
    /// projects a 100% crossing ~1h out, well before the reset ~2.5h out. Mirrors
    /// `EngineSelfEvalTests.steepFiveHourFeatures` but on a scoped per-model
    /// identity, so it exercises `burnOutlook(windowKey:)` for the burn warning.
    static func onPaceSessionRows(identity: String, completed: Int) -> [EngineFeatures.ScopedRow] {
        let duration: TimeInterval = 5 * 3600
        var raw: [(at: Date, pct: Double, reset: Date)] = []
        for c in 0..<completed {
            let start = now.addingTimeInterval(-Double(completed + 1 - c) * duration)
            let reset = start.addingTimeInterval(duration)
            var pct = 0.0, t = start
            while t <= reset {
                raw.append((t, min(60, pct), reset))
                t = t.addingTimeInterval(15 * 60); pct += 2
            }
        }
        // Steep live cycle: started 2.5h ago, 75%+ and climbing ~25pp/hr.
        let liveStart = now.addingTimeInterval(-2.5 * 3600)
        let liveReset = liveStart.addingTimeInterval(duration)
        var pct = 0.0, t = liveStart
        while t <= now {
            raw.append((t, min(100, pct), liveReset))
            t = t.addingTimeInterval(15 * 60); pct += 25.0 / 4
        }
        let newest = raw.map(\.at).max() ?? now
        return raw.map { row in
            EngineFeatures.ScopedRow(
                identity: identity, group: "session", label: "Fable",
                modelId: nil, modelDisplayName: "Fable", surface: nil,
                at: row.at, usedPercentage: row.pct, resetsAt: row.reset,
                inLatestBatch: row.at >= newest.addingTimeInterval(-2), isActive: false)
        }
    }

    // MARK: - Duration hint (Decision B)

    @Test func scopedDurationFromGroupHint() {
        #expect(WindowSpec.scopedDuration(group: "session") == 5 * 3600)
        #expect(WindowSpec.scopedDuration(group: "weekly") == 7 * 24 * 3600)
        #expect(WindowSpec.scopedDuration(group: "Weekly") == 7 * 24 * 3600)   // case-insensitive
        // Unknown group with no spacing → 7d default.
        #expect(WindowSpec.scopedDuration(group: "mystery") == 7 * 24 * 3600)
        // Unknown group falls back to the median observed reset spacing.
        let day: TimeInterval = 86400
        #expect(WindowSpec.scopedDuration(group: "mystery", resetSpacings: [day, day, 2 * day]) == day)
    }

    // MARK: - Scoped-only filter (Decision C)

    @Test func accountWideRowsAreNotForecastAsScoped() {
        // A `session`/`weekly_all` row carries no model or surface — it must NOT
        // become a scoped window (the fixed 5h/7d hero windows already own it).
        let rows = Self.scopedRows(
            identity: "weekly_all||", group: "weekly", label: "All models",
            modelId: nil, modelDisplayName: nil, surface: nil,
            duration: 7 * 86400, completed: 3, stepH: 12, peak: 50, perStep: 2)
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [],
                                     rate: [], lastArrivalAt: nil, scoped: rows)
        #expect(f.windows.filter { $0.isScoped }.isEmpty)
    }

    @Test func modelScopedRowsBecomeAScopedWindow() {
        let rows = Self.scopedRows(
            identity: Self.fableIdentity(), group: "weekly", label: "Fable",
            modelId: nil, modelDisplayName: "Fable", surface: nil,
            duration: 7 * 86400, completed: 5, stepH: 8, peak: 58, perStep: 2.0)
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [],
                                     rate: [], lastArrivalAt: nil, scoped: rows)
        let scoped = f.windows.filter { $0.isScoped }
        #expect(scoped.count == 1)
        let spec = scoped.first
        #expect(spec?.key == Self.fableIdentity())
        #expect((spec?.duration ?? 0) == TimeInterval(7 * 24 * 3600))   // weekly hint
        #expect(spec?.displayName == "Fable")

        // It gets its own fit + a real end-at-reset outlook, keyed by identity.
        let fit = UsageIntelligenceEngine.makeFit(f)
        #expect(fit.rl[Self.fableIdentity()] != nil)
        let est = UsageIntelligenceEngine.answer(.scopedOutlook(Self.fableIdentity()), features: f, fit: fit)
        #expect(!est.isInsufficient)
        #expect(est.value >= 0 && est.value <= 100)
        #expect(est.method.hasPrefix("rl-"))
    }

    // MARK: - Isolation from the fixed windows (no regression)

    @Test func scopedWindowsDoNotPerturbTheFixedWindows() {
        // Fixed 7d rows.
        var rate: [EngineFeatures.RateRow] = []
        let d7: TimeInterval = 7 * 86400
        for c in 0..<4 {
            let cycleStart = Self.now.addingTimeInterval(-Double(3 - c) * d7 - 2 * 86400)
            let resetsAt = cycleStart.addingTimeInterval(d7)
            var t = cycleStart; var pct = 0.0
            while t <= min(resetsAt, Self.now) {
                rate.append(.init(window: "seven_day", at: t, usedPercentage: min(60, pct), resetsAt: resetsAt))
                t = t.addingTimeInterval(6 * 3600); pct += 2.2
            }
        }
        let scoped = Self.scopedRows(
            identity: Self.fableIdentity(), group: "weekly", label: "Fable",
            modelId: nil, modelDisplayName: "Fable", surface: nil,
            duration: d7, completed: 5, stepH: 8, peak: 58, perStep: 2.0)

        let without = UsageIntelligenceEngine.makeFit(
            EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [], rate: rate, lastArrivalAt: nil))
        let with = UsageIntelligenceEngine.makeFit(
            EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [], rate: rate, lastArrivalAt: nil, scoped: scoped))

        let a = without.rl["seven_day"]
        let b = with.rl["seven_day"]
        #expect(a != nil && b != nil)
        #expect(a?.selectedId == b?.selectedId)
        #expect(a?.duration == b?.duration)
        #expect(a?.historyCount == b?.historyCount)
        #expect(a?.cyclesObserved == b?.cyclesObserved)
        #expect(a?.calibrators["pooled"]?.count == b?.calibrators["pooled"]?.count)
        // And the fixed window's Estimate is identical with or without scoped.
        let fWithout = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [], rate: rate, lastArrivalAt: nil)
        let fWith = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [], rate: rate, lastArrivalAt: nil, scoped: scoped)
        let eWithout = UsageIntelligenceEngine.answer(.rateLimitOutlook(.sevenDay), features: fWithout, fit: without)
        let eWith = UsageIntelligenceEngine.answer(.rateLimitOutlook(.sevenDay), features: fWith, fit: with)
        #expect(eWithout.value == eWith.value)
        #expect(eWithout.interval80 == eWith.interval80)
    }

    // MARK: - Cold start: point-only, no saturated band (Decision: band gate)

    @Test func scopedColdStartShowsNoSaturatedBand() {
        // One live cycle, zero completed cycles → the residual gate must decline
        // a band (fewer than conformalMinResiduals), so the surface shows the
        // point alone rather than a "5 min – 32 hr" range.
        let rows = Self.scopedRows(
            identity: Self.fableIdentity(), group: "weekly", label: "Fable",
            modelId: nil, modelDisplayName: "Fable", surface: nil,
            duration: 7 * 86400, completed: 0, stepH: 8, peak: 40, perStep: 3)
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [],
                                     rate: [], lastArrivalAt: nil, scoped: rows)
        let fit = UsageIntelligenceEngine.makeFit(f)
        let est = UsageIntelligenceEngine.answer(.scopedOutlook(Self.fableIdentity()), features: f, fit: fit)
        // Band gated (nil) either way; confidence low on ~0 completed cycles.
        #expect(est.interval80 == nil)
        #expect(est.interval50 == nil)
        if !est.isInsufficient { #expect(est.confidence == .low) }
    }

    // MARK: - Staleness guard: a vanished limit goes quiet

    @Test func vanishedScopedWindowIsNotForecast() {
        // History exists but the identity is absent from the latest batch
        // (present:false) → no WindowSpec, no fit, outlook insufficient.
        let rows = Self.scopedRows(
            identity: Self.fableIdentity(), group: "weekly", label: "Fable",
            modelId: nil, modelDisplayName: "Fable", surface: nil,
            duration: 7 * 86400, completed: 5, stepH: 8, peak: 58, perStep: 2.0,
            present: false)
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [],
                                     rate: [], lastArrivalAt: nil, scoped: rows)
        #expect(f.windows.filter { $0.isScoped }.isEmpty)
        let fit = UsageIntelligenceEngine.makeFit(f)
        #expect(fit.rl[Self.fableIdentity()] == nil)
        let est = UsageIntelligenceEngine.answer(.scopedOutlook(Self.fableIdentity()), features: f, fit: fit)
        #expect(est.isInsufficient)
    }

    // MARK: - Burn-rate (time-to-limit) warning wiring

    private func fableRule(_ identity: String) -> AlertRule {
        AlertRule(name: identity, metric: AlertRuleMetric.rateLimitPct,
                  thresholdValue: 75, scopedWindow: identity, enabled: true)
    }

    @Test func scopedOnPaceWindowWithConfiguredAlertWarrantsABurnWarning() {
        let id = "session_scoped|Fable|"
        let rows = Self.onPaceSessionRows(identity: id, completed: 5)
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [],
                                     rate: [], lastArrivalAt: nil, scoped: rows)
        // The scoped window is discovered and forecast through the generic path.
        #expect(f.windows.contains { $0.isScoped && $0.key == id })
        let fit = UsageIntelligenceEngine.makeFit(f)
        let outlook = UsageIntelligenceEngine.burnOutlook(f, fit, windowKey: id)
        #expect(outlook != nil)
        // The engine projects a pre-reset crossing off the steep live cycle…
        #expect(outlook!.willHitLimitBeforeReset)
        #expect(outlook!.projectedFullAt! < outlook!.resetsAt)
        #expect(outlook!.usedPct >= BurnRate.warningUsedFloor)
        // …and it's warm (≥ 3 completed cycles), so not cold-start-gated.
        #expect(outlook!.cyclesObserved >= ScopedRateLimitAlerts.burnRateMinCyclesObserved)

        // With a configured scoped threshold alert → warns.
        #expect(ScopedRateLimitAlerts.shouldWarnBurnRate(
            identity: id, willHitLimitBeforeReset: outlook!.willHitLimitBeforeReset,
            usedPct: outlook!.usedPct, cyclesObserved: outlook!.cyclesObserved,
            in: [fableRule(id)]))
        // No configured alert → never warns (opt-in default).
        #expect(!ScopedRateLimitAlerts.shouldWarnBurnRate(
            identity: id, willHitLimitBeforeReset: outlook!.willHitLimitBeforeReset,
            usedPct: outlook!.usedPct, cyclesObserved: outlook!.cyclesObserved, in: []))
    }

    @Test func scopedColdStartWindowDoesNotWarnEvenOnPace() {
        // Zero completed cycles → cold start. Even if the live cycle alone
        // projects a crossing, the cold-start guard keeps us silent.
        let id = "session_scoped|Fable|"
        let rows = Self.onPaceSessionRows(identity: id, completed: 0)
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [],
                                     rate: [], lastArrivalAt: nil, scoped: rows)
        let fit = UsageIntelligenceEngine.makeFit(f)
        let outlook = UsageIntelligenceEngine.burnOutlook(f, fit, windowKey: id)
        #expect(outlook != nil)
        #expect(outlook!.cyclesObserved < ScopedRateLimitAlerts.burnRateMinCyclesObserved)
        // Opted in AND on pace, but cold → no warning.
        #expect(!ScopedRateLimitAlerts.shouldWarnBurnRate(
            identity: id, willHitLimitBeforeReset: outlook!.willHitLimitBeforeReset,
            usedPct: max(outlook!.usedPct, 80), cyclesObserved: outlook!.cyclesObserved,
            in: [fableRule(id)]))
    }

    @Test func vanishedScopedWindowIsNotEvaluatedForBurn() {
        // Absent from the latest poll (present:false) → no WindowSpec, no fit,
        // and `burnOutlook` returns nil, so the burn check never fires for it.
        let id = "session_scoped|Fable|"
        var rows = Self.onPaceSessionRows(identity: id, completed: 5)
        rows = rows.map {
            EngineFeatures.ScopedRow(
                identity: $0.identity, group: $0.group, label: $0.label,
                modelId: $0.modelId, modelDisplayName: $0.modelDisplayName, surface: $0.surface,
                at: $0.at, usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt,
                inLatestBatch: false, isActive: false)
        }
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [],
                                     rate: [], lastArrivalAt: nil, scoped: rows)
        #expect(f.windows.filter { $0.isScoped }.isEmpty)
        let fit = UsageIntelligenceEngine.makeFit(f)
        #expect(UsageIntelligenceEngine.burnOutlook(f, fit, windowKey: id) == nil)
    }

    // MARK: - Snapshot export

    @Test func snapshotExportsScopedOutlookForActor() async throws {
        let container = try PacerStore.makeInMemoryContainer()
        let context = ModelContext(container)
        // Seed a live Fable weekly window via UsageLimitSample rows.
        let rows = Self.scopedRows(
            identity: Self.fableIdentity(), group: "weekly", label: "Fable",
            modelId: nil, modelDisplayName: "Fable", surface: nil,
            duration: 7 * 86400, completed: 5, stepH: 8, peak: 58, perStep: 2.0)
        for r in rows {
            context.insert(UsageLimitSample(
                sampledAt: r.at, identity: r.identity, kind: "weekly_scoped", group: r.group,
                label: r.label, percent: r.usedPercentage, resetsAt: r.resetsAt,
                severity: "normal", isActive: r.inLatestBatch, modelId: r.modelId,
                modelDisplayName: r.modelDisplayName, surface: r.surface, source: "oauth"))
        }
        try context.save()

        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.recompute(now: Self.now, calendar: Self.utc)
        let scopedSpecs = await engine.scopedWindows()
        #expect(scopedSpecs.contains { $0.key == Self.fableIdentity() })
        let snap = await engine.snapshot()
        #expect(snap.scoped?.contains { $0.identity == Self.fableIdentity() } == true)
    }
}
