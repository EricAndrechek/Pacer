import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The one-time pass that ends the swap era.
///
/// A non-active account's samples used to live only in `AccountUsageArchive` —
/// on the machine this was written for, 45,973 rate-limit rows spanning four
/// months, current to the minute, that no view could draw. Now that the live
/// tables are account-aware, that history belongs in them.
@Suite("Folding the archive back into the live tables")
struct ArchiveFoldTests {

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: RateLimitSample.self, UsageLimitSample.self, ExtraUsageSample.self,
            AccountUsageArchive.self, Account.self, ClaudeCodeMeta.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @MainActor
    private static func seed(_ context: ModelContext, now: Date) {
        // Inside the live window, two accounts.
        for (org, pct, ago) in [("orgA", 12.0, 60.0), ("orgB", 88.0, 120.0)] {
            context.insert(AccountUsageArchive(
                accountId: org, kind: AccountUsageArchive.kindRateLimit,
                sampledAt: now.addingTimeInterval(-ago),
                window: RateLimitWindowName.fiveHour, usedPercentage: pct,
                resetsAt: nil, source: RateLimitSource.oauth))
        }
        // A scoped row and an extra-usage row, to cover the other two kinds.
        context.insert(AccountUsageArchive(
            accountId: "orgB", kind: AccountUsageArchive.kindUsageLimit,
            sampledAt: now, usedPercentage: 44, resetsAt: nil,
            source: RateLimitSource.oauth, identity: "weekly_scoped|fable|",
            limitKind: "weekly_scoped", group: "weekly", label: "Fable",
            severity: "normal", isActive: true, modelDisplayName: "Fable"))
        context.insert(AccountUsageArchive(
            accountId: "orgB", kind: AccountUsageArchive.kindExtraUsage,
            sampledAt: now, amountCents: 250, source: RateLimitSource.oauth))
        // Outside it: the permanent record, which stays put.
        context.insert(AccountUsageArchive(
            accountId: "orgA", kind: AccountUsageArchive.kindRateLimit,
            sampledAt: now.addingTimeInterval(-40 * 86_400),
            window: RateLimitWindowName.fiveHour, usedPercentage: 5,
            resetsAt: nil, source: RateLimitSource.oauth))
        // A pre-accountId live row, as an old install would have.
        context.insert(RateLimitSample(
            sampledAt: now, window: RateLimitWindowName.sevenDay,
            usedPercentage: 33, resetsAt: nil, source: RateLimitSource.oauth))
        context.insert(Account(id: "orgA", organizationId: "orgA", displayName: "A",
                               isActive: true, firstSeenAt: .distantPast, lastSeenAt: .distantPast))
        context.insert(Account(id: "orgB", organizationId: "orgB", displayName: "B",
                               isActive: false, firstSeenAt: .distantPast, lastSeenAt: .distantPast))
        try? context.save()
    }

    @Test func recentRowsComeBackStampedAndOlderOnesStayArchived() async throws {
        let container = try Self.makeContainer()
        let now = Date()
        await MainActor.run { Self.seed(ModelContext(container), now: now) }

        await OAuthPoller.foldArchiveIntoLiveTables(container: container, now: now)

        // `@Model` types are not Sendable, so cross the actor boundary as
        // plain values.
        struct Row: Sendable { let pct: Double?; let account: String?; let cents: Int? }
        let (live, scoped, extra, archived) = await MainActor.run {
            () -> ([Row], [Row], [Row], [Row]) in
            let c = ModelContext(container)
            let rl = ((try? c.fetch(FetchDescriptor<RateLimitSample>())) ?? [])
                .map { Row(pct: $0.usedPercentage, account: $0.accountId, cents: nil) }
            let ul = ((try? c.fetch(FetchDescriptor<UsageLimitSample>())) ?? [])
                .map { Row(pct: $0.percent, account: $0.accountId, cents: nil) }
            let eu = ((try? c.fetch(FetchDescriptor<ExtraUsageSample>())) ?? [])
                .map { Row(pct: nil, account: $0.accountId, cents: $0.amountCents) }
            let ar = ((try? c.fetch(FetchDescriptor<AccountUsageArchive>())) ?? [])
                .map { Row(pct: $0.usedPercentage, account: $0.accountId, cents: nil) }
            return (rl, ul, eu, ar)
        }

        // Both accounts' recent rows are live now, and both are readable —
        // the property the swap could never satisfy.
        #expect(live.contains { $0.pct == 12 && $0.account == "orgA" })
        #expect(live.contains { $0.pct == 88 && $0.account == "orgB" })
        #expect(scoped.map(\.account) == ["orgB"])
        #expect(extra.map(\.cents) == [250])

        // The 40-day-old row is the permanent record and stays where it is.
        #expect(archived.count == 1)
        #expect(archived.first?.pct == 5)

        // The pre-accountId row is adopted by the active account, so every
        // read site can be a plain `accountId == x` with no nil clause.
        #expect(live.first { $0.pct == 33 }?.account == "orgA")
        #expect(live.allSatisfy { $0.account != nil })
    }

