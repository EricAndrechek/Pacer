import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// `/v1/snapshot` — the payload every scripted consumer reads.
///
/// Two things it got wrong for a while and these cover: it reported exactly
/// two rate-limit windows when the store had been keeping N since v0.4.0, and
/// there was no way to ask it about any account but the active login.
@Suite("Snapshot payload")
struct PacerSnapshotAPITests {

    private static let work = "org-work"
    private static let home = "org-home"

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: RateLimitSample.self, UsageLimitSample.self, ExtraUsageSample.self,
            Account.self, DailyAggregate.self, AccountDailyAggregate.self,
            SessionInfo.self, AccountSessionInfo.self, ClaudeCodeMeta.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static func scoped(_ context: ModelContext, account: String, identity: String,
                               label: String, percent: Double, at: Date, resets: Date?,
                               modelName: String? = "Fable", surface: String? = nil,
                               severity: String = "normal", isActive: Bool = false) {
        context.insert(UsageLimitSample(
            sampledAt: at, identity: identity, kind: "weekly_scoped", group: "weekly",
            label: label, percent: percent, resetsAt: resets, severity: severity,
            isActive: isActive, modelId: nil, modelDisplayName: modelName, surface: surface,
            source: RateLimitSource.oauth, accountId: account))
    }

    /// Two logins, each with the fixed blocks and a scoped per-model window,
    /// plus the account-wide `limits[]` rows that duplicate 5h/7d.
    @MainActor
    private static func seed(_ context: ModelContext, now: Date) {
        context.insert(Account(id: work, organizationId: work, displayName: "Work",
                               isActive: true, firstSeenAt: .distantPast, lastSeenAt: now))
        context.insert(Account(id: home, organizationId: home, displayName: "Home",
                               isActive: false, firstSeenAt: .distantPast, lastSeenAt: now))

        let reset = now.addingTimeInterval(3600)
        for (account, five, seven) in [(work, 37.0, 21.0), (home, 2.0, 5.0)] {
            context.insert(RateLimitSample(
                sampledAt: now, window: RateLimitWindowName.fiveHour,
                usedPercentage: five, resetsAt: reset,
                source: RateLimitSource.oauth, accountId: account))
            context.insert(RateLimitSample(
                sampledAt: now, window: RateLimitWindowName.sevenDay,
                usedPercentage: seven, resetsAt: reset,
                source: RateLimitSource.oauth, accountId: account))
        }

        scoped(context, account: work, identity: "weekly_scoped|Fable|", label: "Fable",
               percent: 16, at: now, resets: reset, severity: "warning", isActive: true)
        scoped(context, account: work, identity: "weekly_scoped|Opus|", label: "Opus",
               percent: 44, at: now, resets: reset, modelName: "Opus")
        scoped(context, account: home, identity: "weekly_scoped|Fable|", label: "Fable",
               percent: 0, at: now, resets: reset)

        // Account-wide rows: same table, no model or surface. These duplicate
        // the fixed blocks and must never reach `scoped`.
        context.insert(UsageLimitSample(
            sampledAt: now, identity: "session||", kind: "session", group: "session",
            label: "All models", percent: 37, resetsAt: reset, severity: "normal",
            isActive: true, source: RateLimitSource.oauth, accountId: work))
        context.insert(UsageLimitSample(
            sampledAt: now, identity: "weekly_all||", kind: "weekly_all", group: "weekly",
            label: "All models", percent: 21, resetsAt: reset, severity: "normal",
            isActive: false, source: RateLimitSource.oauth, accountId: work))

        context.insert(ExtraUsageSample(sampledAt: now, amountCents: 250,
                                        source: RateLimitSource.oauth, accountId: work))
        context.insert(ExtraUsageSample(sampledAt: now, amountCents: 100,
                                        source: RateLimitSource.oauth, accountId: home))

        // Cost + tokens: the global table and the per-account one are siblings,
        // so "all accounts" reads the global rows rather than summing.
        let today = TokenSample.formatDate(now)
        context.insert(DailyAggregate(date: today, model: "claude-opus-5",
                                      inputTokens: 300, outputTokens: 600,
                                      cacheReadTokens: 900, totalCostUSD: 9))
        context.insert(AccountDailyAggregate(accountId: work, date: today, model: "claude-opus-5",
                                             inputTokens: 100, outputTokens: 200,
                                             cacheReadTokens: 300, cacheCreation5mTokens: 0,
                                             cacheCreation1hTokens: 0, totalCostUSD: 6))
        context.insert(AccountDailyAggregate(accountId: home, date: today, model: "claude-opus-5",
                                             inputTokens: 200, outputTokens: 400,
                                             cacheReadTokens: 600, cacheCreation5mTokens: 0,
                                             cacheCreation1hTokens: 0, totalCostUSD: 3))

        context.insert(SessionInfo(sessionId: "s-global", firstSeenAt: now, lastSeenAt: now,
                                   projectPath: "/Users/x/Code/Globex", cumulativeCostUSD: 9,
                                   cumulativeInputTokens: 300, cumulativeOutputTokens: 600,
                                   cumulativeCacheReadTokens: 900))
        context.insert(AccountSessionInfo(
            accountId: home, sessionId: "s-home",
            firstSeenAt: now, lastSeenAt: now, projectPath: "/Users/x/Code/Acme",
            ccVersion: nil, cumulativeCostUSD: 3,
            cumulativeInputTokens: 200, cumulativeOutputTokens: 400,
            cumulativeCacheReadTokens: 600, cumulativeCacheCreation5mTokens: 0,
            cumulativeCacheCreation1hTokens: 0, topModel: "claude-opus-5"))
        try? context.save()
    }

