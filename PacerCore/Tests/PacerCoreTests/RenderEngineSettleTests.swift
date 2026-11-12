import Foundation
import SwiftData
import Testing
@testable import PacerCore

/// The README screenshots' weekly chip flipped between "limit in 3 days" and
/// "may hit limit in 3 days" from run to run, with nothing else changed
/// (#396). The data and the clock were pinned; what moved was the order two
/// calls reached the active account's engine: the render's direct refit and
/// the warm-up `EngineHost.engine(for:)` starts on a detached task. Whichever
/// won decided whether the hit claim had held on one refit or two.
///
/// The fixture is the README seed's rate limits in shape
/// (`ScreenshotMode.seedRateLimits`, which lives in the app target): two
/// accounts, the active one 57% into a weekly cycle that ends with a steep
/// push to 65%, sampled every five minutes, plus its 5-hour window.
@Suite("Headless render: engines settle to one forecast")
@MainActor
struct RenderEngineSettleTests {

    nonisolated static let acme = "org-acme", globex = "org-globex"
    nonisolated static let week: TimeInterval = 7 * 86_400

    /// Built around the real clock, because a warm-up `engine(for:)` starts
    /// fits at `Date()`; in the screenshot run that clock is pinned, so every
    /// fit sees the same instant. Here they are milliseconds apart, which moves
    /// nothing a chip says about a crossing days away.
    nonisolated static func seededContainer(now: Date) throws -> ModelContainer {
        let container = try PacerStore.makeInMemoryContainer()
        let ctx = ModelContext(container)
        for (id, active) in [(acme, true), (globex, false)] {
            ctx.insert(Account(id: id, organizationId: id, displayName: id, isActive: active,
                               firstSeenAt: now.addingTimeInterval(-90 * 86_400),
                               lastSeenAt: active ? now : now.addingTimeInterval(-25 * 60)))
        }
        func seed(_ window: String, account: String, resetsIn: TimeInterval, duration: TimeInterval,
                  every step: TimeInterval = 5 * 60, keyframes: [(Double, Double)]) {
            let reset = now.addingTimeInterval(resetsIn)
            let start = reset.addingTimeInterval(-duration)
            var t = start
            while t <= now {
                ctx.insert(RateLimitSample(
                    sampledAt: t, window: window,
                    usedPercentage: interpolate(keyframes, at: t.timeIntervalSince(start) / duration),
                    resetsAt: reset, source: "oauth", accountId: account))
                t = t.addingTimeInterval(step)
            }
        }
        // The README's weekly story: ahead early, a midweek lull, a late push.
        seed("seven_day", account: acme, resetsIn: 3 * 86_400, duration: week,
             keyframes: [(0, 0), (0.08, 14), (0.18, 29), (0.26, 34), (0.36, 36),
                         (0.46, 39), (0.52, 50), (0.55, 58), (0.57, 65)])
        seed("five_hour", account: acme, resetsIn: 2 * 3_600, duration: 5 * 3_600,
             keyframes: [(0, 0), (0.12, 6), (0.25, 12), (0.38, 17), (0.50, 22), (0.56, 26), (0.60, 32)])
        // The other account: a quiet week with nothing to claim, sampled
        // hourly only to keep its fits cheap.
        seed("seven_day", account: globex, resetsIn: 2 * 86_400, duration: week, every: 3_600,
             keyframes: [(0, 0), (0.72, 30)])
        try ctx.save()
        return container
    }

    nonisolated static func interpolate(_ kf: [(Double, Double)], at x: Double) -> Double {
        guard let first = kf.first, let last = kf.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for j in 1..<kf.count where x <= kf[j].0 {
            let (x0, y0) = kf[j - 1], (x1, y1) = kf[j]
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        }
        return last.1
    }

    /// The weekly chip as the pace card and the menu bar word it.
    nonisolated static func weeklyChip(_ engine: UsageIntelligenceEngine, now: Date) async -> ForecastChip? {
        guard let outlook = await engine.burnOutlook(window: .sevenDay) else { return nil }
        let end = await engine.ask(.rateLimitOutlook(.sevenDay))
        return ForecastChip.make(outlook: outlook, endEstimate: end, duration: week,
                                 usedPct: outlook.usedPct, now: now)
    }

