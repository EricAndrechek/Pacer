import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// `EngineHost.live` decides what gets refitted every cycle, and that is the
/// most expensive recurring thing the app does — measured at a median of 15.9s
/// per cycle on a two-account store, half an hour of work across a day. Before
/// this, asking for a scope once kept it refitting for the life of the process.
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
    @Test("a warm but unasked scope is not refitted")
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

    @Test("a scope idle past the grace period drops out, and asking revives it")
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
}
