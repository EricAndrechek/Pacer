import Foundation
import Testing
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