    private static func build(_ container: ModelContainer, account: String?,
                              now: Date) throws -> PacerSnapshotPayload {
        try PacerSnapshotBuilder.build(container: container, account: account,
                                       activeAccountId: work, now: now)
    }

    // MARK: - Every window, not two

    @MainActor
    @Test func scopedWindowsAreReportedAlongsideTheFixedBlocks() throws {
        let container = try Self.makeContainer()
        let now = Date()
        Self.seed(ModelContext(container), now: now)

        let limits = try Self.build(container, account: nil, now: now).limits
        #expect(limits.fiveHour?.usedPercent == 37)
        #expect(limits.sevenDay?.usedPercent == 21)
        // Ordered by identity, so a consumer diffing two responses sees a
        // stable list rather than whatever the fetch happened to return.
        #expect(limits.scoped.map(\.identity) == ["weekly_scoped|Fable|", "weekly_scoped|Opus|"])
        #expect(limits.scoped.first?.label == "Fable")
        #expect(limits.scoped.first?.group == "weekly")
        #expect(limits.scoped.first?.isActive == true)
        #expect(limits.scoped.first?.severity == "warning")
        // `all` is what a consumer iterates: fixed first, then scoped.
        #expect(limits.all.map(\.identity)
            == ["five_hour", "seven_day", "weekly_scoped|Fable|", "weekly_scoped|Opus|"])
    }

    /// `session` / `weekly_all` arrive in the same table and say the same thing
    /// as the fixed blocks. Reporting them as scoped windows would have a
    /// consumer count the 5-hour window twice.
    @MainActor
    @Test func accountWideRowsAreNotRepublishedAsScopedWindows() throws {
        let container = try Self.makeContainer()
        let now = Date()
        Self.seed(ModelContext(container), now: now)

        let limits = try Self.build(container, account: nil, now: now).limits
        #expect(!limits.scoped.contains { $0.identity.hasPrefix("session|") })
        #expect(!limits.scoped.contains { $0.identity.hasPrefix("weekly_all|") })
    }

    /// The fixed blocks carry the same identity/label/group triple a scoped
    /// window does, so `all` is one homogeneous list.
    @MainActor
    @Test func fixedBlocksCarryTheSameIdentityFieldsAsScopedOnes() throws {
        let container = try Self.makeContainer()
        let now = Date()
        Self.seed(ModelContext(container), now: now)

        let limits = try Self.build(container, account: nil, now: now).limits
        #expect(limits.fiveHour?.identity == "five_hour")
        #expect(limits.fiveHour?.label == "5-hour")
        #expect(limits.fiveHour?.group == "session")
        #expect(limits.sevenDay?.identity == "seven_day")
        #expect(limits.sevenDay?.label == "7-day")
        #expect(limits.sevenDay?.group == "weekly")
        // Not reported for a fixed block — nil means "the source carries no
        // such flag", not "false".
        #expect(limits.fiveHour?.isActive == nil)
        #expect(limits.fiveHour?.severity == nil)
    }

    // MARK: - Whose numbers

    /// Unscoped: cost and tokens cover every account, limits are the active
    /// login's. Unchanged from before `?account=` existed.
    @MainActor
    @Test func unscopedReportsGlobalCostAndTheActiveLoginsLimits() throws {
        let container = try Self.makeContainer()
        let now = Date()
        Self.seed(ModelContext(container), now: now)

        let snap = try Self.build(container, account: nil, now: now)
        #expect(snap.account == nil)
        #expect(snap.cost.todayUSD == 9)         // the global rollup, not a sum
        #expect(snap.tokens.todayTotal == 900)
        #expect(snap.limits.fiveHour?.usedPercent == 37)   // work, the active login
        #expect(snap.overageUSD == 2.5)
        #expect(snap.session?.project == "Globex")
    }

    @MainActor
    @Test func scopingToAnAccountMovesEveryNumberInThePayload() throws {
        let container = try Self.makeContainer()
        let now = Date()
        Self.seed(ModelContext(container), now: now)

        let snap = try Self.build(container, account: Self.home, now: now)
        #expect(snap.account == Self.home)
        #expect(snap.cost.todayUSD == 3)
        #expect(snap.tokens.todayInput == 200)
        #expect(snap.tokens.todayTotal == 600)
        #expect(snap.limits.fiveHour?.usedPercent == 2)
        #expect(snap.limits.sevenDay?.usedPercent == 5)
        #expect(snap.overageUSD == 1)
        #expect(snap.session?.project == "Acme")
        // The other login's scoped window is not in this account's list.
        #expect(snap.limits.scoped.map(\.identity) == ["weekly_scoped|Fable|"])
        #expect(snap.limits.scoped.first?.usedPercent == 0)
    }

    /// Session tokens exclude cache, matching `tokens.todayTotal` and the menu
    /// bar. `SessionRow.totalTokens` counts cache too, and normalising the two
    /// session tables through it would have changed a shipped number.
    @MainActor
    @Test func sessionTokensExcludeCache() throws {
        let container = try Self.makeContainer()
        let now = Date()
        Self.seed(ModelContext(container), now: now)

        #expect(try Self.build(container, account: nil, now: now).session?.tokens == 900)
        #expect(try Self.build(container, account: Self.home, now: now).session?.tokens == 600)
    }

    // MARK: - Which engine's projection

    /// The all-accounts engine fits the **active login's** rate-limit windows,
    /// so an unscoped payload — and a request for the active account — reads
    /// its outlook. Its *cost* projection blends both logins, which is why only
    /// the unscoped payload takes that half.
    @MainActor
    @Test func theActiveLoginsWindowsReadTheAllAccountsOutlook() throws {
        let container = try Self.makeContainer()
        let now = Date()
        let context = ModelContext(container)
        Self.seed(context, now: now)
        let reset = now.addingTimeInterval(3600)

        let outlook = EngineSnapshot.WindowOutlook(
            usedPct: 37, endPct: 88, endLoPct: 70, endHiPct: 99,
            crossingUnix: nil, resetsUnix: reset.timeIntervalSince1970, trajectory: [])
        let scopedOutlook = EngineSnapshot.ScopedWindowOutlook(
            identity: "weekly_scoped|Fable|", displayName: "Fable", group: "weekly",
            isActive: true,
            outlook: EngineSnapshot.WindowOutlook(
                usedPct: 16, endPct: 40, endLoPct: 30, endHiPct: 55,
                crossingUnix: nil, resetsUnix: reset.timeIntervalSince1970, trajectory: []))
        let snapshot = EngineSnapshot(generatedUnix: now.timeIntervalSince1970,
                                      fiveHour: outlook, sevenDay: nil,
                                      cost: nil, scoped: [scopedOutlook])
        context.insert(ClaudeCodeMeta(key: EngineSnapshot.metaKey(for: .allAccounts),
                                      value: snapshot.encodedJSON() ?? ""))
        try context.save()

        for account in [nil, Self.work] {
            let limits = try Self.build(container, account: account, now: now).limits
            #expect(limits.fiveHour?.projectedEndPercent == 88)
            // Scoped windows get their projection matched by identity.
            #expect(limits.scoped.first { $0.identity == "weekly_scoped|Fable|" }?
                .projectedEndPercent == 40)
        }
    }

    /// Another account's engine scope may be cold — nothing has asked for it in
    /// fifteen minutes — and then there is simply no projection. It must never
    /// borrow the all-accounts one, which describes a different login's habits.
    @MainActor
    @Test func anotherAccountNeverBorrowsTheAllAccountsProjection() throws {
        let container = try Self.makeContainer()
        let now = Date()
        let context = ModelContext(container)
        Self.seed(context, now: now)
        let reset = now.addingTimeInterval(3600)

        let snapshot = EngineSnapshot(
            generatedUnix: now.timeIntervalSince1970,
            fiveHour: EngineSnapshot.WindowOutlook(
                usedPct: 37, endPct: 88, endLoPct: 70, endHiPct: 99,
                crossingUnix: nil, resetsUnix: reset.timeIntervalSince1970, trajectory: []),
            sevenDay: nil,
            cost: EngineSnapshot.CostOutlook(
                projectedTodayUSD: 12, projectedTodayLoUSD: 10, projectedTodayHiUSD: 15,
                projectedMonthUSD: nil, projectedMonthLoUSD: nil, projectedMonthHiUSD: nil,
                pacePercentile: 0.9, paceNote: "running hot"),
            scoped: nil)
        context.insert(ClaudeCodeMeta(key: EngineSnapshot.metaKey(for: .allAccounts),
                                      value: snapshot.encodedJSON() ?? ""))
        try context.save()

        let scopedSnap = try Self.build(container, account: Self.home, now: now)
        #expect(scopedSnap.limits.fiveHour?.projectedEndPercent == nil)
        #expect(scopedSnap.cost.projectedTodayUSD == nil)
        #expect(scopedSnap.pace.percentile == nil)
        #expect(scopedSnap.dataSource.forecastFresh == false)

        // Unscoped still reads it.
        let global = try Self.build(container, account: nil, now: now)
        #expect(global.cost.projectedTodayUSD == 12)
        #expect(global.dataSource.forecastFresh == true)
    }

    @Test func engineScopeFollowsTheActiveLogin() {
        #expect(PacerSnapshotBuilder.engineScope(limitAccount: nil, activeAccountId: Self.work)
            == .allAccounts)
        #expect(PacerSnapshotBuilder.engineScope(limitAccount: Self.work, activeAccountId: Self.work)
            == .allAccounts)
        #expect(PacerSnapshotBuilder.engineScope(limitAccount: Self.home, activeAccountId: Self.work)
            == .account(Self.home))
    }

    /// A projection from a previous cycle would be nonsense, so it is attached
    /// only when the outlook's reset matches the sample's.
    @MainActor
    @Test func aProjectionFromAnotherCycleIsDropped() throws {
        let container = try Self.makeContainer()
        let now = Date()
        let context = ModelContext(container)
        Self.seed(context, now: now)

        let staleReset = now.addingTimeInterval(3600 + 600)   // 10 min off
        let snapshot = EngineSnapshot(
            generatedUnix: now.timeIntervalSince1970,
            fiveHour: EngineSnapshot.WindowOutlook(
                usedPct: 37, endPct: 88, endLoPct: 70, endHiPct: 99,
                crossingUnix: nil, resetsUnix: staleReset.timeIntervalSince1970, trajectory: []),
            sevenDay: nil, cost: nil, scoped: nil)
        context.insert(ClaudeCodeMeta(key: EngineSnapshot.metaKey(for: .allAccounts),
                                      value: snapshot.encodedJSON() ?? ""))
        try context.save()

        #expect(try Self.build(container, account: nil, now: now)
            .limits.fiveHour?.projectedEndPercent == nil)
    }

    // MARK: - Wire format

    @MainActor
    @Test func jsonCarriesScopedWindowsAndEchoesTheAccount() throws {
        let container = try Self.makeContainer()
        let now = Date()
        Self.seed(ModelContext(container), now: now)

        let scopedJSON = try Self.build(container, account: Self.home, now: now).encodedJSON()
        #expect(scopedJSON.contains("\"account\" : \"org-home\""))
        #expect(scopedJSON.contains("\"identity\" : \"weekly_scoped|Fable|\""))
        #expect(scopedJSON.contains("\"scoped\" : ["))

        // An unscoped payload carries no `account` key at all, rather than a
        // null a consumer would have to special-case.
        let globalJSON = try Self.build(container, account: nil, now: now).encodedJSON()
        #expect(!globalJSON.contains("\"account\""))
    }

    /// An account with no windows yet is an empty list, never a missing key —
    /// a consumer iterating `scoped` should not have to nil-check it.
    @MainActor
    @Test func anAccountWithNoScopedWindowsEncodesAnEmptyList() throws {
        let container = try Self.makeContainer()
        let now = Date()
        let context = ModelContext(container)
        context.insert(Account(id: Self.work, organizationId: Self.work, displayName: "Work",
                               isActive: true, firstSeenAt: .distantPast, lastSeenAt: now))
        try context.save()

        let snap = try Self.build(container, account: nil, now: now)
        #expect(snap.limits.scoped.isEmpty)
        #expect(snap.limits.all.isEmpty)
        #expect(try snap.encodedJSON().contains("\"scoped\" : ["))
    }
}
