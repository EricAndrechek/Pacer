import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The rate-limit tables now hold every account's rows, so a read that forgets
/// to scope returns two logins interleaved — no crash, no empty state, just
/// someone else's number. These cover the piece every read site delegates to.
@Suite("Rate-limit reads are scoped by account")
struct LimitScopeTests {

    private static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: RateLimitSample.self, UsageLimitSample.self, ExtraUsageSample.self,
            Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// Two accounts polling at different rates, interleaved — the shape that
    /// makes an unscoped `fetchLimit` wrong.
    @MainActor
    private static func seed(_ context: ModelContext, now: Date) {
        for i in 0..<10 {
            context.insert(RateLimitSample(
                sampledAt: now.addingTimeInterval(Double(-i) * 60),
                window: RateLimitWindowName.fiveHour,
                usedPercentage: Double(i), resetsAt: nil,
                source: RateLimitSource.oauth,
                accountId: i % 2 == 0 ? "orgA" : "orgB"))
        }
        try? context.save()
    }

    @MainActor
    @Test func aScopedLimitFetchNeverReturnsAnotherAccountsRows() throws {
        let context = ModelContext(try Self.makeContainer())
        let now = Date()
        Self.seed(context, now: now)

        let a = try context.fetch(LimitScope.rateLimits(account: "orgA"))
        #expect(a.count == 5)
        #expect(a.allSatisfy { $0.accountId == "orgA" })

        // The whole point of doing this in the predicate rather than after the
        // fetch: a limit applied to an unscoped query can be entirely the
        // other account's rows.
        let newestForB = try context.fetch(LimitScope.rateLimits(account: "orgB", limit: 1))
        #expect(newestForB.first?.usedPercentage == 1)   // B's newest, not A's 0
    }

    @MainActor
    @Test func anUnscopedFetchIsEverythingSoTheFreshInstallCaseStillWorks() throws {
        let context = ModelContext(try Self.makeContainer())
        Self.seed(context, now: Date())
        #expect(try context.fetch(LimitScope.rateLimits(account: nil)).count == 10)
    }

    @MainActor
    @Test func sinceAndAccountCompose() throws {
        let context = ModelContext(try Self.makeContainer())
        let now = Date()
        Self.seed(context, now: now)
        let recent = try context.fetch(
            LimitScope.rateLimits(account: "orgA", since: now.addingTimeInterval(-3 * 60)))
        #expect(recent.count == 2)                        // i = 0, 2
        #expect(recent.allSatisfy { $0.accountId == "orgA" })
    }

    /// Two accounts can report a scoped window under the *same* identity
    /// string. Nothing but the stamp tells the rows apart, so this is the case
    /// where an unscoped read is not merely untidy but wrong.
    @MainActor
    @Test func twoAccountsSharingAScopedIdentityStayApart() throws {
        let context = ModelContext(try Self.makeContainer())
        let now = Date()
        for (org, pct) in [("orgA", 40.0), ("orgB", 88.0)] {
            context.insert(UsageLimitSample(
                sampledAt: now, identity: "weekly_scoped|fable|", kind: "weekly_scoped",
                group: "weekly", label: "Fable", percent: pct, resetsAt: nil,
                severity: "normal", isActive: true, modelId: nil,
                modelDisplayName: "Fable", surface: nil,
                source: RateLimitSource.oauth, accountId: org))
        }
        try context.save()

        let a = try context.fetch(LimitScope.usageLimits(account: "orgA"))
        #expect(a.map(\.percent) == [40.0])
        let b = try context.fetch(LimitScope.usageLimits(account: "orgB"))
        #expect(b.map(\.percent) == [88.0])
    }

    /// The engine resolves its account from the store rather than from App
    /// Group defaults — self-contained, and nil on a store with no accounts.
    @MainActor
    @Test func activeAccountResolvesFromTheStore() throws {
        let context = ModelContext(try Self.makeContainer())
        #expect(Account.activeId(in: context) == nil)

        context.insert(Account(id: "orgA", organizationId: "orgA", displayName: "A",
                               isActive: false, firstSeenAt: .distantPast, lastSeenAt: .distantPast))
        context.insert(Account(id: "orgB", organizationId: "orgB", displayName: "B",
                               isActive: true, firstSeenAt: .distantPast, lastSeenAt: .distantPast))
        try context.save()
        #expect(Account.activeId(in: context) == "orgB")
    }
}