    /// The reason the pass repeats: a first run that silently under-drains
    /// must not leave a permanent hole.
    @Test func aSecondRunPicksUpWhatTheFirstOneMissed() async throws {
        let container = try Self.makeContainer()
        let now = Date()
        await MainActor.run { Self.seed(ModelContext(container), now: now) }
        await OAuthPoller.foldArchiveIntoLiveTables(container: container, now: now)

        // Stand in for the straggler: a recent archive row that appears after
        // the first pass has already run and written its meta key.
        await MainActor.run {
            let c = ModelContext(container)
            c.insert(AccountUsageArchive(
                accountId: "orgB", kind: AccountUsageArchive.kindRateLimit,
                sampledAt: now, window: RateLimitWindowName.sevenDay,
                usedPercentage: 61, resetsAt: nil, source: RateLimitSource.oauth))
            try? c.save()
        }

        await OAuthPoller.foldArchiveIntoLiveTables(container: container, now: now)
        let found = await MainActor.run {
            ((try? ModelContext(container).fetch(FetchDescriptor<RateLimitSample>())) ?? [])
                .contains { $0.usedPercentage == 61 && $0.accountId == "orgB" }
        }
        #expect(found)
    }

    @Test func runningTwiceMovesNothingTheSecondTime() async throws {
        let container = try Self.makeContainer()
        let now = Date()
        await MainActor.run { Self.seed(ModelContext(container), now: now) }

        await OAuthPoller.foldArchiveIntoLiveTables(container: container, now: now)
        let after = await MainActor.run {
            (try? ModelContext(container).fetch(FetchDescriptor<RateLimitSample>()))?.count ?? 0
        }
        // A second launch must not duplicate anything. The pass runs every
        // launch by design — the first real one left 1,250 rows behind — so
        // "already folded" has to be a property of the data, not a flag: once
        // a row is out of the archive there is nothing left to move.
        await OAuthPoller.foldArchiveIntoLiveTables(container: container, now: now)
        let again = await MainActor.run {
            (try? ModelContext(container).fetch(FetchDescriptor<RateLimitSample>()))?.count ?? 0
        }
        #expect(after == again)
    }
}

/// The mirror the widget process reads must track the store's flag.
///
/// Serialized and self-restoring because `PacerPreferences.store` is the
/// machine's real App Group suite — a test that left a fixture id behind would
/// scope the running app to an account with no rows.
@Suite("The scope mirror follows the store", .serialized)
struct ScopeMirrorTests {

    @Test func reconcilePointsDefaultsAtTheStoresActiveAccount() async throws {
        let container = try ModelContainer(
            for: Account.self, RateLimitSample.self, UsageLimitSample.self,
            ExtraUsageSample.self, AccountUsageArchive.self, ClaudeCodeMeta.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        await MainActor.run {
            let c = ModelContext(container)
            c.insert(Account(id: "orgA", organizationId: "orgA", displayName: "A",
                             isActive: false, firstSeenAt: .distantPast, lastSeenAt: .distantPast))
            c.insert(Account(id: "orgB", organizationId: "orgB", displayName: "B",
                             isActive: true, firstSeenAt: .distantPast, lastSeenAt: .distantPast))
            try? c.save()
        }

        let previous = UsageScope.storedActiveAccountId
        defer {
            if let previous {
                PacerPreferences.store.set(previous, forKey: UsageScope.activeKey)
            } else {
                PacerPreferences.store.removeObject(forKey: UsageScope.activeKey)
            }
        }

        // The exact drift seen in production: the `default` sentinel, which is
        // a legal account id and so cannot be rejected by shape alone.
        await MainActor.run { UsageScope.shared.setActiveAccount(Account.defaultKey) }
        await OAuthPoller.reconcileScopeMirror(container: container)

        #expect(await MainActor.run { UsageScope.shared.activeAccountId } == "orgB")
        #expect(UsageScope.storedActiveAccountId == "orgB")
    }

    /// The mirror is what *other* processes read. A reconcile that diffs
    /// against this process's own in-memory value cannot repair one that has
    /// gone missing — and an absent mirror makes every out-of-process
    /// rate-limit read unscoped, which is silently wrong rather than empty.
    @Test("a missing mirror is republished even when this process already agrees")
    func reconcileRewritesAnAbsentMirror() async throws {
        let container = try ModelContainer(
            for: Account.self, RateLimitSample.self, UsageLimitSample.self,
            ExtraUsageSample.self, AccountUsageArchive.self, ClaudeCodeMeta.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        await MainActor.run {
            let c = ModelContext(container)
            c.insert(Account(id: "orgB", organizationId: "orgB", displayName: "B",
                             isActive: true, firstSeenAt: .distantPast, lastSeenAt: .distantPast))
            try? c.save()
        }

        let previous = UsageScope.storedActiveAccountId
        defer {
            if let previous {
                PacerPreferences.store.set(previous, forKey: UsageScope.activeKey)
            } else {
                PacerPreferences.store.removeObject(forKey: UsageScope.activeKey)
            }
        }

        // In memory it is already right; on disk it is gone. This is the shape
        // a `defaults delete` under a running app leaves behind.
        await MainActor.run { UsageScope.shared.setActiveAccount("orgB") }
        PacerPreferences.store.removeObject(forKey: UsageScope.activeKey)
        #expect(UsageScope.storedActiveAccountId == nil)

        await OAuthPoller.reconcileScopeMirror(container: container)

        #expect(UsageScope.storedActiveAccountId == "orgB")
    }
}