    nonisolated static func isClaimed(_ chip: ForecastChip) -> Bool {
        if case .limit = chip.kind { return true }
        return false
    }

    /// The mechanism, with each interleaving forced. The render created the
    /// account's engine with `engine(for:)` (whose detached warm-up adopts the
    /// scope, then fits) and fitted it once directly. Same data, same clock,
    /// same calls; only the order the engine received them in differs. Off
    /// the main actor: nothing here needs it, and a fit awaited from it runs
    /// on the main thread, holding up every other main-actor test.
    @Test nonisolated func theOldRenderWarmUpsChipDependedOnWhichCallReachedTheEngineFirst() async throws {
        // The warm-up's adopt lands first: both fits are the account's, the
        // claim holds on two refits and is confirmed.
        let now = Date()
        let adoptFirst = UsageIntelligenceEngine(modelContainer: try Self.seededContainer(now: now))
        await adoptFirst.adopt(scope: .account(Self.acme))   // warm-up
        await adoptFirst.recompute(now: now)                 // the render's direct fit
        await adoptFirst.recompute(now: now)                 // warm-up
        let confirmed = try #require(await Self.weeklyChip(adoptFirst, now: now))

        // The direct fit overtakes the adopt and fits the engine as all
        // accounts, which fits no rate limits while an account is active. The
        // warm-up's fit is the only one the claim streak counts.
        let overtaken = UsageIntelligenceEngine(modelContainer: try Self.seededContainer(now: now))
        await overtaken.recompute(now: now)                  // the render's direct fit, unscoped
        await overtaken.adopt(scope: .account(Self.acme))    // warm-up
        await overtaken.recompute(now: now)                  // warm-up
        let hedged = try #require(await Self.weeklyChip(overtaken, now: now))
        let withheld = try #require(await overtaken.burnOutlook(window: .sevenDay)).hitWithheld

        #expect(Self.isClaimed(confirmed))
        #expect(!Self.isClaimed(hedged))
        #expect(withheld == .unconfirmed)
        // The two README pictures: one word apart, with the same crossing.
        #expect(hedged.text == "may hit " + confirmed.text)
    }

    /// What can already have happened to the engines when the render settles
    /// them.
    enum Before: String, CaseIterable, CustomTestStringConvertible {
        /// No account engine yet.
        case nothing
        /// A view asked for the account first: its warm-up is in flight.
        case aViewAsked
        /// The removed render code: `engine(for:)` and one direct refit per
        /// account, racing each warm-up exactly as the README run did.
        case theOldRenderWarmUp
        /// An engine an overtaking fit left in the all-accounts scope, with no
        /// warm-up behind it to adopt the account's.
        case anUnscopedFit
        /// Known and scoped by `keepFitted`, never fitted.
        case scopedNeverFitted

        var testDescription: String { rawValue }
    }

    @Test(arguments: Before.allCases)
    func aSettledRenderClaimsTheWeeklyHitWhateverRanBefore(_ before: Before) async throws {
        var texts: Set<String> = []
        // Each pass lets whatever is in flight run a different distance ahead
        // of the settle: not at all, one yield, a moment, part of a fit.
        for pass in 0..<4 {
            let now = Date()
            let container = try Self.seededContainer(now: now)
            var preseeded: [EngineScope: UsageIntelligenceEngine] = [
                .allAccounts: UsageIntelligenceEngine(modelContainer: container)
            ]
            if before == .anUnscopedFit {
                let stray = UsageIntelligenceEngine(modelContainer: container)
                await Task.detached { await stray.recompute(now: now) }.value
                preseeded[.account(Self.acme)] = stray
            }
            let host = EngineHost(container: container, preseeded: preseeded)
            switch before {
            case .nothing, .anUnscopedFit:
                break
            case .aViewAsked:
                _ = host.engine(forAccount: Self.acme)
            case .theOldRenderWarmUp:
                for id in [Self.acme, Self.globex] {
                    await host.engine(forAccount: id).recompute(now: now)
                }
            case .scopedNeverFitted:
                await host.keepFitted(accounts: [Self.acme, Self.globex], active: Self.acme)
            }
            switch pass {
            case 1: await Task.yield()
            case 2: try await Task.sleep(for: .milliseconds(2))
            case 3: try await Task.sleep(for: .milliseconds(40))
            default: break
            }

            await host.settleForRender(accounts: [Self.acme, Self.globex], active: Self.acme, now: now)

            #expect(host.rateLimitEngine === host.engine(for: .account(Self.acme)))
            let chip = try #require(await Self.weeklyChip(host.rateLimitEngine, now: now))
            #expect(Self.isClaimed(chip), "pass \(pass): \(chip.text)")
            texts.insert(chip.text)
            // Nothing left running against a container this test is done with.
            await host.warmUpsFinished()
        }
        #expect(texts.count == 1, "\(texts.sorted())")
    }

