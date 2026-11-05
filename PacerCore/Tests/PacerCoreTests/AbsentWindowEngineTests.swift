import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// A verified Ultra account has no 5-hour window (since 2026-10-30): its polls
/// carry `seven_day` and no `five_hour`. The engine follows the same rule the
/// surfaces do (`LimitSamplePoint.hasNoFiveHourWindow`), so it fits, grades,
/// snapshots and asks the arena about no 5-hour window for such an account,
/// whatever 5-hour history is still stored (#366). A Max account, whose polls
/// carry both, is unchanged (the golden in `EngineWindowGoldenTests` pins it).
@Suite("Engine: no work for an absent window")
struct AbsentWindowEngineTests {

    static let utc = EngineWindowGoldenTests.utc
    static let now = EngineWindowGoldenTests.now

    static func fiveHour(shiftedBack: TimeInterval = 0) -> [EngineFeatures.RateRow] {
        EngineWindowGoldenTests.rows(window: "five_hour", duration: 5 * 3600, completed: 12,
                                     stepH: 0.25, peak: 82, perStep: 5.5)
            .map { .init(window: $0.window, at: $0.at.addingTimeInterval(-shiftedBack),
                         usedPercentage: $0.usedPercentage,
                         resetsAt: $0.resetsAt?.addingTimeInterval(-shiftedBack)) }
    }

    static var sevenDay: [EngineFeatures.RateRow] {
        EngineWindowGoldenTests.rows(window: "seven_day", duration: 7 * 86400, completed: 6,
                                     stepH: 6, peak: 61, perStep: 2.2)
    }

    /// The 5-hour readings stopped two days ago; the 7-day ones run to now.
    static var ultraRows: [EngineFeatures.RateRow] { fiveHour(shiftedBack: 2 * 86400) + sevenDay }
    static var maxRows: [EngineFeatures.RateRow] { fiveHour() + sevenDay }

    static func features(_ rate: [EngineFeatures.RateRow]) -> EngineFeatures {
        EngineFeatures.build(now: now, calendar: utc, daily: [], hourly: [], rate: rate, lastArrivalAt: nil)
    }

    // MARK: - The window set

    @Test func anUltraAccountHasNoFiveHourWindow() {
        let f = Self.features(Self.ultraRows)
        #expect(f.windows.map(\.key) == ["seven_day"])
        // Its history stays in the store; the engine just has no series for it.
        #expect(f.rateLimit["five_hour"] == nil)
        #expect(f.rateLimit["seven_day"]?.isEmpty == false)
    }

    @Test func aMaxAccountKeepsBothWindowsInOrder() {
        let f = Self.features(Self.maxRows)
        #expect(f.windows.map(\.key) == ["five_hour", "seven_day"])
        #expect(f.rateLimit["five_hour"]?.isEmpty == false)
    }

    /// No reading, or a poll that carried neither window, is not an Ultra
    /// account: both windows stay, exactly as before.
    @Test func noReadingKeepsBothWindows() {
        #expect(Self.features([]).windows.map(\.key) == ["five_hour", "seven_day"])
        let onlyFive = Self.fiveHour()
        #expect(Self.features(onlyFive).windows.map(\.key) == ["five_hour", "seven_day"])
    }

    /// The rule is the latest poll's, so a 5-hour window that comes back is
    /// fitted again (an unverified Ultra account keeps a temporary cap).
    @Test func aFiveHourWindowThatReturnsIsFittedAgain() {
        let back = EngineFeatures.RateRow(window: "five_hour", at: Self.now, usedPercentage: 3,
                                          resetsAt: Self.now.addingTimeInterval(4 * 3600))
        let f = Self.features(Self.ultraRows + [back])
        #expect(f.windows.map(\.key) == ["five_hour", "seven_day"])
    }

    /// Two lanes of one poll a second apart are one batch (the shared
    /// tolerance), so jitter cannot drop the window.
    @Test func jitterInsideOnePollKeepsTheWindow() {
        var rows = Self.maxRows.filter { $0.at < Self.now.addingTimeInterval(-60) }
        rows.append(.init(window: "seven_day", at: Self.now, usedPercentage: 30, resetsAt: nil))
        rows.append(.init(window: "five_hour", at: Self.now.addingTimeInterval(-1.2), usedPercentage: 50, resetsAt: nil))
        #expect(Self.features(rows).windows.map(\.key) == ["five_hour", "seven_day"])
    }

    // MARK: - Fits and answers

