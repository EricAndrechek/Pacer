import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// The app's wiring (`AppBackgroundService.arenaRuntime`), against a real
/// `EngineHost`: the scorer's batches reach the account's engine, and live
/// projections landing redraw it. The closures below are the app's, word for
/// word, so this also holds them to PacerCore's types.
@Suite("Arena runtime: the app's wiring", .serialized)
@MainActor
struct RuntimeWiringTests {

    static func appRuntime(container: ModelContainer, engines: EngineHost, roster: ArenaRoster,
                           config: ArenaRecordScorer.Config, redraws: RuntimeEngineTests.Landed) -> ArenaRuntime {
        ArenaRuntime(
            container: container, roster: roster, config: config,
            onRecordLanded: { account, news in
                let engine = await MainActor.run {
                    engines.all.first { $0.scope == .account(account) }?.engine
                }
                _ = await engine?.ingestArenaOutcomes(news)
            },
            onLiveLanded: { accounts in
                let targets = await MainActor.run {
                    engines.all.filter { $0.scope.accountId.map { accounts.contains($0) } ?? false }.map(\.engine)
                }
                var changed = false
                for engine in targets {
                    if await engine.refreshArenaResolution() { changed = true }
                }
                guard changed else { return }
                redraws.live(accounts)
            })
    }

    @Test func batchesReachTheAccountsEngineAndLiveProjectionsRedrawIt() async throws {
        let container = try RuntimeEngineTests.seeded()
        let engines = EngineHost(container: container)
        let account = RuntimeEngineTests.account
        await engines.keepFitted(accounts: [account], active: account)
        let redraws = RuntimeEngineTests.Landed()
        let runtime = Self.appRuntime(container: container, engines: engines,
                                      roster: ArenaRoster(registry: [RuntimeEngineTests.oracle]),
                                      config: RuntimeEngineTests.noSleep(), redraws: redraws)
        let link = runtime.link
        for entry in engines.all { await entry.engine.adopt(arena: link) }
        let engine = engines.engine(for: .account(account))
        await engine.recompute(now: RuntimeEngineTests.now)

        _ = await runtime.scorer.pass(accounts: [account], now: RuntimeEngineTests.now)
        await engine.recompute(now: RuntimeEngineTests.now)
        #expect(await engine.resolvedMethod(windowKey: "five_hour").selected == "test-oracle")
        await runtime.live.settle()
        // Give the landed callback its hop back.
        for _ in 0..<100 where redraws.liveAccounts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(redraws.liveAccounts == [[account]])
        #expect(await engine.resolvedMethod(windowKey: "five_hour").resolved == "test-oracle")
        await runtime.stop()
    }
}
