import Foundation
import Testing
@testable import PacerCore

/// Wall time per forecast of the TimesFM 2.5 network for the meter shapes
/// `fm-timesfm25-meter` uses (five-hour: 288 steps of context, 60 to the
/// reset, one pass; weekly: 672 of context, 672 to the reset, a prefill and
/// five autoregressive steps), Accelerate single-threaded and with its
/// default threading, and the model end to end on the 120-day synthetic
/// history at cuts over its last 30 days. Opt-in (`PACER_TIMESFM_BENCH=1`),
/// and meaningful only in a release build (`swift test -c release
/// -Xswiftc -enable-testing`).
///
/// Measured 2026-10-26 on Apple silicon, the machine shared with four other
/// builds: see the MERGE NOTES of feat/fm-timesfm for the numbers.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PACER_TIMESFM_BENCH"] != nil))
struct TimesFMTimingTests {
    @Test func networkTimings() throws {
        guard let be = try TimesFMNetworkTests.backend() else { return }
        let shapes: [(String, Int, Int)] = [("five-hour", 288, 60), ("weekly", 672, 672)]
        var lines: [String] = []
        for (label, t, h) in shapes {
            let ctx = TimestralTimingTests.context(t, seed: 7)
            for single in [true, false] {
                FMBackends.setBLASThreading(singleThreaded: single)
                _ = try be.quantiles(context: [[ctx]], horizon: h)   // warm
                let n = 6
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<n { _ = try be.quantiles(context: [[ctx]], horizon: h) }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(n)
                lines.append(String(format: "timesfm25 %@ %@: %.1f ms/forecast", label,
                                    single ? "1 thread" : "default threads", ms))
            }
        }
        FMBackends.setBLASThreading(singleThreaded: false)
        print("TimesFM 2.5 timings\n" + lines.joined(separator: "\n"))
    }

    @Test func meterModelOnA120DayHistory() throws {
        guard let dir = TimestralTestWeights.url(FMWeights.timesfm25) else { return }
        let store = TimestralSyntheticHistory.store(days: 120)
        let runner = ArenaRunner(registry: ArenaRegistry.all,
                                 services: ArenaServices(weights: { $0 == FMWeights.timesfm25 ? dir : nil }))
        let last = store.meters.values.compactMap { $0.last?.tEvent }.max()!
        var lines: [String] = []
        for target in [ArenaTarget.meterFiveHour, .meterSevenDay] {
            var n = 0, total = 0.0
            for i in 0..<12 {
                let now = last - Millis(i) * (30 * ArenaTime.day / 12) - 7 * ArenaTime.minute
                let h = ArenaHistory(store: store, now: now, accounts: ["A1"])
                let req = ArenaRunner.request(history: h, targets: [target])
                guard !req.targets.isEmpty else { continue }
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = try runner.forecast(model: "fm-timesfm25-meter", history: h, request: req)
                total += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                n += 1
            }
            lines.append(String(format: "fm-timesfm25-meter %@: %.1f ms/forecast over %d cuts", target.rawValue,
                                total / Double(max(n, 1)), n))
        }
        print("fm-timesfm25-meter on a 120-day history\n" + lines.joined(separator: "\n"))
    }
}
