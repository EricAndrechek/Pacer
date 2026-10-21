import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The end-of-day scoreboard follows its priced history (#329): when a day is
/// repriced, its rows and every later day's are replayed, so `predicted` and
/// `truth` are always dollars of the same pricing as `DailyAggregate`.
@Suite("Engine scoreboard rescore")
struct EngineScoreboardRescoreTests {

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    static let now = utc.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 20, minute: 30))!

    static func key(_ back: Int) -> String {
        let day = utc.date(byAdding: .day, value: -back, to: utc.startOfDay(for: now))!
        return TokenSample.formatDate(day, timeZone: utc.timeZone)
    }

    /// A day's three active hours. Costs vary by day so each day's backtest
    /// depends on its priors, which is what makes a repriced prior matter.
    static func hours(_ back: Int) -> [(hour: Int, cost: Double)] {
        [(9, 5 + Double(back % 7)), (13, 8 + Double(back % 5)), (17, 3 + Double(back % 3))]
    }

    static func features(days: ClosedRange<Int>) -> EngineFeatures {
        var hourly: [EngineFeatures.HourlyRow] = []
        var daily: [EngineFeatures.DailyRow] = []
        for back in days {
            let hs = hours(back)
            for h in hs { hourly.append(.init(date: key(back), hour: h.hour, cost: h.cost, sampleCount: 1)) }
            daily.append(.init(date: key(back), cost: hs.reduce(0) { $0 + $1.cost }))
        }
        return EngineFeatures.build(now: now, calendar: utc, daily: daily, hourly: hourly, rate: [], lastArrivalAt: nil)
    }

    static func sorted(_ xs: [EngineSelfEval.NewOutcome]) -> [EngineSelfEval.NewOutcome] {
        xs.sorted { ($0.periodKey, $0.bucket, $0.method) < ($1.periodKey, $1.bucket, $1.method) }
    }

    // MARK: - Pure

    @Test func staleDaysFindsTheEarliestRepricedDay() {
        func rec(_ day: String, _ truth: Double) -> EngineSelfEval.Record {
            .init(method: "m", bucket: "b", periodKey: day, predicted: truth, truth: truth)
        }
        let totals = ["2026-06-01": 10.0, "2026-06-02": 20.0, "2026-06-03": 30.0]
        // Current: nothing to do.
        #expect(EngineSelfEval.staleEODDays(records: [rec("2026-06-01", 10), rec("2026-06-02", 20)],
                                            dayTotals: totals) == nil)
        // Two repriced days: the earliest wins, both count.
        let stale = EngineSelfEval.staleEODDays(
            records: [rec("2026-06-01", 10), rec("2026-06-03", 31), rec("2026-06-02", 19), rec("2026-06-02", 19)],
            dayTotals: totals)
        #expect(stale?.earliest == "2026-06-02")
        #expect(stale?.count == 2)
        // A scored day the history no longer has is stale; one from before the
        // history starts can't be checked and is left alone.
        #expect(EngineSelfEval.staleEODDays(records: [rec("2026-06-04", 5)], dayTotals: totals)?.earliest == "2026-06-04")
        #expect(EngineSelfEval.staleEODDays(records: [rec("2026-05-31", 5)], dayTotals: totals) == nil)
    }

    @Test func replayReproducesLiveScoring() {
        // Under the live window, live scoring and the replay see the same
        // priors for every day, so they must agree exactly.
        let f = Self.features(days: 1...30)
        let live = EngineSelfEval.newOutcomesEOD(periods: f.dailyPeriods, calendar: Self.utc, existingKeys: [])
        let replay = EngineSelfEval.replayOutcomesEOD(days: f.dailyPeriods, from: Self.key(30), calendar: Self.utc)
        #expect(!live.isEmpty)
        #expect(Self.sorted(replay) == Self.sorted(live))

        // Over a longer history the newest day replays to exactly what live
        // scoring gives it: the 59 days before it.
        let long = Self.features(days: 1...90)
        let all = EngineFeatures.priorPeriods(long.priorDayHourlyCosts, keys: long.priorDayHourlyCosts.keys.sorted(),
                                              calendar: Self.utc)
        #expect(all.count == 90 && long.dailyPeriods.count == EngineFeatures.eodPriorDays)
        let newestLive = EngineSelfEval.newOutcomesEOD(periods: long.dailyPeriods, calendar: Self.utc, existingKeys: [])
            .filter { $0.periodKey == Self.key(1) }
        let newestReplay = EngineSelfEval.replayOutcomesEOD(days: all, from: Self.key(1), calendar: Self.utc)
        #expect(!newestReplay.isEmpty)
        #expect(Self.sorted(newestReplay) == Self.sorted(newestLive))
    }

    // MARK: - Through the engine

    typealias Row = (predicted: Double, truth: Double, recordedAt: Date)

    @MainActor
    static func seed(_ container: ModelContainer, days: ClosedRange<Int>, account: String? = nil) throws {
        let context = ModelContext(container)
        for back in days {
            let hs = hours(back)
            let total = hs.reduce(0) { $0 + $1.cost }
            if let account {
                context.insert(AccountDailyAggregate(
                    accountId: account, date: key(back), model: "m",
                    inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                    cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: total))
                for h in hs {
                    context.insert(AccountHourlyAggregate(
                        accountId: account, date: key(back), hour: h.hour, model: "m",
                        inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                        cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: h.cost))
                }
            } else {
                context.insert(DailyAggregate(date: key(back), model: "m", totalCostUSD: total))
                for h in hs {
                    context.insert(HourlyAggregate(date: key(back), hour: h.hour, model: "m",
                                                   totalCostUSD: h.cost, sampleCount: 1))
                }
            }
        }
        try context.save()
    }

    /// Multiply the cost of `days` by `factor` in both rollups, as a price
    /// correction would.
    @MainActor
    static func reprice(_ container: ModelContainer, days: Set<String>, by factor: Double, account: String? = nil) throws {
        let context = ModelContext(container)
        if let account {
            for r in try context.fetch(FetchDescriptor<AccountDailyAggregate>()) where r.accountId == account && days.contains(r.date) {
                r.totalCostUSD *= factor
            }
            for r in try context.fetch(FetchDescriptor<AccountHourlyAggregate>()) where r.accountId == account && days.contains(r.date) {
                r.totalCostUSD *= factor
            }
        } else {
            for r in try context.fetch(FetchDescriptor<DailyAggregate>()) where days.contains(r.date) { r.totalCostUSD *= factor }
            for r in try context.fetch(FetchDescriptor<HourlyAggregate>()) where days.contains(r.date) { r.totalCostUSD *= factor }
        }
        try context.save()
    }

    static func eodRows(_ container: ModelContainer, surface: String = EngineSelfEval.surfaceEOD) throws -> [String: Row] {
        let rows = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>())
        return Dictionary(uniqueKeysWithValues: rows.filter { $0.surface == surface }
            .map { ($0.key, (predicted: $0.predicted, truth: $0.truth, recordedAt: $0.recordedAt)) })
    }

    static func dayTotals(_ container: ModelContainer, account: String? = nil) throws -> [String: Double] {
        let context = ModelContext(container)
        var out: [String: Double] = [:]
        if let account {
            for r in try context.fetch(FetchDescriptor<AccountDailyAggregate>()) where r.accountId == account {
                out[r.date, default: 0] += r.totalCostUSD
            }
        } else {
            for r in try context.fetch(FetchDescriptor<DailyAggregate>()) { out[r.date, default: 0] += r.totalCostUSD }
        }
        return out
    }

    @Test func recomputeRescoresARepricedHistory() async throws {
        let container = try PacerStore.makeInMemoryContainer()
        try await MainActor.run { try Self.seed(container, days: 1...40) }
        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.recompute(now: Self.now, calendar: Self.utc)
        let before = try Self.eodRows(container)
        #expect(!before.isEmpty)

        // A price correction lands on three days in the middle of the history.
        let repriced: Set<String> = [Self.key(20), Self.key(19), Self.key(18)]
        try await MainActor.run { try Self.reprice(container, days: repriced, by: 1.4) }
        await engine.recompute(now: Self.now, calendar: Self.utc)
        let after = try Self.eodRows(container)

        // Every truth is the day's priced total again.
        let totals = try Self.dayTotals(container)
        for (key, row) in after {
            let day = String(key.split(separator: "|").last!)
            #expect(abs(row.truth - totals[day]!) < 1e-6, "\(key)")
        }
        // Days before the earliest repriced one are untouched, to the bit.
        for (key, row) in before where String(key.split(separator: "|").last!) < Self.key(20) {
            #expect(after[key]?.predicted == row.predicted && after[key]?.truth == row.truth, "\(key)")
        }
        // And the whole scoreboard is what a fresh engine computes on the
        // repriced history.
        let fresh = try PacerStore.makeInMemoryContainer()
        try await MainActor.run {
            try Self.seed(fresh, days: 1...40)
            try Self.reprice(fresh, days: repriced, by: 1.4)
        }
        await UsageIntelligenceEngine(modelContainer: fresh).recompute(now: Self.now, calendar: Self.utc)
        let expected = try Self.eodRows(fresh)
        #expect(Set(after.keys) == Set(expected.keys))
        for (key, row) in expected {
            #expect(abs((after[key]?.predicted ?? .nan) - row.predicted) < 1e-9, "\(key)")
        }

        // Once current, a refit changes nothing.
        await engine.recompute(now: Self.now.addingTimeInterval(60), calendar: Self.utc)
        let again = try Self.eodRows(container)
        #expect(again.count == after.count)
        for (key, row) in after {
            #expect(again[key]?.predicted == row.predicted && again[key]?.recordedAt == row.recordedAt, "\(key)")
        }
    }

    @Test func aScopedEngineRescoresOnlyItsOwnRows() async throws {
        let container = try PacerStore.makeInMemoryContainer()
        try await MainActor.run {
            try Self.seed(container, days: 1...30)
            try Self.seed(container, days: 1...30, account: "work")
        }
        let global = UsageIntelligenceEngine(modelContainer: container)
        let work = UsageIntelligenceEngine(modelContainer: container)
        await work.adopt(scope: .account("work"))
        await global.recompute(now: Self.now, calendar: Self.utc)
        await work.recompute(now: Self.now, calendar: Self.utc)
        let workSurface = EngineScope.account("work").qualify(EngineSelfEval.surfaceEOD)
        let globalBefore = try Self.eodRows(container)
        #expect(!globalBefore.isEmpty)
        #expect(!(try Self.eodRows(container, surface: workSurface)).isEmpty)

        // Only the account's history moves.
        try await MainActor.run { try Self.reprice(container, days: [Self.key(10)], by: 0.5, account: "work") }
        await global.recompute(now: Self.now, calendar: Self.utc)
        await work.recompute(now: Self.now, calendar: Self.utc)

        let globalAfter = try Self.eodRows(container)
        #expect(globalAfter.count == globalBefore.count)
        for (key, row) in globalBefore {
            #expect(globalAfter[key]?.predicted == row.predicted && globalAfter[key]?.recordedAt == row.recordedAt)
        }
        let totals = try Self.dayTotals(container, account: "work")
        for (key, row) in try Self.eodRows(container, surface: workSurface) {
            let day = String(key.split(separator: "|").last!)
            #expect(abs(row.truth - totals[day]!) < 1e-6, "\(key)")
        }
    }

    @Test func costSnapshotsCarryThePricingVersion() async throws {
        let container = try PacerStore.makeInMemoryContainer()
        try await MainActor.run {
            try Self.seed(container, days: 1...30)
            let context = ModelContext(container)
            context.insert(ClaudeCodeMeta(key: ClaudeCodeMetaKey.costRecomputeVersion, value: "17"))
            // A 7-day cycle in progress, so a rate-limit snapshot is written too.
            let reset = Self.now.addingTimeInterval(3 * 86400)
            var t = reset.addingTimeInterval(-7 * 86400), pct = 0.0
            while t <= Self.now {
                context.insert(RateLimitSample(sampledAt: t, window: "seven_day", usedPercentage: pct,
                                               resetsAt: reset, source: "oauth"))
                t = t.addingTimeInterval(3600); pct = min(99, pct + 0.5)
            }
            try context.save()
        }
        await UsageIntelligenceEngine(modelContainer: container).recompute(now: Self.now, calendar: Self.utc)

        let snaps = try ModelContext(container).fetch(FetchDescriptor<PredictionSnapshot>())
        let eod = snaps.filter { $0.surface == EngineSelfEval.surfaceEOD }
        #expect(!eod.isEmpty)
        #expect(eod.allSatisfy { $0.pricingVersion == "cost-v17" })
        let rl = snaps.filter { $0.surface.hasPrefix("rl-") }
        #expect(!rl.isEmpty)
        #expect(rl.allSatisfy { $0.pricingVersion == nil })
    }
}
