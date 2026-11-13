import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// #404: a refit cycle racing the warm-up `EngineHost.engine(for:)` starts.
///
/// A view or the HTTP API creates an account's engine, and its warm-up fit
/// runs on a detached task. A refit cycle that starts meanwhile finds the
/// engine already made (`keepFitted` skips it) and fits it as well. When the
/// engine learned its scope from the warm-up's first message, a refit that got
/// there first fitted it as all accounts, which fits no rate limits while an
/// account is active (`fitsRateLimits`, #303): that fit did not count toward
/// the two refits a hit claim needs, and the chip said "may hit limit" a cycle
/// longer than it should. The engine is now built in its scope.
///
/// Each ordering is forced: the warm-up is held at its start
/// (`EngineHost.warmUpGate`) while the refit runs, or let finish first, or
/// released with the refit in flight. The fixture is `RenderEngineSettleTests`',
/// whose active account has a weekly hit to claim.
@Suite("Engine warm-up: a refit fits a new engine in its own scope")
@MainActor
struct EngineWarmUpOrderTests {

    static let acme = RenderEngineSettleTests.acme
    static let globex = RenderEngineSettleTests.globex

    /// Holds every warm-up that reaches it until `open()`.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    if isOpen { return true }
                    waiting.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let resumed = lock.withLock {
                isOpen = true
                defer { waiting = [] }
                return waiting
            }
            for continuation in resumed { continuation.resume() }
        }
    }

    /// The refit cycle's engine steps, as `AppBackgroundService` runs them:
    /// the account list to the host, then every live engine fitted on a
    /// detached task, concurrently.
    static func refitCycle(_ host: EngineHost, now: Date) async {
        host.keepFitted(accounts: [acme, globex], active: acme)
        let live = host.live
        await Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for entry in live {
                    group.addTask { await entry.engine.recompute(now: now) }
                }
            }
        }.value
    }

    enum Order: String, CaseIterable, CustomTestStringConvertible {
        /// The refit reaches the new engine while its warm-up has not started.
        case refitFirst
        /// The warm-up finishes before the refit starts.
        case warmUpFirst
        /// The warm-up is let go with the refit already in flight.
        case together

        var testDescription: String { rawValue }
    }

    @Test(arguments: Order.allCases)
    func aRefitRacingAWarmUpFitsTheEngineInItsScope(_ order: Order) async throws {
        let now = Date()
        let container = try RenderEngineSettleTests.seededContainer(now: now)
        let host = EngineHost(container: container,
                              preseeded: [.allAccounts: UsageIntelligenceEngine(modelContainer: container)])
        let gate = Gate()
        if order != .warmUpFirst { host.warmUpGate = { await gate.wait() } }

        // A view asks for the active account's engine before the cycle.
        let engine = host.engine(forAccount: Self.acme)

        switch order {
        case .refitFirst:
            // Nothing has reached the engine yet, and it is already its own.
            #expect(await engine.scope == .account(Self.acme))
            await Self.refitCycle(host, now: now)
            // The refit's fit alone: the account's, so it fitted the weekly
            // window. As all accounts it would have fitted none.
            #expect(await engine.burnOutlook(window: .sevenDay) != nil)
            gate.open()
            await host.warmUpsFinished()
        case .warmUpFirst:
            await host.warmUpsFinished()
            await Self.refitCycle(host, now: now)
        case .together:
            let refit = Task { @MainActor in await Self.refitCycle(host, now: now) }
            await Task.yield()
            gate.open()
            await refit.value
            await host.warmUpsFinished()
        }

        #expect(await engine.scope == .account(Self.acme))
        #expect(host.rateLimitEngine === engine)
        // Both fits were the account's, so the claim held on two refits.
        let chip = try #require(await RenderEngineSettleTests.weeklyChip(engine, now: now))
        #expect(RenderEngineSettleTests.isClaimed(chip), "\(order): \(chip.text)")
    }

    /// `keepFitted` builds the engines it adds in their scopes too, without a
    /// hop to each one from the main actor.
    @Test func keepFittedBuildsEnginesInTheirScopes() async throws {
        let container = try RenderEngineSettleTests.seededContainer(now: Date())
        let host = EngineHost(container: container,
                              preseeded: [.allAccounts: UsageIntelligenceEngine(modelContainer: container)])
        host.keepFitted(accounts: [Self.acme, Self.globex], active: Self.acme)
        for (scope, engine) in host.all {
            #expect(await engine.scope == scope)
        }
    }
}
