import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// "All accounts" rate-limit answers are the active login's, from its own
/// engine (#303): the all-accounts engine fits none while an account is
/// active, so it can't keep a record folding every account into one.
@Suite("Rate-limit routing to the active account")
@MainActor
struct RLActiveAccountRoutingTests {

    static let now = Date(timeIntervalSince1970: 1_752_000_000)
    static let work = "org-work", home = "org-home"

    /// Two accounts, `work` active, each with a few completed 5-hour cycles and
    /// a live one.
    static func seededContainer(withAccounts: Bool = true) throws -> ModelContainer {
        let container = try PacerStore.makeInMemoryContainer()
        let ctx = ModelContext(container)
        if withAccounts {
            for (id, active) in [(work, true), (home, false)] {
                ctx.insert(Account(id: id, organizationId: id, displayName: id, isActive: active,
                                   firstSeenAt: now.addingTimeInterval(-86400 * 3), lastSeenAt: now))
            }
        }
        let duration: TimeInterval = 5 * 3600
        for (acct, step) in [(work, 3.0), (home, 1.5)] {
            for c in 0..<5 {
                let start = now.addingTimeInterval(-Double(5 - c) * duration + 3600)
                let reset = start.addingTimeInterval(duration)
                var t = start, pct = 0.0
                while t <= min(reset, now) {
                    ctx.insert(RateLimitSample(sampledAt: t, window: "five_hour", usedPercentage: min(95, pct),
                                               resetsAt: reset, source: "oauth",
                                               accountId: withAccounts ? acct : nil))
                    t = t.addingTimeInterval(600); pct += step
                }
            }
            if !withAccounts { break }
        }
        try ctx.save()
        return container
    }

    @Test func allAccountsRateLimitAnswersAreTheActiveAccountsOwn() async throws {
        let container = try Self.seededContainer()
        let host = EngineHost(container: container,
                              preseeded: [.allAccounts: UsageIntelligenceEngine(modelContainer: container)])
        await host.keepFitted(accounts: [Self.work, Self.home], active: Self.work)
        for (_, engine) in host.all { await engine.recompute(now: Self.now) }

        let routed = host.rateLimitEngine
        #expect(routed === host.engine(for: .account(Self.work)))
        let viaRoute = await routed.burnOutlook(window: .fiveHour)
        let viaAccount = await host.engine(for: .account(Self.work)).burnOutlook(window: .fiveHour)
        #expect(viaRoute != nil)
        #expect(viaRoute?.usedPct == viaAccount?.usedPct)
        #expect(viaRoute?.method == viaAccount?.method)
        #expect(viaRoute?.projectedFullAt == viaAccount?.projectedFullAt)
        // The all-accounts engine fits none, so it can't contradict the column.
        #expect(await host.global.burnOutlook(window: .fiveHour) == nil)
    }

    @Test func theAllAccountsEngineWritesNoUnscopedRateLimitRecord() async throws {
        let container = try Self.seededContainer()
        let global = UsageIntelligenceEngine(modelContainer: container)
        await global.recompute(now: Self.now)
        await global.recompute(now: Self.now)      // and not on the backfill refit either
        let rows = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>())
        #expect(!rows.contains { $0.surface.hasPrefix("rl-") && !$0.surface.contains("#") })

        let work = UsageIntelligenceEngine(modelContainer: container)
        await work.adopt(scope: .account(Self.work))
        await work.recompute(now: Self.now)
        let scoped = try ModelContext(container).fetch(FetchDescriptor<EngineEvalOutcome>())
        #expect(scoped.contains { $0.surface.hasPrefix("rl-") && $0.surface.hasSuffix(Self.work) })
    }

    @Test func withNoAccountTheAllAccountsEngineStillFitsRateLimits() async throws {
        let container = try Self.seededContainer(withAccounts: false)
        let global = UsageIntelligenceEngine(modelContainer: container)
        await global.recompute(now: Self.now)
        #expect(await global.burnOutlook(window: .fiveHour) != nil)
        let host = EngineHost(container: container, preseeded: [.allAccounts: global])
        #expect(host.rateLimitEngine === global)
    }

    @Test func anActivationReRoutesAtOnce() async throws {
        let container = try Self.seededContainer()
        // The preseeded host installs no activation observer: the plain one
        // listens on the shared NotificationCenter, where the poller tests
        // running in parallel post real activations ("orgA") and re-routed
        // this host mid-test. The handler itself is called directly below.
        let host = EngineHost(container: container,
                              preseeded: [.allAccounts: UsageIntelligenceEngine(modelContainer: container)])
        await host.keepFitted(accounts: [Self.work, Self.home], active: Self.work)
        #expect(host.rateLimitEngine === host.engine(for: .account(Self.work)))
        host.activeAccountDidChange(to: Self.home)
        #expect(host.activeAccountId == Self.home)
        #expect(host.rateLimitEngine === host.engine(for: .account(Self.home)))
    }

    @Test func theRuleItself() {
        #expect(!UsageIntelligenceEngine.fitsRateLimits(scope: .allAccounts, activeAccountId: Self.work))
        #expect(UsageIntelligenceEngine.fitsRateLimits(scope: .allAccounts, activeAccountId: nil))
        #expect(UsageIntelligenceEngine.fitsRateLimits(scope: .account(Self.work), activeAccountId: Self.work))
    }
}
