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

    // MARK: - Crossover from the persisted record

    @Test func crossoverPicksEveningTailWhereShapeRobustlyWins() {
        // Shape is much closer than clock only at the late buckets (>=0.75);
        // clock wins earlier. Crossover should land at the start of that tail.
        var records: [EngineSelfEval.Record] = []
        for i in 0..<12 {
            let p = "p\(i)", truth = 100.0
            for cf in EngineSelfEval.cutFractions {
                let lateWin = cf >= 0.75
                records.append(rec("regime-gated-eod", cf, p, lateWin ? 100 : 150, truth))  // APE 0 late, 50 early
                records.append(rec("average-rate", cf, p, lateWin ? 130 : 110, truth))       // APE 30 late, 10 early
            }
        }
        #expect(EngineSelfEval.crossover(from: records) == 0.75)
    }

    @Test func crossoverIsInfinityWhenShapeNeverRobustlyWins() {
        // Shape always worse → never selected → clock all day.
        var records: [EngineSelfEval.Record] = []
        for i in 0..<12 {
            let p = "p\(i)", truth = 100.0
            for cf in EngineSelfEval.cutFractions {
                records.append(rec("regime-gated-eod", cf, p, 200, truth))   // APE 100
                records.append(rec("average-rate", cf, p, 110, truth))       // APE 10
            }
        }
        #expect(EngineSelfEval.crossover(from: records) == .infinity)
    }

    @Test func crossoverIsInfinityOnThinData() {
        // Even a clean shape win doesn't get trusted below the shared-day bar.
        var records: [EngineSelfEval.Record] = []
        for i in 0..<5 {                      // < minShared
            let p = "p\(i)", truth = 100.0
            records.append(rec("regime-gated-eod", 0.875, p, 100, truth))
            records.append(rec("average-rate", 0.875, p, 140, truth))
        }
        #expect(EngineSelfEval.crossover(from: records) == .infinity)
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
}
