import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// What the runtime costs on a synthetic heavy account: 120 days of five-hour
/// and weekly readings every two minutes and ~480 turns a day. Off by
/// default; `PACER_ARENA_PERF=1 swift test --filter RuntimePerfProbe` prints
/// the numbers the merge notes quote. Synthetic data only.
@Suite("Arena runtime: perf probe", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PACER_ARENA_PERF"] == "1"))
struct RuntimePerfProbe {

    static let account = "acct-perf"

    static func heavyStore(days: Int, now: Date) throws -> ModelContainer {
        let container = try PacerStore.makeInMemoryContainer()
        let ctx = ModelContext(container)
        ctx.insert(Account(id: account, organizationId: account, displayName: "Perf", isActive: true,
                           firstSeenAt: now.addingTimeInterval(-Double(days) * 86400), lastSeenAt: now))
        let start = now.addingTimeInterval(-Double(days) * 86400)
        var rng = ArenaRNG(seed: 7)
        // Five-hour cycles with a one-hour gap; weekly cycles back to back.
        var t = start
        var cycleStart = start
        var weekStart = start
        var used5 = 0.0, used7 = 0.0
        var n = 0
        while t <= now {
            if t >= cycleStart.addingTimeInterval(6 * 3600) { cycleStart = t; used5 = 0 }
            if t >= weekStart.addingTimeInterval(7 * 86400) { weekStart = t; used7 = 0 }
            let inCycle = t < cycleStart.addingTimeInterval(5 * 3600)
            let burn = rng.uniform() < 0.3 ? rng.uniform() * 1.5 : 0
            if inCycle { used5 = min(100, used5 + burn) }
            used7 = min(100, used7 + burn / 12)
            ctx.insert(RateLimitSample(sampledAt: t, window: "five_hour", usedPercentage: used5.rounded(),
                                       resetsAt: inCycle ? cycleStart.addingTimeInterval(5 * 3600) : nil,
                                       source: "oauth", accountId: account))
            ctx.insert(RateLimitSample(sampledAt: t, window: "seven_day", usedPercentage: used7.rounded(),
                                       resetsAt: weekStart.addingTimeInterval(7 * 86400), source: "oauth",
                                       accountId: account))
            if burn > 0 {
                let s = TokenSample(sampledAt: t, date: TokenSample.formatDate(t),
                                    model: rng.uniform() < 0.7 ? "claude-opus-5-5" : "claude-sonnet-5",
                                    inputTokens: 2000, outputTokens: 800, cacheReadTokens: 40_000,
                                    cacheCreation5mTokens: 1000, cacheCreation1hTokens: 0)
                s.accountId = account
                ctx.insert(s)
            }
            n += 1
            if n % 20_000 == 0 { try ctx.save() }
            t = t.addingTimeInterval(120)
        }
        try ctx.save()
        return container
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    static let meters: Set<ArenaTarget> = [.meterFiveHour, .meterSevenDay, .meterScoped]

    @Test func heavyAccount() async throws {
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        let clock = ContinuousClock()
        let seedStart = clock.now
        let container = try Self.heavyStore(days: 120, now: now)
        print("[perf] seeded 120 days in \(Self.seconds(clock.now - seedStart)) s")

        let pricing = PricingTable.Snapshot(pricingByModel: RuntimeHistoryBuilderTests.catalog)
        var t0 = clock.now
        let built = ArenaHistoryBuilder.build(container: container, account: Self.account, now: now,
                                              mode: .calculate, pricing: pricing)
        let buildS = Self.seconds(clock.now - t0)
        let rows = built.store.meters.values.map(\.count).reduce(0, +)
        let spend = built.store.spend[Self.account]?.count ?? 0
        print("[perf] full build: \(String(format: "%.2f", buildS)) s, \(rows) thinned readings, \(spend) spend rows")

        t0 = clock.now
        let ext = ArenaHistoryBuilder.extend(built, container: container, account: Self.account,
                                             now: now.addingTimeInterval(60), mode: .calculate, pricing: pricing)
        print("[perf] extend: \(String(format: "%.3f", Self.seconds(clock.now - t0))) s (\(ext.store.meters.values.map(\.count).reduce(0, +)) readings)")

        // Per-forecast time on one cut, five-hour and weekly.
        let kalman = ArenaModelSpec(name: "perf-kalman", targets: Self.meters, config: ["method": "kalman-trend"],
                                    complexity: 5) { try PortEngineModel(context: $0) }
        let registry = ArenaRegistry.portModels + [kalman]
        for (target, kind) in [(ArenaTarget.meterFiveHour, "five_hour"), (.meterSevenDay, "seven_day")] {
            let binding = ArenaWindowBinding(account: Self.account, windowKey: kind, target: target, cap: nil)
            let readings = built.store.meters[ArenaMeterID(account: Self.account, windowKind: kind)]!
            for name in ["naive-flat", "perf-kalman"] {
                var times: [Double] = []
                for k in 0..<40 {
                    // Cuts spread over the last 60 days, each inside a live cycle.
                    let cutT = ArenaTime.millis(now) - Millis(k) * 36 * ArenaTime.hour - 2 * ArenaTime.hour
                    guard let c = ArenaRunner.cycleAt(readings.filter { $0.tKnown <= cutT }, now: cutT) else { continue }
                    let cut = ArenaHistory(store: built.store, now: cutT, accounts: [Self.account])
                    let runner = ArenaRunner(registry: registry)
                    let s = clock.now
                    _ = try? runner.projection(model: name, binding: binding, history: cut, resetAt: c.resetAt)
                    times.append(Self.seconds(clock.now - s) * 1000)
                }
                times.sort()
                print("[perf] \(kind) \(name): median \(String(format: "%.2f", times[times.count / 2])) ms, "
                      + "p90 \(String(format: "%.2f", times[times.count * 9 / 10])) ms over \(times.count) cuts")
            }
        }

        // A full scorer pass at full duty: throughput.
        var config = ArenaRecordScorer.Config()
        config.dutyCycle = 1
        let rt = ArenaRuntime(container: container, roster: ArenaRoster(registry: registry), config: config,
                              onRecordLanded: { _, _ in }, onLiveLanded: { _ in })
        t0 = clock.now
        let report = await rt.scorer.pass(accounts: [Self.account], now: now)
        let passS = Self.seconds(clock.now - t0)
        print("[perf] scorer pass: \(report.cycles) cycles, \(report.forecasts) forecasts, \(report.outcomes) outcomes "
              + "in \(String(format: "%.1f", passS)) s (busy \(String(format: "%.1f", report.busySeconds)) s); "
              + "\(String(format: "%.2f", report.busySeconds * 1000 / Double(max(1, report.forecasts)))) ms/forecast busy")
        print("[perf] memory: \(ProcessMemory.current().summary)")
    }
}
