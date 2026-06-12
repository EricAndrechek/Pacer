import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// Tests for the self-eval feedback loop: scoring completed days into the
/// persisted scoreboard, learning the per-user clock→shape crossover from the
/// accumulated record, the accuracy report, and the end-to-end actor path.
@Suite("Engine self-eval")
struct EngineSelfEvalTests {

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    static let now = utc.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 20, minute: 30))!

    private func bucket(_ cf: Double) -> String { "cut=\(String(format: "%.2f", cf))|all" }
    private func rec(_ method: String, _ cf: Double, _ period: String, _ predicted: Double, _ truth: Double) -> EngineSelfEval.Record {
        .init(method: method, bucket: bucket(cf), periodKey: period, predicted: predicted, truth: truth)
    }

    // MARK: - Per-cut trimmed pools from the persisted record

    @Test func poolTrimsTheWeakMethodPerCut() {
        // At early cuts the shape is far off (it would drag a plain median);
        // at late cuts it's the best. The pool must exclude it early and
        // include it (first) late.
        var records: [EngineSelfEval.Record] = []
        for i in 0..<12 {
            let p = "p\(i)", truth = 100.0
            for cf in EngineSelfEval.cutFractions {
                let late = cf >= 0.75
                records.append(rec("regime-gated-eod", cf, p, late ? 102 : 200, truth))  // 2% late, 100% early
                records.append(rec("average-rate", cf, p, 110, truth))                    // 10% always
                records.append(rec("additive-pickup", cf, p, 112, truth))                 // 12% always
            }
        }
        let early = EngineSelfEval.poolMembers(forCut: 0.375, records: records)
        #expect(!early.contains("regime-gated-eod"))
        #expect(early.contains("average-rate") && early.contains("additive-pickup"))
        let late = EngineSelfEval.poolMembers(forCut: 0.875, records: records)
        #expect(late.first == "regime-gated-eod")   // best-first ordering
    }

    @Test func poolColdStartReturnsAllCandidates() {
        // Below the min-periods bar nothing is trusted → median-of-everything.
        var records: [EngineSelfEval.Record] = []
        for i in 0..<5 {                      // < poolMinPeriods
            records.append(rec("average-rate", 0.5, "p\(i)", 110, 100))
        }
        let pool = EngineSelfEval.poolMembers(forCut: 0.5, records: records)
        #expect(Set(pool) == Set(EngineSelfEval.eodCandidates.map { $0.id }))
    }

    // MARK: - Accuracy report

    @Test func accuracyReportsMedianErrorPerMethod() {
        let records = [
            rec("average-rate", 0.5, "p0", 110, 100),   // APE 10
            rec("average-rate", 0.5, "p1", 120, 100),   // APE 20
            rec("average-rate", 0.5, "p2", 130, 100),   // APE 30
        ]
        let acc = EngineSelfEval.accuracy(from: records)
        let clock = acc.methods.first { $0.method == "average-rate" }
        #expect(clock?.periods == 3)
        #expect(abs((clock?.medianAbsPctError ?? 0) - 20) < 1e-9)
    }

    // MARK: - Scoring completed days (pure)

    @Test func newOutcomesAreIdempotentAndCoverBothMethods() {
        // Build prior days as cumulative-by-hour periods via the feature builder.
        var hourly: [EngineFeatures.HourlyRow] = []
        var daily: [EngineFeatures.DailyRow] = []
        let cal = Self.utc
        for i in 1...30 {
            let day = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: Self.now))!
            let k = TokenSample.formatDate(day, timeZone: cal.timeZone)
            for h in [9, 13, 17] { hourly.append(.init(date: k, hour: h, cost: 12, sampleCount: 1)) }
            daily.append(.init(date: k, cost: 36))
        }
        let f = EngineFeatures.build(now: Self.now, calendar: cal, daily: daily, hourly: hourly, rate: [], lastArrivalAt: nil)

        let first = EngineSelfEval.newOutcomesEOD(periods: f.dailyPeriods, calendar: cal, existingKeys: [])
        #expect(!first.isEmpty)
        #expect(first.contains { $0.method == "average-rate" })
        #expect(first.contains { $0.method == "regime-gated-eod" })

        // Re-running with everything already recorded yields nothing new.
        let keys = Set(first.map { EngineEvalOutcome.makeKey(surface: $0.surface, method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey) })
        let second = EngineSelfEval.newOutcomesEOD(periods: f.dailyPeriods, calendar: cal, existingKeys: keys)
        #expect(second.isEmpty)
    }

    // MARK: - Rate-limit outlook self-eval

    /// Build `n` complete 7-day cycles, each ramping 0 → ~60%.
    private func sevenDayCycles(_ n: Int) -> [BurnTrajectory.Cycle] {
        let duration: TimeInterval = 7 * 24 * 3600
        return (0..<n).map { c in
            let start = Self.now.addingTimeInterval(-Double(n - c) * duration)
            let reset = start.addingTimeInterval(duration)
            var samples: [BurnTrajectory.Sample] = []
            var pct = 0.0, t = start
            while t <= reset {
                samples.append(.init(at: t, usedPercentage: min(60, pct)))
                t = t.addingTimeInterval(6 * 3600); pct += 2.2
            }
            return BurnTrajectory.Cycle(samples: samples, cycleStart: start, resetsAt: reset)
        }
    }

    @Test func rlOutcomesIncludeDiurnalAndAreIdempotent() {
        let cycles = sevenDayCycles(4)
        let grid = [[Double]](repeating: [Double](repeating: 1, count: 24), count: 7)
        let first = EngineSelfEval.newOutcomesRL(
            window: "seven_day", cycles: cycles, activityGrid: grid, calendar: Self.utc,
            existingKeys: [], includeDiurnal: true)
        #expect(!first.isEmpty)
        #expect(first.contains { $0.method == "diurnal-rate" })          // the diurnal model earns a record
        #expect(first.contains { $0.method == "linear-recent" })

        let keys = Set(first.map { EngineEvalOutcome.makeKey(surface: $0.surface, method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey) })
        let second = EngineSelfEval.newOutcomesRL(
            window: "seven_day", cycles: cycles, activityGrid: grid, calendar: Self.utc,
            existingKeys: keys, includeDiurnal: true)
        #expect(second.isEmpty)
    }

    @Test func bestMethodPrefersLowerErrorAcrossPeriods() {
        var records: [EngineSelfEval.Record] = []
        for i in 0..<4 {
            let p = "c\(i)", truth = 60.0
            records.append(.init(method: "diurnal-rate", bucket: "cut=0.50", periodKey: p, predicted: 58, truth: truth))   // APE ~3
            records.append(.init(method: "linear-recent", bucket: "cut=0.50", periodKey: p, predicted: 90, truth: truth))  // APE 50
        }
        #expect(EngineSelfEval.bestMethod(from: records) == "diurnal-rate")
        // Below the min-periods bar, no pick (engine falls back to on-the-fly).
        #expect(EngineSelfEval.bestMethod(from: Array(records.prefix(1)), minPeriods: 2) == nil)
    }

    // MARK: - Burn outlook + trajectories (the chart / warning surface)

    /// Features with one live 5h cycle ramping fast enough to cross 100%
    /// before reset, plus a few completed cycles of history.
    private func steepFiveHourFeatures() -> EngineFeatures {
        let duration: TimeInterval = 5 * 3600
        var rate: [EngineFeatures.RateRow] = []
        // Three completed gentle cycles.
        for c in 0..<3 {
            let start = Self.now.addingTimeInterval(-Double(4 - c) * duration)
            let reset = start.addingTimeInterval(duration)
            var pct = 0.0, t = start
            while t <= reset {
                rate.append(.init(window: "five_hour", at: t, usedPercentage: min(60, pct), resetsAt: reset))
                t = t.addingTimeInterval(15 * 60); pct += 2
            }
        }
        // Live cycle: started 2.5h ago, at 75% and climbing ~25pp/hr → crosses
        // 100% in ~1h, well before the reset 2.5h out.
        let liveStart = Self.now.addingTimeInterval(-2.5 * 3600)
        let liveReset = liveStart.addingTimeInterval(duration)
        var pct = 0.0
        var t = liveStart
        while t <= Self.now {
            rate.append(.init(window: "five_hour", at: t, usedPercentage: min(100, pct), resetsAt: liveReset))
            t = t.addingTimeInterval(15 * 60); pct += 25.0 / 4
        }
        return EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [],
                                    rate: rate, lastArrivalAt: nil)
    }

    @Test func burnOutlookFlagsAPreResetCrossingOnASteepCycle() {
        let f = steepFiveHourFeatures()
        let fit = UsageIntelligenceEngine.makeFit(f)
        let outlook = UsageIntelligenceEngine.burnOutlook(f, fit, window: .fiveHour)
        #expect(outlook != nil)
        #expect(outlook!.slopePercentPerHour > 10)            // climbing hard
        #expect(outlook!.willHitLimitBeforeReset)             // crossing flagged
        #expect(outlook!.projectedFullAt! > f.now)
        #expect(outlook!.projectedFullAt! < outlook!.resetsAt) // strictly before reset
        #expect(outlook!.usedPct > 60)
    }

    @Test func burnOutlookProjectsNoCrossingOnAFlatCycle() {
        // Live cycle dead flat at 40% → no crossing, near-zero slope.
        let duration: TimeInterval = 5 * 3600
        let liveStart = Self.now.addingTimeInterval(-2 * 3600)
        let liveReset = liveStart.addingTimeInterval(duration)
        var rate: [EngineFeatures.RateRow] = []
        var t = liveStart
        while t <= Self.now {
            rate.append(.init(window: "five_hour", at: t, usedPercentage: 40, resetsAt: liveReset))
            t = t.addingTimeInterval(15 * 60)
        }
        let f = EngineFeatures.build(now: Self.now, calendar: Self.utc, daily: [], hourly: [],
                                     rate: rate, lastArrivalAt: nil)
        let fit = UsageIntelligenceEngine.makeFit(f)
        let outlook = UsageIntelligenceEngine.burnOutlook(f, fit, window: .fiveHour)
        #expect(outlook != nil)
        #expect(!outlook!.willHitLimitBeforeReset)
        #expect(abs(outlook!.slopePercentPerHour) < 1)
    }

    @Test func trajectoriesSpanNowToResetAndFlagSelection() {
        let f = steepFiveHourFeatures()
        let fit = UsageIntelligenceEngine.makeFit(f)
        let list = UsageIntelligenceEngine.rateLimitTrajectories(f, fit, window: .fiveHour, accuracy: nil)
        #expect(!list.isEmpty)
        #expect(list.filter { $0.isSelected }.count <= 1)
        for st in list {
            #expect(st.trajectory.points.first?.at == f.now)
            #expect(st.trajectory.points.allSatisfy { $0.usedPercentage >= 0 && $0.usedPercentage <= 100 })
        }
        // At least one model should see the steep climb crossing 100%.
        #expect(list.contains { $0.trajectory.crossesFullAt != nil })
    }

    // MARK: - End-to-end actor persistence

    @Test func recomputePersistsScoreboardAndIsIdempotent() async throws {
        let container = try PacerStore.makeInMemoryContainer()
        let cal = Self.utc

        // Seed ~30 prior complete days of pre-aggregated cost.
        let seed = ModelContext(container)
        for i in 1...30 {
            let day = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: Self.now))!
            let k = TokenSample.formatDate(day, timeZone: cal.timeZone)
            seed.insert(DailyAggregate(date: k, model: "m", totalCostUSD: 36))
            for h in [9, 13, 17] {
                seed.insert(HourlyAggregate(date: k, hour: h, model: "m", totalCostUSD: 12, sampleCount: 1))
            }
        }
        try seed.save()

        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.recompute(now: Self.now, calendar: cal)

        func outcomeCount() throws -> Int {
            try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>()).count
        }
        let afterFirst = try outcomeCount()
        #expect(afterFirst > 0)                       // the scoreboard persisted

        // A second recompute scores nothing new — the loop is idempotent.
        await engine.recompute(now: Self.now, calendar: cal)
        #expect(try outcomeCount() == afterFirst)

        // The track record is exposed and includes the clock baseline.
        let acc = await engine.selfEvalAccuracy()
        #expect(acc != nil)
        #expect(acc?.methods.contains { $0.method == "average-rate" } == true)
    }

    @Test func recomputePersistsRateLimitTrackRecordIncludingDiurnal() async throws {
        let container = try PacerStore.makeInMemoryContainer()
        let cal = Self.utc
        let duration: TimeInterval = 7 * 24 * 3600

        // Seed 3 complete 7-day cycles of OAuth utilisation samples.
        let seed = ModelContext(container)
        for c in 0..<3 {
            let start = Self.now.addingTimeInterval(-Double(3 - c) * duration)
            let reset = start.addingTimeInterval(duration)
            var pct = 0.0, t = start
            while t <= reset {
                seed.insert(RateLimitSample(sampledAt: t, window: "seven_day", usedPercentage: min(60, pct), resetsAt: reset, source: "oauth"))
                t = t.addingTimeInterval(6 * 3600); pct += 2.2
            }
        }
        try seed.save()

        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.recompute(now: Self.now, calendar: cal)

        let rows = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>())
        let rl = rows.filter { $0.surface == EngineSelfEval.rlSurface("seven_day") }
        #expect(!rl.isEmpty)
        #expect(rl.contains { $0.method == "diurnal-rate" })   // diurnal now has a persisted track record

        let acc = await engine.selfEvalAccuracy(surface: EngineSelfEval.rlSurface("seven_day"))
        #expect(acc != nil)
    }
}
