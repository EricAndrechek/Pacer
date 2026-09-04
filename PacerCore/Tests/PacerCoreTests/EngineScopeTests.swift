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
