import Foundation
import Testing
@testable import PacerCore

/// Wall time per forecast, every Timestral size on this Mac, for the meter
/// shapes the models use: five-hour (144 steps of context, 60 to the reset),
/// weekly (288 of context, 672 to the reset) and the extended weekly
/// (1344 of context), with Accelerate single-threaded and with its default
/// threading. Opt-in (`PACER_TIMESTRAL_BENCH=1`), and meaningful only in a
/// release build (`swift test -c release -Xswiftc -enable-testing`).
///
/// Measured 2026-10-26 on Apple silicon, the machine shared with other
/// builds (ms per forecast, both symmetric passes; one thread / default):
/// 5M 0.9 / 0.9 five-hour, 2.0 / 2.1 weekly; 28M 4.0 / 4.0, 7.1 / 7.1;
/// 123M 15 / 16, 26 / 26; 209M 28 / 28, 44 / 45, and 70 / 55-71 with the
/// 1344-step weekly context. A loaded run doubled the 209M numbers single-
/// threaded (146 and 287 ms) while default threading held at 78 and 98.
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

/// A synthetic account with `days` of meter readings every minute (five-hour
/// and weekly meters, idle nights, integer utils) and five-minute spend
/// buckets: the size of history the app back-scores on first install.
enum TimestralSyntheticHistory {
    static func store(days: Int, seed: UInt64 = 11) -> ArenaHistoryStore {
        var rng = ArenaRNG(seed: seed)
        let start: Millis = 1_780_000_000_000 - 1_780_000_000_000 % ArenaTime.day
        let end = start + Millis(days) * ArenaTime.day
        var five: [ArenaReading] = [], week: [ArenaReading] = [], spend: [ArenaSpendRow] = []
        var fiveReset: Millis? = nil, fiveUtil = 0.0
        var weekReset = start + 7 * ArenaTime.day, weekUtil = 0.0
        var t = start
        while t < end {
            let hour = Int((t % ArenaTime.day) / ArenaTime.hour)
            let busy = hour >= 8 && hour < 23 && rng.uniform() < 0.7
            if t >= weekReset { weekReset += 7 * ArenaTime.day; weekUtil = 0 }
            if let r = fiveReset, t >= r { fiveReset = nil; fiveUtil = 0 }
            if busy {
                if fiveReset == nil { fiveReset = t + 5 * ArenaTime.hour }
                let burn = max(0, rng.normal() * 0.15 + 0.12)
                fiveUtil = min(100, fiveUtil + burn)
                weekUtil = min(100, weekUtil + burn / 12)
                if t % (5 * ArenaTime.minute) == 0 {
                    spend.append(ArenaSpendRow(tEvent: t, tKnown: t + 2_000, family: rng.uniform() < 0.7 ? "opus" : "sonnet",
                                               costUSD: burn * 0.4, turns: 3, tokens: 20_000))
                }
            }
            five.append(ArenaReading(tEvent: t, tKnown: t + 1_000, utilPct: fiveReset == nil ? 0 : fiveUtil.rounded(.down),
                                     resetsAt: fiveReset, active: fiveReset != nil))
            week.append(ArenaReading(tEvent: t, tKnown: t + 1_000, utilPct: weekUtil.rounded(.down),
                                     resetsAt: weekReset, active: true))
            t += ArenaTime.minute
        }
        return ArenaHistoryStore(meters: [ArenaMeterID(account: "A1", windowKind: "five_hour"): five,
                                          ArenaMeterID(account: "A1", windowKind: "seven_day"): week],
                                 spend: ["A1": spend], tzOffsetMin: -240, dataStart: start)
    }
}

/// Per-forecast wall time of every fm model on a 120-day history, at cuts
/// spread over the last 30 days, each cut a fresh `ArenaHistory` (what a
/// backfill does). Opt-in like the network timings.
///
/// Measured 2026-10-26 (release, ms per forecast, five-hour / weekly):
/// fm-timestral-5m-meter 2.1 / 2.0 (3.6 / 4.5 without the shared store
/// series); 28m-meter 7.5 / 6.1; struct-timestral-5m 23 / 33; struct-28m
/// 54 / 67; 209m-meter weekly 32; g2-01-haiku-weekly-209m-extended 47.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PACER_TIMESTRAL_BENCH"] != nil))
struct TimestralBackfillTimingTests {
    @Test func modelsOnA120DayHistory() throws {
        let store = TimestralSyntheticHistory.store(days: 120)
        let runner = ArenaRunner(registry: ArenaRegistry.all, services: TimestralTestWeights.services())
        let last = store.meters.values.compactMap { $0.last?.tEvent }.max()!
        var lines: [String] = []
        let models = ["fm-timestral-5m-meter", "fm-timestral-28m-meter", "struct-timestral-5m", "struct-timestral-28m",
                      "fm-timestral-209m-meter", "g2-01-haiku-weekly-209m-extended"]
        for name in models {
            guard let spec = ArenaRegistry.spec(name), spec.weights.allSatisfy({ TimestralTestWeights.url($0) != nil }) else {
                lines.append("\(name): weights not here"); continue
            }
            for target in [ArenaTarget.meterFiveHour, .meterSevenDay] where spec.targets.contains(target) {
                var n = 0, total = 0.0
                let cuts = name.contains("209m") ? 6 : 40
                for i in 0..<cuts {
                    let now = last - Millis(i) * (30 * ArenaTime.day / Millis(cuts)) - 7 * ArenaTime.minute
                    let h = ArenaHistory(store: store, now: now, accounts: ["A1"])
                    let req = ArenaRunner.request(history: h, targets: [target])
                    guard !req.targets.isEmpty else { continue }
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = try runner.forecast(model: name, history: h, request: req)
                    total += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                    n += 1
                }
                lines.append(String(format: "%@ %@: %.1f ms/forecast over %d cuts", name, target.rawValue,
                                    total / Double(max(n, 1)), n))
            }
        }
        // What the shared store series saves: the 5M meter with it off.
        FMSeries.storeSeriesEnabled = false
        for target in [ArenaTarget.meterFiveHour, .meterSevenDay] {
            var n = 0, total = 0.0
            for i in 0..<40 {
                let now = last - Millis(i) * (30 * ArenaTime.day / 40) - 7 * ArenaTime.minute
                let h = ArenaHistory(store: store, now: now, accounts: ["A1"])
                let req = ArenaRunner.request(history: h, targets: [target])
                guard !req.targets.isEmpty else { continue }
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = try ArenaRunner(registry: ArenaRegistry.all, services: TimestralTestWeights.services())
                    .forecast(model: "fm-timestral-5m-meter", history: h, request: req)
                total += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                n += 1
            }
            lines.append(String(format: "fm-timestral-5m-meter %@ without the store series: %.1f ms/forecast", target.rawValue,
                                total / Double(max(n, 1))))
        }
        FMSeries.storeSeriesEnabled = true
        print("fm models on a 120-day history\n" + lines.joined(separator: "\n"))
    }
}
