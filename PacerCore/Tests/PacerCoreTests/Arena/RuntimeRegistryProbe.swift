import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// Every registered arena model, timed the way the scorer runs it, on the
/// synthetic heavy account of `RuntimePerfProbe`: three completed cycles per
/// window, the eight cuts of each, one runner per cycle (a scorer turn), so
/// ensembles get the memo they get in the app. Prints each model's cost per
/// forecast and the first-launch estimate the merge notes quote.
///
/// Off by default: `PACER_ARENA_PERF=1 swift test --filter RuntimeRegistryProbe`.
/// `PACER_ARENA_WEIGHTS=<dir>` points at a `ForecastWeights` folder
/// (`<org>/<name>@<rev>/`) so models that pin weights run too. Synthetic data
/// only.
@Suite("Arena runtime: registry probe", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PACER_ARENA_PERF"] == "1"))
struct RuntimeRegistryProbe {

    static func weights() -> @Sendable (String) -> URL? {
        guard let root = ProcessInfo.processInfo.environment["PACER_ARENA_WEIGHTS"] else { return { _ in nil } }
        return { id in
            let dir = URL(fileURLWithPath: root).appendingPathComponent(id, isDirectory: true)
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
                ? dir : nil
        }
    }

    /// The scorer itself over the registry: a pass on the heavy account with
    /// small caps, each model's cost per forecast as the scorer sees it (one
    /// runner per turn), the memory it leaves, and the engine's pick after.
    @Test func aScorerPassOverTheRegistry() async throws {
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        let container = try RuntimePerfProbe.heavyStore(days: 120, now: now)
        let engine = UsageIntelligenceEngine(modelContainer: container)
        await engine.adopt(scope: .account(RuntimePerfProbe.account))
        await engine.recompute(now: now)
        _ = await engine.backfillRateLimitRecordIfNeeded(now: now, pause: .zero)
        var config = ArenaRecordScorer.Config()
        config.dutyCycle = 1
        config.sessionCycleCap = Int(ProcessInfo.processInfo.environment["PACER_ARENA_CAP5H"] ?? "") ?? 28
        config.weeklyCycleCap = 8
        let rt = ArenaRuntime(container: container, roster: .standard, weights: Self.weights(), config: config,
                              onRecordLanded: { _, news in _ = await engine.ingestArenaOutcomes(news) },
                              onLiveLanded: { _ in })
        await engine.adopt(arena: rt.link)
        let clock = ContinuousClock()
        let t0 = clock.now
        let r = await rt.scorer.pass(accounts: [RuntimePerfProbe.account], now: now)
        print(String(format: "[perf] scorer pass: %d cycles, %d forecasts, %d declined, %.1f s wall, %.1f s busy",
                     r.cycles, r.forecasts, r.declined, RuntimePerfProbe.seconds(clock.now - t0), r.busySeconds))
        for (id, sec) in r.modelSeconds.sorted(by: { $0.value > $1.value }) {
            print(String(format: "[perf]   %@: %.1f ms/forecast over %d", id,
                         sec * 1000 / Double(max(1, r.modelForecasts[id] ?? 1)), r.modelForecasts[id] ?? 0))
        }
        print("[perf] memory after the pass: \(ProcessMemory.current().summary)")
        await engine.recompute(now: now)
        for key in ["five_hour", "seven_day"] {
            let m = await engine.resolvedMethod(windowKey: key)
            let arenaIds = await engine.arenaModelIds(windowKey: key)
            print("[perf] \(key): picked \(m.selected ?? "-"), drawn \(m.resolved ?? "-"), sheet lists \(arenaIds)")
        }
    }

    @Test func everyRegisteredModel() async throws {
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        let container = try RuntimePerfProbe.heavyStore(days: 120, now: now)
        let pricing = PricingTable.Snapshot(pricingByModel: RuntimeHistoryBuilderTests.catalog)
        let built = ArenaHistoryBuilder.build(container: container, account: RuntimePerfProbe.account, now: now,
                                              mode: .calculate, pricing: pricing)
        let roster = ArenaRoster.standard
        let services = ArenaServices(weights: Self.weights())
        let clock = ContinuousClock()
        var perModel: [String: [String: [Double]]] = [:]     // window → model → ms
        var declined: [String: Int] = [:]
        for (target, kind) in [(ArenaTarget.meterFiveHour, "five_hour"), (.meterSevenDay, "seven_day")] {
            let binding = ArenaWindowBinding(account: RuntimePerfProbe.account, windowKey: kind, target: target, cap: nil)
            let readings = built.store.meters[ArenaMeterID(account: RuntimePerfProbe.account, windowKind: kind)]!
            let samples = readings.compactMap { r -> (at: Date, usedPercentage: Double, resetsAt: Date)? in
                guard let v = r.utilPct, let reset = r.resetsAt else { return nil }
                return (ArenaTime.date(r.tEvent), v, ArenaTime.date(reset))
            }
            let duration: TimeInterval = target == .meterFiveHour ? 5 * 3600 : 7 * 86400
            let (_, cycles) = BurnTrajectory.segment(samples: samples, duration: duration, now: now)
            let recent = cycles.filter { $0.resetsAt <= now }.sorted { $0.resetsAt > $1.resetsAt }.prefix(3)
            let models = roster.specs(for: target).filter {
                ArenaRecordScorer.weightsPresent($0, roster: roster, services: services)
            }
            for cycle in recent {
                let runner = ArenaRunner(registry: roster.registry, services: services)
                for cf in EngineSelfEval.rlCutFractions {
                    let cutNow = cycle.cycleStart.addingTimeInterval(duration * cf)
                    let cut = ArenaHistory(store: built.store, now: ArenaTime.millis(cutNow),
                                           accounts: [RuntimePerfProbe.account])
                    for spec in models {
                        let s = clock.now
                        let ok = (try? runner.projection(model: spec.name, binding: binding, history: cut,
                                                         resetAt: ArenaTime.millis(cycle.resetsAt))) != nil
                        let ms = RuntimePerfProbe.seconds(clock.now - s) * 1000
                        perModel[kind, default: [:]][spec.name, default: []].append(ms)
                        if !ok { declined["\(kind) \(spec.name)", default: 0] += 1 }
                    }
                }
            }
        }
        var total: [String: Double] = [:]
        for (kind, models) in perModel.sorted(by: { $0.key < $1.key }) {
            for (name, times) in models.sorted(by: { $0.key < $1.key }) {
                let mean = times.reduce(0, +) / Double(times.count)
                let sorted = times.sorted()
                total[kind, default: 0] += mean
                print(String(format: "[perf] %@ %@: mean %.1f ms, median %.1f ms, max %.1f ms (n=%d, declined %d)",
                             kind, name, mean, sorted[sorted.count / 2], sorted.last ?? 0, times.count,
                             declined["\(kind) \(name)"] ?? 0))
            }
        }
        let skipped = roster.selectable.filter {
            !ArenaRecordScorer.weightsPresent($0, roster: roster, services: services)
        }.map(\.name)
        if !skipped.isEmpty { print("[perf] not run (weights missing): \(skipped.joined(separator: ", "))") }
        // A heavy user: 4 accounts × (180 five-hour + 18 weekly + 18 scoped
        // cycles, the scorer's caps) × 8 cuts, every model, no pruning.
        let five = total["five_hour"] ?? 0, week = total["seven_day"] ?? 0
        let cpu = 4 * 8 * (180 * five + 36 * week) / 1000
        print(String(format: "[perf] all models, one cut: five-hour %.0f ms, weekly %.0f ms; first launch, 4 heavy accounts, "
                     + "no pruning: %.0f min of CPU, %.1f h at 25%% of a core", five, week, cpu / 60, cpu / 3600 / 0.25))
    }
}
