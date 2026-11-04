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
        let first = UsageIntelligenceEngine.makeFit(f)
        let once = UsageIntelligenceEngine.burnOutlook(f, first, windowKey: "five_hour")
        #expect(once?.hitClaimable == true)                   // the evidence is there…
        #expect(once?.willHitLimitBeforeReset == false)       // …but one refit doesn't claim it (#304)
        // Two consecutive refits of the same cycle do.
        let second = UsageIntelligenceEngine.carryClaimStreaks(
            f, into: UsageIntelligenceEngine.makeFit(f),
            from: UsageIntelligenceEngine.carryClaimStreaks(f, into: first, from: .init()))
        let outlook = UsageIntelligenceEngine.burnOutlook(f, second, windowKey: "five_hour")
        #expect(outlook != nil)
        #expect(outlook!.slopePercentPerHour > 10)            // climbing hard
        #expect(outlook!.willHitLimitBeforeReset)             // crossing claimed
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
        let outlook = UsageIntelligenceEngine.burnOutlook(f, fit, windowKey: "five_hour")
        #expect(outlook != nil)
        #expect(!outlook!.willHitLimitBeforeReset)
        #expect(abs(outlook!.slopePercentPerHour) < 1)
    }

    @Test func trajectoriesSpanNowToResetAndFlagSelection() {
        let f = steepFiveHourFeatures()
        let fit = UsageIntelligenceEngine.makeFit(f)
        let list = UsageIntelligenceEngine.rateLimitTrajectories(f, fit, windowKey: "five_hour", accuracy: nil)
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

    // MARK: - Settled moments (#374)

    /// `n` completed cycles of `duration` whose meter climbs evenly to
    /// `final` by `settlesAt` of the window and then sits there: every cut
    /// after it is a settled moment.
    private func settlingCycles(_ n: Int, duration: TimeInterval, final: Double, settlesAt: Double,
                                step: TimeInterval) -> [BurnTrajectory.Cycle] {
        (0..<n).map { c in
            let start = Self.now.addingTimeInterval(-Double(n - c) * duration)
            let reset = start.addingTimeInterval(duration)
            var samples: [BurnTrajectory.Sample] = []
            var t = start
            while t <= reset {
                let f = t.timeIntervalSince(start) / duration
                samples.append(.init(at: t, usedPercentage: (final * min(1, f / settlesAt)).rounded()))
                t = t.addingTimeInterval(step)
            }
            return BurnTrajectory.Cycle(samples: samples, cycleStart: start, resetsAt: reset)
        }
    }

    /// The engine's methods graded on `cycles`, plus a model that holds the
    /// reading ("Stays where it is"), simplest of all, graded the same way:
    /// its shown value is the reading at the cut.
    private func settlingRecord(_ cycles: [BurnTrajectory.Cycle], window: String) -> [EngineSelfEval.Record] {
        let graded = EngineSelfEval.newOutcomesRL(window: window, cycles: cycles, activityGrid: [],
                                                  calendar: Self.utc, existingKeys: [], includeDiurnal: false)
        var rows = graded.map {
            EngineSelfEval.Record(method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey,
                                  predicted: $0.predicted, truth: $0.truth, inputs: $0.inputs, reading: $0.reading)
        }
        var moments = Set<String>()
        for r in rows where moments.insert(r.periodKey + r.bucket).inserted {
            rows.append(.init(method: "hold", bucket: r.bucket, periodKey: r.periodKey,
                              predicted: r.reading!, truth: r.truth, reading: r.reading))
        }
        return rows
    }

    private var settlingComplexity: [String: Int] {
        RateLimitRoster.engineComplexities.merging(["hold": 0]) { a, _ in a }
    }

    private func rankSettling(_ rows: [EngineSelfEval.Record], weekly: Bool) -> EngineSelfEval.RLRanking {
        EngineSelfEval.rankRL(rows, complexity: settlingComplexity, weekly: weekly, at: 0.85,
                              depth: EngineSelfEval.rlDepth(weekly: weekly), tieRelative: 0.05, disagreement: 2)
    }

    /// Past cycles that reached their final early and sat there; the live
    /// one is 0.85 of the way through and still climbing. Every graded moment
    /// near 0.85 is settled, where holding the reading is exactly right
    /// without forecasting anything. Ranking leaves those out and falls back
    /// to the open moments at every cut, where the record separates the
    /// models: the pick extrapolates. A final of 98 is the case where holding
    /// and clamping to 100 spread exactly 2 points. Five-hour blocks maxed
    /// early are the same shape, ranked the same way.
    @Test(arguments: [(window: "seven_day", final: 98.0), (window: "seven_day", final: 100.0),
                      (window: "five_hour", final: 100.0), (window: "five_hour", final: 98.0)])
    func settledMomentsDoNotRank(window: String, final: Double) throws {
        let weekly = window == "seven_day"
        let duration: TimeInterval = weekly ? 7 * 86_400 : 5 * 3600
        let cycles = settlingCycles(weekly ? 3 : 8, duration: duration, final: final,
                                    settlesAt: weekly ? 0.6 : 0.3, step: duration / 56)
        let rows = settlingRecord(cycles, window: window)

        // The trap: every moment graded near 0.85 is settled, and there
        // holding the reading is exactly right.
        let near = rows.filter { $0.method == "hold" && EngineSelfEval.rlCutFraction($0.bucket)! >= 0.7 }
        #expect(!near.isEmpty && near.allSatisfy { $0.predicted == $0.truth && $0.reading == $0.truth })

        let after = rankSettling(rows, weekly: weekly)
        let pick = try #require(after.pick)
        #expect(pick != "hold")
        #expect(!after.noEvidence)
        // Holding is ranked on the open moments now, and there it is far off.
        let hold = try #require(after.standing("hold")?.typicalAbsError)
        let best = try #require(after.standing(pick)?.typicalAbsError)
        #expect(hold > 10 && best < hold)
        // Still the live point's ranking; the open moments it fell back to
        // are every cut's, alike.
        #expect(after.at == 0.85)
    }

    @Test func aMomentIsSettledAtItsFinal() {
        #expect(EngineSelfEval.isSettled(reading: 98, truth: 98))
        #expect(EngineSelfEval.isSettled(reading: 99.6, truth: 100))
        #expect(!EngineSelfEval.isSettled(reading: 97, truth: 98))
    }

    /// The reading travels with a grade, the arena's and the engine's alike,
    /// and a row graded before it was recorded takes its moment's from any
    /// row that has it.
    @Test func aMomentsReadingComesFromAnyOfItsRows() throws {
        let cycles = settlingCycles(3, duration: 7 * 86_400, final: 98, settlesAt: 0.6, step: 3 * 3600)
        let rows = settlingRecord(cycles, window: "seven_day")
        #expect(rows.allSatisfy { $0.reading != nil })
        // "hold" graded before readings: it takes the engine rows'.
        let mixed = rows.map {
            $0.method == "hold"
                ? EngineSelfEval.Record(method: $0.method, bucket: $0.bucket, periodKey: $0.periodKey,
                                        predicted: $0.predicted, truth: $0.truth)
                : $0
        }
        #expect(rankSettling(mixed, weekly: true) == rankSettling(rows, weekly: true))
    }

    // MARK: - No evidence (#374)

    /// A zero-width band: with a best of 0, a model 0.05 off is still tied,
    /// and the simplest of the tied is picked, not the simplest at exactly 0.
    @Test func theTieBandHasAnAbsoluteFloor() {
        let scored = [(id: "a", err: 0.0), (id: "b", err: 0.0), (id: "c", err: 0.05), (id: "d", err: 0.3)]
        let complexity = ["a": 3, "b": 2, "c": 1, "d": 0]
        #expect(EngineSelfEval.pickWithinTie(scored, complexity: complexity, tieRelative: 0.05) == "c")
        // Above the floor the relative band is as it was.
        let wide = [(id: "a", err: 10.0), (id: "b", err: 10.4), (id: "c", err: 10.6)]
        #expect(EngineSelfEval.pickWithinTie(wide, complexity: complexity, tieRelative: 0.05) == "b")
    }

    /// Every moment settled, so the record holds nothing but ties at 0:
    /// matched or over every cut, it is no evidence. Nothing is picked (the
    /// cold backtest picks), and no number is shown.
    @Test func anAllZeroBoardIsNoEvidence() throws {
        var rows: [EngineSelfEval.Record] = []
        for p in 0..<3 {
            let period = EngineSelfEval.periodKeyRL(Self.now.addingTimeInterval(Double(p) * 7 * 86_400))
            for cut in EngineSelfEval.rlGrading.cuts {
                for (m, miss) in [("a", 0.0), ("b", 0.0), ("c", 0.0), ("d", 2.0)] {
                    rows.append(.init(method: m, bucket: EngineSelfEval.rlGrading.bucket(cut), periodKey: period,
                                      predicted: 98 + miss, truth: 98, reading: 98))
                }
            }
        }
        let r = EngineSelfEval.rankRL(rows, complexity: ["a": 1, "b": 2, "c": 3, "d": 4], weekly: true, at: 0.85,
                                      depth: 17, tieRelative: 0.05, disagreement: 2)
        #expect(r.noEvidence)
        #expect(r.pick == nil)
        #expect(r.ranked.count == 4)
        #expect(r.accuracy(surface: "rl-seven_day").methods.allSatisfy { !$0.typicalAbsError.isFinite })

        let board = UsageIntelligenceEngine.board(
            windowKey: "seven_day", weekly: true, ranking: r, current: r, engineIds: ["a", "b", "c", "d"],
            specs: [], complexity: [:], selected: nil, shown: "a", cutFraction: 0.85, canRunArena: true,
            weightsPresent: { _ in true }, liveFailure: { _ in nil }, progress: nil, gradedThrough: true,
            drawLimit: 4)
        #expect(board.rows.allSatisfy { $0.status == .noEvidence(cycles: 3) })
    }

    /// A tie at 0 only near the live point, while the open record over every
    /// cut separates the models: ranked over every cut.
    @Test func aZeroTieNearTheLivePointRanksOverEveryCut() throws {
        var rows: [EngineSelfEval.Record] = []
        for p in 0..<3 {
            let period = EngineSelfEval.periodKeyRL(Self.now.addingTimeInterval(Double(p) * 7 * 86_400))
            for cut in EngineSelfEval.rlGrading.cuts {
                // Early cuts: "a" and "b" 4 and 1 off; late ones, both exact.
                let late = cut >= 0.7
                for (m, miss) in [("a", late ? 0.0 : 4.0), ("b", late ? 0.0 : 1.0)] {
                    rows.append(.init(method: m, bucket: EngineSelfEval.rlGrading.bucket(cut), periodKey: period,
                                      predicted: 60 + miss, truth: 60))
                }
            }
        }
        let r = EngineSelfEval.rankRL(rows, complexity: ["a": 1, "b": 2], weekly: true, at: 0.85,
                                      depth: 17, tieRelative: 0.05)
        #expect(!r.noEvidence)
        #expect(r.at == nil)
        #expect(r.pick == "b")
    }

    // MARK: - Disagreement at the cap (#374)

    /// Holding 98 against clamping to 100 is exactly 2 points apart, and is
    /// not disagreement: only a spread of more than the threshold is.
    @Test func aSpreadOfExactlyTheThresholdIsNotDisagreement() {
        // Two cycles where the models spread exactly 2 points, one where they
        // spread 5: only the last one's moments count.
        let rows = (0..<3).flatMap { p -> [EngineSelfEval.Record] in
            let period = EngineSelfEval.periodKeyRL(Self.now.addingTimeInterval(Double(p) * 7 * 86_400))
            let spread = p < 2 ? 2.0 : 5.0
            return EngineSelfEval.rlGrading.cuts.flatMap { cut -> [EngineSelfEval.Record] in
                let b = EngineSelfEval.rlGrading.bucket(cut)
                return [.init(method: "low", bucket: b, periodKey: period, predicted: 80, truth: 90),
                        .init(method: "high", bucket: b, periodKey: period, predicted: 80 + spread, truth: 90)]
            }
        }
        let r = EngineSelfEval.rankRL(rows, weekly: true, at: 0.85, depth: 17, tieRelative: 0.05, disagreement: 2)
        #expect(r.standing("high")?.typicalAbsError == 5)
        #expect(r.standing("low")?.typicalAbsError == 10)
    }
}
