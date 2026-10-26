import Foundation
import Testing
@testable import PacerCore

/// Wall time per forecast, every Timestral size on this Mac, for the meter
/// shapes the models use: five-hour (144 steps of context, 60 to the reset),
/// weekly (288 of context, 672 to the reset) and the extended weekly
/// (1344 of context), with Accelerate single-threaded and with its default
/// threading. Opt-in (`PACER_TIMESTRAL_BENCH=1`), and meaningful only in a
/// release build (`swift test -c release -Xswiftc -enable-testing`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PACER_TIMESTRAL_BENCH"] != nil))
struct TimestralTimingTests {
    static func context(_ n: Int, seed: UInt64) -> [Double] {
        var rng = ArenaRNG(seed: seed)
        var c = 0.0
        return (0..<n).map { i in
            c += max(0, rng.normal() * 0.6 + (i % 60 < 30 ? 0.4 : 0.05))
            return i % 97 == 13 ? .nan : c
        }
    }

    @Test func timings() throws {
        let shapes: [(String, Int, Int)] = [("five-hour", 144, 60), ("weekly", 288, 672), ("weekly-1344", 1344, 672)]
        var lines: [String] = []
        for size in ["5m", "28m", "123m", "209m"] {
            guard let fc = try TimestralTestWeights.forecaster(size) else { lines.append("\(size): weights not here"); continue }
            for (label, t, h) in shapes {
                if label == "weekly-1344" && size != "209m" { continue }
                let ctx = Self.context(t, seed: 7)
                for single in [true, false] {
                    FMBackends.setBLASThreading(singleThreaded: single)
                    _ = try FMBackends.quantiles(fc, context: [[ctx]], horizon: h)   // warm
                    let n = size == "209m" ? 3 : 8
                    let start = DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<n { _ = try FMBackends.quantiles(fc, context: [[ctx]], horizon: h) }
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(n)
                    lines.append(String(format: "%@ %@ %@: %.1f ms/forecast", size, label,
                                        single ? "1 thread" : "default threads", ms))
                }
            }
        }
        FMBackends.setBLASThreading(singleThreaded: false)
        print("Timestral timings\n" + lines.joined(separator: "\n"))
    }
}
