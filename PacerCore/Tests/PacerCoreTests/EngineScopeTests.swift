import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The engine fits one series. With two accounts on a machine that series is a
/// blend of two habits, so there is one engine per scope — and the whole design
/// rests on the two never reading each other's persisted rows.
@Suite("Per-scope engines")
struct EngineScopeTests {

    // MARK: - Surface qualification

    /// `.allAccounts` has to keep writing exactly the ids it always did, or the
    /// accumulated scoreboard and the golden fixtures are orphaned.
    @Test func allAccountsQualifiesNothing() {
        #expect(EngineScope.allAccounts.qualify("eod") == "eod")
        #expect(EngineScope.allAccounts.qualify("rl-five_hour") == "rl-five_hour")
        #expect(EngineScope.allAccounts.suffix.isEmpty)
    }

    @Test func aScopedSurfaceRoundTrips() {
        let scope = EngineScope.account("org-a")
        let persisted = scope.qualify("rl-weekly_scoped|Fable|")
        #expect(persisted == "rl-weekly_scoped|Fable|#org-a")
        #expect(scope.unqualify(persisted) == "rl-weekly_scoped|Fable|")
    }

    /// The isolation the whole design depends on: neither scope may read the
    /// other's rows, in either direction.
    @Test func scopesCannotReadEachOther() {
        let a = EngineScope.account("org-a")
        let b = EngineScope.account("org-b")
        let all = EngineScope.allAccounts

        #expect(a.unqualify(b.qualify("eod")) == nil)
        #expect(b.unqualify(a.qualify("eod")) == nil)
        // An unsuffixed row is the global scope's and only the global scope's.
        #expect(a.unqualify("eod") == nil)
        #expect(all.unqualify(a.qualify("eod")) == nil)
        #expect(all.unqualify("eod") == "eod")
    }

    @Test func theSnapshotExportKeyFollowsTheSameRule() {
        #expect(EngineSnapshot.metaKey(for: .allAccounts) == EngineSnapshot.metaKey)
        #expect(EngineSnapshot.metaKey(for: .account("org-a"))
                == EngineSnapshot.metaKey + "#org-a")
    }

    // MARK: - Fitting

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: DailyAggregate.self, HourlyAggregate.self, AccountDailyAggregate.self,
            AccountHourlyAggregate.self, RateLimitSample.self, UsageLimitSample.self,
            ExtraUsageSample.self, Account.self, TokenSample.self,
            EngineEvalOutcome.self, PredictionSnapshot.self, ClaudeCodeMeta.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// Two accounts with very different histories: one long and expensive, one
    /// short and cheap. A scoped engine must see only its own.
    @MainActor
    private static func seed(_ container: ModelContainer, now: Date) {
        let context = ModelContext(container)
        let cal = Calendar.current
        func key(_ back: Int) -> String {
            TokenSample.formatDate(cal.date(byAdding: .day, value: -back, to: now)!)
        }
        // `dailyPeriods` — what the fit actually trains on — is built from the
        // hourly rollup, so both tables have to be seeded.
        func day(_ back: Int, cost: Double, account: String?) {
            let date = key(back)
            if let account {
                context.insert(AccountDailyAggregate(
                    accountId: account, date: date, model: "m",
                    inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                    cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: cost))
                for hour in 9...12 {
                    context.insert(AccountHourlyAggregate(
                        accountId: account, date: date, hour: hour, model: "m",
                        inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                        cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
                        totalCostUSD: cost / 4))
                }
            } else {
                context.insert(DailyAggregate(
                    date: date, model: "m",
                    inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
                    cacheCreation5mTokens: 0, cacheCreation1hTokens: 0, totalCostUSD: cost))
                for hour in 9...12 {
                    context.insert(HourlyAggregate(
                        date: date, hour: hour, model: "m",
                        inputTokens: 0, outputTokens: 0, totalCostUSD: cost / 4,
                        sampleCount: 1))
                }
            }
        }
        for back in 1...40 {
            day(back, cost: 10, account: "work")     // work: forty days at $10
            day(back, cost: 10, account: nil)        // and the global rollup
        }
        for back in 1...3 {
            day(back, cost: 1, account: "personal")  // personal: three days at $1
        }
        try? context.save()
    }

    @Test func aScopedEngineTrainsOnlyOnItsOwnAccount() async throws {
        let container = try Self.makeContainer()
        let now = Date()
        await MainActor.run { Self.seed(container, now: now) }

        let work = UsageIntelligenceEngine(modelContainer: container)
        await work.adopt(scope: .account("work"))
        await work.recompute(now: now)

        let personal = UsageIntelligenceEngine(modelContainer: container)
        await personal.adopt(scope: .account("personal"))
        await personal.recompute(now: now)

        // Forty days versus three — the difference the blend was hiding.
        #expect(await work.trainingDayCount() == 40)
        #expect(await personal.trainingDayCount() == 3)

        // And the ranking each would state is its own account's.
        let workRank = await work.yesterdayRank()
        #expect(workRank?.cost == 10)
        #expect(workRank?.of == 40)
        // Three days is under the notice floor, which is the honest answer for
        // an account that is three days old.
        #expect(await personal.yesterdayRank() == nil)
    }

    /// The global engine keeps reading the global rollup, so its answer is
    /// exactly what it was before scopes existed.
    @Test func theGlobalEngineIsUnchanged() async throws {
        let container = try Self.makeContainer()
        let now = Date()
        await MainActor.run { Self.seed(container, now: now) }

        let all = UsageIntelligenceEngine(modelContainer: container)
        await all.recompute(now: now)
        #expect(await all.scope == .allAccounts)
        #expect(await all.trainingDayCount() == 40)
    }

    /// Each scope's scoreboard has to accumulate independently — if the rows
    /// leaked, one account's model selection would be driven by the other's
    /// realized errors.
    @Test func scoreboardRowsDoNotLeakBetweenScopes() async throws {
        let container = try Self.makeContainer()
        let now = Date()
        await MainActor.run { Self.seed(container, now: now) }

        let work = UsageIntelligenceEngine(modelContainer: container)
        await work.adopt(scope: .account("work"))
        await work.recompute(now: now)

        let surfaces = await MainActor.run {
            ((try? ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>())) ?? [])
                .map(\.surface)
        }
        #expect(!surfaces.isEmpty)
        #expect(surfaces.allSatisfy { $0.hasSuffix("#work") })
    }
}

