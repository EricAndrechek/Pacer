import Foundation
import Testing
@testable import PacerCore

/// Wall time of the Timestral-123M calls the recalibrated meters make: the
/// live forecast and the self-backtest batches, five-hour (576 steps of
/// context, 60 ahead) and weekly (288 of context, 672 ahead). Opt-in
/// (`PACER_COMBINED_BENCH=1`); meaningful in a release build.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PACER_COMBINED_BENCH"] != nil))
struct CombinedTimingTests {
    static func context(_ n: Int, seed: UInt64) -> [Double] {
        var rng = ArenaRNG(seed: seed)
        var c = 0.0
        return (0..<n).map { i in
            c += max(0, rng.normal() * 0.6 + (i % 60 < 30 ? 0.4 : 0.05))
            return i % 97 == 13 ? .nan : c
        }
    }

    @Test func networkBatches() throws {
        guard let fc = try TimestralTestWeights.forecaster("123m") else { print("123M weights not here"); return }
        var lines: [String] = []
        for (label, t, h) in [("five-hour", 576, 60), ("weekly", 288, 672)] {
            for b in [1, 8, 32] {
                let ctx = (0..<b).map { [Self.context(t, seed: UInt64(7 + $0))] }
                _ = try FMBackends.quantiles(fc, context: ctx, horizon: h)
                let n = 2
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<n { _ = try FMBackends.quantiles(fc, context: ctx, horizon: h) }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(n)
                lines.append(String(format: "123m %@ B=%d: %.1f ms/call, %.1f ms/series", label, b, ms, ms / Double(b)))
            }
        }
        print("Combined timings\n" + lines.joined(separator: "\n"))
    }
}
