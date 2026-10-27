import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// What the arena runtime keeps in memory, and what each model costs, on the
/// synthetic heavy account of `RuntimePerfProbe` (120 days, readings every two
/// minutes): a scorer pass over the whole registry, then each cache measured
/// by what dropping it frees (`malloc` bytes in use), and the per-model CPU
/// table the cheap-first estimate is made from.
///
/// Off by default, and meant for a release build (the networks are 15–18×
/// slower unoptimised):
/// `PACER_ARENA_PERF=1 swift test -c release -Xswiftc -enable-testing --filter RuntimeMemoryProbe`.
/// `PACER_ARENA_CAP5H` / `PACER_ARENA_CAPWK` set the cycles scored (2 / 1),
/// `PACER_ARENA_OLD_POOLS=1` keeps network scratch as before (four a network,
/// any size). Weights as `RuntimeRegistryProbe` finds them. Synthetic data only.
@Suite("Arena runtime: memory probe", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PACER_ARENA_PERF"] == "1"))
struct RuntimeMemoryProbe {

    static func mb(_ b: Int) -> String { String(format: "%.1f MB", Double(b) / 1e6) }

    static func live() -> Int {
        MemoryHygiene.relieve()
        return Int(ProcessMemory.current().mallocLive)
    }

    static func describeHistory(_ rt: ArenaRuntime, account: String, now: Date, models: [String]) async
        -> [ArenaLiveRequest] {
        let built = await rt.history.built(account: account, now: now)
        let readings = built.store.meters.values.reduce(0) { $0 + $1.count }
        let spend = built.store.spend.values.reduce(0) { $0 + $1.count }
        print("[mem] history: \(readings) readings × \(MemoryLayout<ArenaReading>.stride) B + \(spend) spend rows × "
              + "\(MemoryLayout<ArenaSpendRow>.stride) B = "
              + mb(readings * MemoryLayout<ArenaReading>.stride + spend * MemoryLayout<ArenaSpendRow>.stride)
              + " a copy")
        print("[mem] kept network scratch \(mb(FMScratch.keptBytes)), FMCal cut cache \(FMCalCutCache.shared.count) "
              + "entries, store series \(FMSeries.storeSeriesCache.count) rows")
        var reqs: [ArenaLiveRequest] = []
        for (target, kind) in [(ArenaTarget.meterFiveHour, "five_hour"), (.meterSevenDay, "seven_day")] {
            let binding = ArenaWindowBinding(account: account, windowKey: kind, target: target, cap: nil)
            let rows = built.store.meters[ArenaMeterID(account: account, windowKind: kind)] ?? []
            guard let c = ArenaRunner.cycleAt(rows, now: ArenaCut.millis(built.builtThrough)) else { continue }
            reqs.append(ArenaLiveRequest(binding: binding, resetsAt: ArenaTime.date(c.resetAt),
                                         latestReadingAt: built.builtThrough, models: models))
        }
        return reqs
    }

    @Test func whatTheArenaKeepsAndWhatEachModelCosts() async throws {
        let env = ProcessInfo.processInfo.environment
        if env["PACER_ARENA_OLD_POOLS"] == "1" { FMScratch.keepBytes = .max; FMScratch.keepPerNetwork = 4 }
        if let mbCap = Int(env["PACER_ARENA_KEEP_MB"] ?? "") { FMScratch.keepBytes = mbCap << 20 }
        // The runner memo as it was (top-level answers kept, cleared whole
        // when full), to measure the LRU memo against.
        ArenaRunner.legacyMemoForMeasurement = env["PACER_ARENA_LEGACY_MEMO"] == "1"
        defer { ArenaRunner.legacyMemoForMeasurement = false }
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        let account = RuntimePerfProbe.account
        let container = try RuntimePerfProbe.heavyStore(days: 120, now: now)
        let m0 = Self.live()
        print("[mem] baseline after seeding: \(ProcessMemory.current().summary)")

        var config = ArenaRecordScorer.Config()
        config.dutyCycle = 1
        config.adaptiveBudget = false
        config.sessionCycleCap = Int(env["PACER_ARENA_CAP5H"] ?? "") ?? 2
        config.weeklyCycleCap = Int(env["PACER_ARENA_CAPWK"] ?? "") ?? 1
        config.pricing = PricingTable.Snapshot(pricingByModel: RuntimeHistoryBuilderTests.catalog)
        let costs = ArenaModelCosts(defaults: nil)
        let rt = ArenaRuntime(container: container, roster: .standard, weights: RuntimeRegistryProbe.weights(),
                              config: config, costs: costs, onRecordLanded: { _, _ in }, onLiveLanded: { _ in })
        let clock = ContinuousClock()
        let t0 = clock.now
        let r = await rt.scorer.pass(accounts: [account], now: now)
        print(String(format: "[mem] pass: %d cycles (phase 1 %d, phase 2 %d), %d forecasts, %d declined, %.0f s, "
                     + "%.1f s of CPU in forecasts%@", r.cycles, r.phaseCycles[1] ?? 0, r.phaseCycles[2] ?? 0,
                     r.forecasts, r.declined, RuntimePerfProbe.seconds(clock.now - t0),
                     r.modelCPUSeconds.values.reduce(0, +), ArenaRunner.legacyMemoForMeasurement ? " (old memo)" : ""))
        print("[mem] peak during the pass: \(ProcessMemory.current().summary); largest network workspace "
              + Self.mb(FMScratch.largestBytes) + ", kept up to " + Self.mb(FMScratch.keepBytes))
        for st in FMScratch.stats where st.calls > 0 {
            print("[mem]   \(st.network.split(separator: ".").dropLast().last ?? ""): \(st.calls) calls, largest "
                  + Self.mb(st.largest) + ", \(st.overCap) over the cap")
        }

        // The cost table: warm average (what phases are decided by) and the
        // mean including each runner's first forecast.
        let roster = ArenaRoster.standard
        var cheapFive = 0.0, cheapWeek = 0.0, allFive = 0.0, allWeek = 0.0
        var cheapNames: [String] = []
        for spec in roster.selectable where r.modelForecasts[spec.name] != nil {
            let five = costs.measured(spec.name, weekly: false)
            let week = costs.measured(spec.name, weekly: true)
            let mean = (r.modelCPUSeconds[spec.name] ?? 0) * 1000 / Double(max(1, r.modelForecasts[spec.name] ?? 1))
            // Phases are decided per window scale, as the scorer does.
            let cheap5 = (five ?? .infinity) <= config.cheapCostMs, cheapW = (week ?? .infinity) <= config.cheapCostMs
            if cheap5 { cheapFive += five ?? 0 }
            if cheapW { cheapWeek += week ?? 0 }
            if cheap5 || cheapW { cheapNames.append(spec.name) }
            let cheap = (five == nil || cheap5) && (week == nil || cheapW)
            allFive += five ?? 0; allWeek += week ?? 0
            print(String(format: "[cost] %@: five-hour %.1f ms, weekly %.1f ms warm; %.1f ms mean over %d, %.0f ms in all (%@)",
                         spec.name, five ?? -1, week ?? -1, mean, r.modelForecasts[spec.name] ?? 0,
                         (r.modelCPUSeconds[spec.name] ?? 0) * 1000, cheap ? "phase 1" : "phase 2"))
        }
        // A heavy user: 4 accounts × (180 five-hour + 18 weekly + 18 scoped
        // cycles, the scorer's caps) × 8 cuts, no pruning.
        func hours(_ five: Double, _ week: Double, rate: Double) -> Double {
            4 * 8 * (180 * five + 36 * week) / 1000 / 3600 / rate
        }
        print(String(format: "[cost] phase 1: %d models, one cut %.0f ms five-hour, %.0f ms weekly; 4 heavy accounts: "
                     + "%.1f h at 20%% of a core, %.1f h at a full core", cheapNames.count, cheapFive, cheapWeek,
                     hours(cheapFive, cheapWeek, rate: 0.2), hours(cheapFive, cheapWeek, rate: 1)))
        print(String(format: "[cost] every model: one cut %.0f ms five-hour, %.0f ms weekly; 4 heavy accounts: "
                     + "%.1f h at 20%%, %.1f h at a full core (no pruning)", allFive, allWeek,
                     hours(allFive, allWeek, rate: 0.2), hours(allFive, allWeek, rate: 1)))
        print("[cost] phase 1 models: \(cheapNames.sorted().joined(separator: ", "))")

        // What is kept after the pass, by what dropping it frees.
        let m1 = Self.live()
        print("[mem] after the pass, kept: \(Self.mb(m1 - m0)) over the baseline")
        let names = Array(roster.selectable.map(\.name).filter { r.modelForecasts[$0] != nil }.prefix(4))
        // In a function of its own, so nothing here holds the history after.
        let reqs = await Self.describeHistory(rt, account: account, now: now, models: names)
        await rt.live.submit(reqs)
        await rt.live.settle()
        let m2 = Self.live()
        print("[mem] live projections (\(names.count) models × \(reqs.count) windows): +\(Self.mb(m2 - m1))")

        let before = Self.live()
        FMScratch.release()
        let afterScratch = Self.live()
        FMCalCutCache.shared.removeAll()
        FMSeries.storeSeriesCache.removeAll()
        let afterCaches = Self.live()
        await rt.live.dropRunners()
        let afterRunners = Self.live()
        await rt.history.forget(account: account)
        let afterHistory = Self.live()
        print("[mem] freed: network scratch \(Self.mb(before - afterScratch)), FMCal + store series "
              + "\(Self.mb(afterScratch - afterCaches)), live runners \(Self.mb(afterCaches - afterRunners)), "
              + "history (+ its store memo) \(Self.mb(afterRunners - afterHistory)); left over the baseline "
              + Self.mb(afterHistory - m0))
    }
}
