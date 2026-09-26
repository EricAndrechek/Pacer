import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// `EngineHost.live` decides what gets refitted every cycle, and that is the
/// most expensive recurring thing the app does. Every account the store knows
/// is refitted whatever is on screen (`keepFitted(accounts:)`); a scope outside
/// that list is refitted only for a while after something asks for it.
///
/// Every host here is **preseeded**, which is not incidental: the ordinary
/// `init` warms `.allAccounts` on a detached task, and that task outlives an
/// in-memory container the test has finished with — a CoreData abort rather
/// than a failure. Preseeding exercises the scope bookkeeping, which is what
/// these tests are about, without starting a fit.
@Suite("Which engine scopes stay worth refitting", .serialized)
@MainActor
struct EngineHostLiveScopesTests {

    private func makeHost(accounts: [String] = []) throws -> EngineHost {
        let container = try ModelContainer(
            for: Account.self, RateLimitSample.self, UsageLimitSample.self,
            ExtraUsageSample.self, AccountUsageArchive.self, ClaudeCodeMeta.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var seeded: [EngineScope: UsageIntelligenceEngine] = [
            .allAccounts: UsageIntelligenceEngine(modelContainer: container)
        ]
        for id in accounts {
            seeded[.account(id)] = UsageIntelligenceEngine(modelContainer: container)
        }
        return EngineHost(container: container, preseeded: seeded)
    }

    @Test("all-accounts is always live, even untouched")
    func globalAlwaysLive() throws {
        let host = try makeHost()
        #expect(host.live.map(\.scope) == [.allAccounts])
    }

    /// A warm engine nobody has asked for is not automatically a refit target —
    /// that is exactly the permanent cost being removed.
    @Test("an unasked scope outside the known accounts is not refitted")
    func warmButUnaskedIsNotLive() throws {
        let host = try makeHost(accounts: ["orgA"])
        #expect(host.live.map(\.scope) == [.allAccounts])
        #expect(Set(host.all.map(\.scope)) == [.allAccounts, .account("orgA")])
    }

    @Test("asking for a scope makes it live")
    func askingMakesLive() throws {
        let host = try makeHost(accounts: ["orgA"])
        _ = host.engine(forAccount: "orgA")
        #expect(Set(host.live.map(\.scope)) == [.allAccounts, .account("orgA")])
    }

    @Test("outside the known accounts, a scope idle past the grace drops out; asking revives it")
    func idleScopeDropsOut() throws {
        let host = try makeHost(accounts: ["orgA"])
        _ = host.engine(forAccount: "orgA")
        host.markAskedForTesting(.account("orgA"),
                                 at: Date().addingTimeInterval(-EngineHost.idleScopeGrace - 60))
        #expect(host.live.map(\.scope) == [.allAccounts])
        // Kept warm, just not refitted — flicking back must stay free.
        #expect(Set(host.all.map(\.scope)) == [.allAccounts, .account("orgA")])
        _ = host.engine(forAccount: "orgA")
        #expect(Set(host.live.map(\.scope)) == [.allAccounts, .account("orgA")])
    }

    /// A forecast shouldn't depend on what's on screen: an account nobody has
    /// looked at for hours is refitted like any other.
    @Test("every known account is refitted, asked for or not")
    func knownAccountsAreAlwaysLive() async throws {
        let host = try makeHost(accounts: ["orgA"])
        await host.keepFitted(accounts: ["orgA", "orgB"])
        let everyone: Set<EngineScope> = [.allAccounts, .account("orgA"), .account("orgB")]
        #expect(Set(host.live.map(\.scope)) == everyone)
        host.markAskedForTesting(.account("orgA"),
                                 at: Date().addingTimeInterval(-EngineHost.idleScopeGrace - 60))
        #expect(Set(host.live.map(\.scope)) == everyone)
        // An account that leaves the list falls back to the ask rule.
        await host.keepFitted(accounts: ["orgB"])
        #expect(Set(host.live.map(\.scope)) == [.allAccounts, .account("orgB")])
    }

    /// An engine created for the refit has to know its scope before the refit
    /// reaches it; fitted unscoped, it would forecast every account's usage
    /// under one account's name.
    @Test("an engine created for a known account is scoped before anything fits it")
    func createdEnginesAreScoped() async throws {
        let host = try makeHost()
        await host.keepFitted(accounts: ["orgB"])
        let engine = try #require(host.all.first { $0.scope == .account("orgB") }?.engine)
        #expect(await engine.scope == .account("orgB"))
    }
}