/// The diurnal model learns its accrual *shape* from completed cycles. With
/// none it is the activity prior alone, and on a thin history that prior is
/// zero in almost every (weekday, hour) cell — so integrating it forward
/// projects no growth at all.
///
/// Seen on a two-day-old account: the weekly window projected 88% → 88% flat
/// while the same window under a scope with more history projected
/// 88% → 92% → 95% → 99%. A model with nothing to say should not compete.
@Suite("The diurnal model needs a completed cycle")
struct DiurnalRosterGateTests {

    private func features(cycles: Int, now: Date) -> EngineFeatures {
        let duration: TimeInterval = 7 * 86_400
        var samples: [(at: Date, usedPercentage: Double, resetsAt: Date)] = []
        // `cycles` complete cycles behind us, then a partial one.
        for c in stride(from: cycles, through: 1, by: -1) {
            let resets = now.addingTimeInterval(-Double(c - 1) * duration - 3600)
            for step in 0..<12 {
                samples.append((at: resets.addingTimeInterval(-duration + Double(step) * duration / 12),
                                usedPercentage: Double(step) * 8, resetsAt: resets))
            }
        }
        let currentReset = now.addingTimeInterval(duration / 2)
        for step in 0..<6 {
            samples.append((at: now.addingTimeInterval(-Double(6 - step) * 3600),
                            usedPercentage: Double(step) * 10, resetsAt: currentReset))
        }
        return EngineFeatures.build(
            now: now, calendar: .current,
            daily: [], hourly: [], rate: samples.map {
                .init(window: RateLimitWindowName.sevenDay, at: $0.at,
                      usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt)
            },
            lastArrivalAt: now, scoped: [])
    }

    private func rosterIds(cycles: Int) -> [String] {
        let now = Date()
        let fit = UsageIntelligenceEngine.makeFit(features(cycles: cycles, now: now))
        return fit.rl[RateLimitWindowName.sevenDay]?.roster.map(\.id) ?? []
    }

    @Test func itSitsOutWithNoCompletedCycle() {
        let ids = rosterIds(cycles: 0)
        #expect(!ids.isEmpty)                      // the simple models still compete
        #expect(!ids.contains("diurnal-rate"))
    }

    @Test func itCompetesOnceThereIsOne() {
        #expect(rosterIds(cycles: 3).contains("diurnal-rate"))
    }
}


/// Two failures found the day Anthropic reset the windows, both of which made
/// a freshly-reset window project nonsense.
@Suite("Early-cycle rate-limit projections")
struct EarlyCycleProjectionTests {

    private let duration: TimeInterval = 7 * 86_400

    /// A rate table with uniform activity — the shape is irrelevant here, only
    /// how much of it has been observed.
    private func flatModel() -> DiurnalBurnModel {
        DiurnalBurnModel(rate: Array(repeating: Array(repeating: 1.0, count: 24), count: 7))
    }