    @Test func nothingIsFittedOrAnsweredForTheAbsentWindow() {
        let f = Self.features(Self.ultraRows)
        let fit = UsageIntelligenceEngine.makeFit(f)
        #expect(fit.rl["five_hour"] == nil)
        #expect(UsageIntelligenceEngine.answer(.rateLimitOutlook(.fiveHour), features: f, fit: fit).isInsufficient)
        #expect(UsageIntelligenceEngine.burnOutlook(f, fit, windowKey: "five_hour") == nil)
        #expect(UsageIntelligenceEngine.rateLimitTrajectories(f, fit, windowKey: "five_hour", accuracy: nil).isEmpty)
        let drafts = UsageIntelligenceEngine.snapshotDrafts(f, fit)
        #expect(!drafts.contains { $0.surface == EngineSelfEval.rlSurface("five_hour") })
        #expect(drafts.contains { $0.surface == EngineSelfEval.rlSurface("seven_day") })
    }

    /// The 7-day window is the same window either way: its fit and its answers
    /// do not depend on whether stale 5-hour rows were read beside it.
    @Test func theSevenDayAnswerIsUnchanged() {
        let ultra = Self.features(Self.ultraRows)
        let alone = Self.features(Self.sevenDay)
        let ultraFit = UsageIntelligenceEngine.makeFit(ultra)
        let aloneFit = UsageIntelligenceEngine.makeFit(alone)
        let a = UsageIntelligenceEngine.answer(.rateLimitOutlook(.sevenDay), features: ultra, fit: ultraFit)
        let b = UsageIntelligenceEngine.answer(.rateLimitOutlook(.sevenDay), features: alone, fit: aloneFit)
        #expect(a == b)
        #expect(UsageIntelligenceEngine.burnOutlook(ultra, ultraFit, windowKey: "seven_day")
                == UsageIntelligenceEngine.burnOutlook(alone, aloneFit, windowKey: "seven_day"))
    }

    // MARK: - What the actor writes

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: DailyAggregate.self, HourlyAggregate.self, AccountDailyAggregate.self,
            AccountHourlyAggregate.self, RateLimitSample.self, UsageLimitSample.self,
            ExtraUsageSample.self, Account.self, TokenSample.self, AccountUsageArchive.self,
            EngineEvalOutcome.self, PredictionSnapshot.self, ClaudeCodeMeta.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @MainActor
    private static func seed(_ container: ModelContainer) {
        let context = ModelContext(container)
        for (account, rows) in [("ultra", ultraRows), ("max", maxRows)] {
            for r in rows {
                context.insert(RateLimitSample(sampledAt: r.at, window: r.window, usedPercentage: r.usedPercentage,
                                               resetsAt: r.resetsAt, source: "oauth", accountId: account))
            }
        }
        try? context.save()
    }

    /// Grading rows and prediction snapshots are what the refit writes: none
    /// for the absent window, and the Max account's 5-hour ones as before.
    @Test func theRefitWritesNothingForTheAbsentWindow() async throws {
        let container = try Self.makeContainer()
        await MainActor.run { Self.seed(container) }

        let ultra = UsageIntelligenceEngine(modelContainer: container)
        await ultra.adopt(scope: .account("ultra"))
        await ultra.recompute(now: Self.now, calendar: Self.utc)
        await ultra.backfillRateLimitRecordIfNeeded(now: Self.now, calendar: Self.utc, pause: .zero)

        let max = UsageIntelligenceEngine(modelContainer: container)
        await max.adopt(scope: .account("max"))
        await max.recompute(now: Self.now, calendar: Self.utc)
        await max.backfillRateLimitRecordIfNeeded(now: Self.now, calendar: Self.utc, pause: .zero)

        #expect(await ultra.windowSpecsForProbe().map(\.key) == ["seven_day"])
        #expect(await max.windowSpecsForProbe().map(\.key) == ["five_hour", "seven_day"])
        #expect(await ultra.selfEvalAccuracy(surface: EngineSelfEval.rlSurface("five_hour")) == nil)

        let context = ModelContext(container)
        let outcomes = try context.fetch(FetchDescriptor<EngineEvalOutcome>()).map(\.surface)
        let snapshots = try context.fetch(FetchDescriptor<PredictionSnapshot>()).map(\.surface)
        let ultraFive = EngineScope.account("ultra").qualify(EngineSelfEval.rlSurface("five_hour"))
        let ultraSeven = EngineScope.account("ultra").qualify(EngineSelfEval.rlSurface("seven_day"))
        let maxFive = EngineScope.account("max").qualify(EngineSelfEval.rlSurface("five_hour"))
        #expect(!outcomes.contains(ultraFive))
        #expect(!snapshots.contains(ultraFive))
        #expect(outcomes.contains(ultraSeven))
        #expect(snapshots.contains(ultraSeven))
        // The Max account's 5-hour window is graded and recorded as before.
        #expect(outcomes.contains(maxFive))
        #expect(snapshots.contains(maxFive))
        // And the 5-hour readings themselves are all still in the store.
        let fiveRows = try context.fetchCount(FetchDescriptor<RateLimitSample>(
            predicate: #Predicate { $0.accountId == "ultra" && $0.window == "five_hour" }))
        #expect(fiveRows == Self.fiveHour().count)
    }
}
