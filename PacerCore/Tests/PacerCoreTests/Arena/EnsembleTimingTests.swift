import Foundation
import Testing
import SwiftData
@testable import PacerCore

/// Wall time of one forecast of each ensemble port, backtests included, on
/// the synthetic 120-day history of `SpendTimingTests` (no real usage), five
/// hour and weekly: cold (a fresh runner: every child backtest runs) and
/// warm (the same runner five minutes later: the backtest origins sit on a
/// fixed lattice, so the runner's memo answers them). Needs the
/// Timestral-123M weights; opt-in (`PACER_ENSEMBLE_BENCH=1`), and
/// meaningful in a release build
/// (`swift test -c release -Xswiftc -enable-testing --filter EnsembleTimingTests`).
///
/// Recorded 2026-10-26, release, M-series Mac shared with seven other
/// builds (so ±2×), all six g1-05 children registered: g1-01 17 ms (both
/// windows); g2-05 20-48 ms five-hour, 29-65 ms weekly; g1-05 five-hour cold
/// 90-125 ms (6 child backtest forecasts on this quiet history; a busy one
/// has up to 42), warm 43-120 ms; g1-05 weekly cold 344-707 ms (42 child
/// backtest forecasts), warm 39-92 ms.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PACER_ENSEMBLE_BENCH"] != nil))
struct EnsembleTimingTests {
    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var origins = 0
        var lines: [String] = []
        func log(_ model: String, _ message: String) {
            lock.lock(); defer { lock.unlock() }
            if message.hasPrefix("backtest "), let r = message.range(of: #": (\d+) origins"#, options: .regularExpression) {
                let digits = message[r].filter(\.isNumber)
                origins += Int(digits) ?? 0
            }
            if message.contains("failed") || message.contains("cannot") { lines.append("\(model): \(message)") }
        }
    }

    /// As the record scorer runs them (`RuntimeRegistryProbe.everyRegisteredModel`
    /// for these three only): the heavy synthetic account, the three latest
    /// completed cycles per window, the eight cuts of each, one runner per
    /// cycle, so a cut's backtests reuse the earlier cuts' where the lattice
    /// agrees. Mean / median / max ms per forecast. Recorded 2026-10-26
    /// (release, shared Mac): five-hour g1-01 17.8 / 16.3 / 52, g2-05
    /// 18.3 / 18.3 / 19, g1-05 110 / 54 / 434; weekly g1-01 22 / 24 / 28,
    /// g2-05 27 / 28 / 33, g1-05 154 / 127 / 553 (the max is a cycle's first
    /// cut, which pays for every child backtest).
    @Test func asTheScorerRunsThem() throws {
        guard TimestralTestWeights.url(FMWeights.timestral123M) != nil else { return }
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        let container = try RuntimePerfProbe.heavyStore(days: 120, now: now)
        let pricing = PricingTable.Snapshot(pricingByModel: RuntimeHistoryBuilderTests.catalog)
        let built = ArenaHistoryBuilder.build(container: container, account: RuntimePerfProbe.account, now: now,
                                              mode: .calculate, pricing: pricing)
        let roster = ArenaRoster.standard
        let services = TimestralTestWeights.services()
        let names = ["g1-01-sonnet-calibrate123", "g2-05-sonnet-final", "g1-05-opus-ens-meter-big"]
        var lines: [String] = []
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
            for name in names {
                var times: [Double] = []
                var declined = 0
                for cycle in recent {
                    let runner = ArenaRunner(registry: roster.registry, services: services)
                    for cf in EngineSelfEval.rlCutFractions {
                        let cut = ArenaHistory(store: built.store,
                                               now: ArenaTime.millis(cycle.cycleStart.addingTimeInterval(duration * cf)),
                                               accounts: [RuntimePerfProbe.account])
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        let ok = (try? runner.projection(model: name, binding: binding, history: cut,
                                                         resetAt: ArenaTime.millis(cycle.resetsAt))) != nil
                        times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                        if !ok { declined += 1 }
                    }
                }
                let s = times.sorted()
                guard !s.isEmpty else { continue }
                lines.append(String(format: "%@ %@: mean %.1f ms, median %.1f ms, max %.1f ms (n=%d, declined %d)",
                                    kind, name, s.reduce(0, +) / Double(s.count), s[s.count / 2], s.last!, s.count,
                                    declined))
            }
        }
        print("ensemble timings as the scorer runs them\n" + lines.joined(separator: "\n"))
    }

    @Test func timings() throws {
        guard TimestralTestWeights.url(FMWeights.timestral123M) != nil else {
            print("ensemble timings: Timestral-123M weights not on this Mac, skipped")
            return
        }
        let (store, end) = SpendTimingTests.synthetic(days: 120)
        var out: [String] = []
        for (label, kind) in [("five-hour", "five_hour"), ("weekly", "seven_day")] {
            let meter = ArenaMeterID(account: "S1", windowKind: kind)
            let now = SpendTimingTests.activeNow(store, before: end, meter: ArenaMeterID(account: "S1", windowKind: "five_hour"))
            // Each child of g1-05 alone, at now (a fresh runner each).
            let kids = ArenaRegistry.spec("g1-05-opus-ens-meter-big")?.children ?? []
            for kid in kids where ArenaRegistry.spec(kid) != nil {
                let runner = ArenaRunner(registry: ArenaRegistry.all, services: TimestralTestWeights.services())
                let h = ArenaHistory(store: store, now: now, accounts: ["S1"])
                guard let tr = ArenaRunner.targetRequest(history: h, meter: meter) else { continue }
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = try runner.forecast(model: kid, history: h, request: ArenaRequest(now: now, accounts: ["S1"], targets: [tr]))
                out.append(String(format: "  child %@ %@: %.0f ms", kid, label,
                                  Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6))
            }
            for name in ["g1-01-sonnet-calibrate123", "g2-05-sonnet-final", "g1-05-opus-ens-meter-big"] {
                let counter = Counter()
                let services = ArenaServices(weights: { TimestralTestWeights.url($0) }, log: { counter.log($0, $1) })
                let runner = ArenaRunner(registry: ArenaRegistry.all, services: services)
                func ask(_ t: Millis) throws -> Double {
                    let h = ArenaHistory(store: store, now: t, accounts: ["S1"])
                    let tr = try #require(ArenaRunner.targetRequest(history: h, meter: meter))
                    let req = ArenaRequest(now: t, accounts: ["S1"], targets: [tr])
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let fc = try runner.forecast(model: name, history: h, request: req)
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                    #expect(fc.byKey[tr.key] != nil, "\(name) \(label)")
                    return ms
                }
                let cold = try ask(now)
                let coldOrigins = counter.origins
                let warm = try ask(now + 5 * ArenaTime.minute)
                out.append(String(format: "%@ %@: cold %.0f ms (%d child backtest forecasts), warm %.0f ms (%d more asked, memoized)",
                                  name, label, cold, coldOrigins, warm, counter.origins - coldOrigins))
                out += counter.lines.prefix(3).map { "    " + $0 }
            }
        }
        print("ensemble timings (120-day synthetic history)\n" + out.joined(separator: "\n"))
    }
}