    /// The other account, which has nothing to claim, settles to the same
    /// answer too, and the all-accounts engine leaves rate limits to the
    /// active account's (#303) after the settle as before it.
    @Test func everyEngineTheRenderReadsIsSettled() async throws {
        let now = Date()
        let container = try Self.seededContainer(now: now)
        let host = EngineHost(container: container,
                              preseeded: [.allAccounts: UsageIntelligenceEngine(modelContainer: container)])
        _ = host.engine(forAccount: Self.globex)
        await host.settleForRender(accounts: [Self.acme, Self.globex], active: Self.acme, now: now)

        #expect(Set(host.live.map(\.scope)) == [.allAccounts, .account(Self.acme), .account(Self.globex)])
        for (scope, engine) in host.all {
            #expect(await engine.scope == scope)
            #expect(await engine.fittedAt() != nil)
        }
        let quiet = try #require(await host.engine(forAccount: Self.globex).burnOutlook(window: .sevenDay))
        #expect(quiet.projectedFullAt == nil)
        #expect(await host.global.burnOutlook(window: .sevenDay) == nil)
    }
}

/// How often the removed render warm-up hedged the weekly chip, against the
/// settled one, with nothing forced: the race as it ran. Opt-in, because a
/// race's odds are a measurement, not an assertion:
///
///     PACER_RENDER_RACE_PROBE=1 swift test --package-path PacerCore --filter RenderWarmUpRaceProbe
///
/// `PACER_RENDER_RACE_RUNS` sets the number of runs (default 40).
@Suite("Render warm-up race probe", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PACER_RENDER_RACE_PROBE"] != nil))
@MainActor
struct RenderWarmUpRaceProbe {

    @Test func howOftenEachWarmUpHedgedTheWeeklyChip() async throws {
        let runs = Int(ProcessInfo.processInfo.environment["PACER_RENDER_RACE_RUNS"] ?? "") ?? 40
        let acme = RenderEngineSettleTests.acme, globex = RenderEngineSettleTests.globex
        var old: [String: Int] = [:], settled: [String: Int] = [:]
        for _ in 0..<runs {
            let now = Date()
            // The removed `ScreenshotMode.captureAll` lines, as they were.
            let before = try RenderEngineSettleTests.seededContainer(now: now)
            let oldHost = EngineHost(container: before,
                                     preseeded: [.allAccounts: UsageIntelligenceEngine(modelContainer: before)])
            await oldHost.global.recompute(now: now)
            for id in [acme, globex] { await oldHost.engine(forAccount: id).recompute(now: now) }
            await oldHost.warmUpsFinished()
            let o = await RenderEngineSettleTests.weeklyChip(oldHost.engine(for: .account(acme)), now: now)
            old[o?.text ?? "no chip", default: 0] += 1

            let after = try RenderEngineSettleTests.seededContainer(now: now)
            let host = EngineHost(container: after,
                                  preseeded: [.allAccounts: UsageIntelligenceEngine(modelContainer: after)])
            await host.settleForRender(accounts: [acme, globex], active: acme, now: now)
            let s = await RenderEngineSettleTests.weeklyChip(host.rateLimitEngine, now: now)
            settled[s?.text ?? "no chip", default: 0] += 1
        }
        print("render warm-up race, \(runs) runs")
        print("  old (engine(for:) + one direct refit): \(old.sorted { $0.key < $1.key })")
        print("  settleForRender:                        \(settled.sorted { $0.key < $1.key })")
        #expect(settled.count == 1)
    }
}