    private func cycle(elapsed: TimeInterval, used: Double) -> BurnTrajectory.PartialCycle {
        let now = Date()
        let start = now.addingTimeInterval(-elapsed)
        return BurnTrajectory.PartialCycle(
            samples: [.init(at: now, usedPercentage: used)],
            now: now, cycleStart: start, resetsAt: start.addingTimeInterval(duration))
    }

    /// `level` is `used / expected-so-far`, and just after a reset that
    /// denominator is nearly zero — so 3% burned in the first hours scaled the
    /// whole forward shape enormously. Observed live: a 7-day window three
    /// hours in, 3% used, projecting **3% → 100%**.
    @Test func theDiurnalModelDeclinesTooEarlyInACycle() {
        let model = flatModel()
        // Three hours into a seven-day window — well under the 5% floor.
        #expect(model.fit(cycle(elapsed: 3 * 3600, used: 3)) == nil)
    }

    @Test func itFitsOnceEnoughOfTheCycleHasHappened() {
        let model = flatModel()
        // A day and a half in — comfortably past the floor.
        let projection = model.fit(cycle(elapsed: 1.5 * 86_400, used: 20))
        #expect(projection != nil)
    }

    /// The floor is a share of the cycle, not a fixed time, so it scales to the
    /// 5-hour window too.
    @Test func theFloorIsRelativeToTheWindow() {
        let model = DiurnalBurnModel(
            rate: Array(repeating: Array(repeating: 1.0, count: 24), count: 7))
        let now = Date()
        let short: TimeInterval = 5 * 3600
        func fiveHourCycle(elapsed: TimeInterval) -> BurnTrajectory.PartialCycle {
            let start = now.addingTimeInterval(-elapsed)
            return BurnTrajectory.PartialCycle(
                samples: [.init(at: now, usedPercentage: 10)],
                now: now, cycleStart: start, resetsAt: start.addingTimeInterval(short))
        }
        #expect(model.fit(fiveHourCycle(elapsed: 60)) == nil)          // one minute in
        #expect(model.fit(fiveHourCycle(elapsed: 2 * 3600)) != nil)    // two hours in
    }
}


/// The scoreboard names a model from the accumulated record; the roster is what
/// can actually fit *this* cycle. They disagree whenever a model declines — the
/// diurnal one early in a cycle, all of them at 0% — and when they did, nothing
/// was marked selected and the chart drew whatever came first in roster order.
@Suite("Selecting a trajectory that is actually present")
struct TrajectorySelectionFallbackTests {

    private func features(now: Date) -> EngineFeatures {
        let duration: TimeInterval = 7 * 86_400
        let resets = now.addingTimeInterval(duration * 0.9)
        let start = resets.addingTimeInterval(-duration)
        var rows: [EngineFeatures.RateRow] = []
        for step in 0...8 {
            rows.append(.init(window: RateLimitWindowName.sevenDay,
                              at: start.addingTimeInterval(Double(step) * 1200),
                              usedPercentage: Double(step) * 0.5, resetsAt: resets))
        }
        return EngineFeatures.build(now: now, calendar: .current, daily: [], hourly: [],
                                    rate: rows, lastArrivalAt: now, scoped: [])
    }

    @Test func somethingIsAlwaysSelected() {
        let now = Date()
        let f = features(now: now)
        var fit = UsageIntelligenceEngine.makeFit(f)
        // The scoreboard picked a model that cannot fit this cycle.
        fit.rl[RateLimitWindowName.sevenDay]?.selectedId = "a-model-that-declined"

        let scored = UsageIntelligenceEngine.rateLimitTrajectories(
            f, fit, windowKey: RateLimitWindowName.sevenDay, accuracy: nil)
        #expect(!scored.isEmpty)
        #expect(scored.filter(\.isSelected).count == 1)
    }

    /// And it is the best one available, not the first in roster order.
    @Test func theStandInIsTheMostAccurateThatFitted() {
        let now = Date()
        let f = features(now: now)
        var fit = UsageIntelligenceEngine.makeFit(f)
        fit.rl[RateLimitWindowName.sevenDay]?.selectedId = nil

        let ids = UsageIntelligenceEngine.rateLimitTrajectories(
            f, fit, windowKey: RateLimitWindowName.sevenDay, accuracy: nil).map(\.modelId)
        let scored = UsageIntelligenceEngine.rateLimitTrajectories(
            f, fit, windowKey: RateLimitWindowName.sevenDay, accuracy: nil)
        // With no accuracy record every error is `.infinity`, so the tie-break
        // is complexity — the simplest model, not `ids.first`.
        let chosen = scored.first(where: \.isSelected)
        #expect(chosen != nil)
        #expect(chosen?.complexity == scored.map(\.complexity).min())
        #expect(ids.count > 1)
    }
}
