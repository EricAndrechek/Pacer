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

/// A synthetic account over `days` days (five-hour and weekly meters read
/// every 5 minutes, spend rows while active), deterministic in `seed`: a
/// realistic-length history for timing, nothing more.
enum CombinedSynthetic {
    static func history(days: Int, end: Millis, seed: UInt64 = 3) -> ArenaHistoryStore {
        var rng = ArenaRNG(seed: seed)
        let step = 5 * ArenaTime.minute
        let start = end - Millis(days) * ArenaTime.day
        var r5: [ArenaReading] = [], r7: [ArenaReading] = [], spend: [ArenaSpendRow] = []
        var reset5: Millis?, reset7: Millis?
        var u5 = 0.0, u7 = 0.0
        var t = start
        var busy = false
        while t <= end {
            let hour = Int(((t / ArenaTime.hour) % 24 + 24) % 24)
            let daytime = hour >= 13 && hour <= 23
            // Sessions start and stop at random, mostly in the local day.
            if busy { if rng.uniform() < 0.04 { busy = false } } else if rng.uniform() < (daytime ? 0.03 : 0.004) { busy = true }
            if let r = reset5, t >= r { reset5 = nil; u5 = 0 }
            if let r = reset7, t >= r { reset7 = nil; u7 = 0 }
            if busy {
                if reset5 == nil { reset5 = t + 5 * ArenaTime.hour }
                if reset7 == nil { reset7 = t + 7 * ArenaTime.day }
                let burn = max(0, 0.9 + 0.6 * rng.normal())
                u5 = min(100, u5 + burn)
                u7 = min(100, u7 + burn / 14)
                spend.append(ArenaSpendRow(tEvent: t - 7_000, tKnown: t - 7_000, family: rng.uniform() < 0.7 ? "opus" : "sonnet",
                                           costUSD: burn * 0.4))
            }
            r5.append(ArenaReading(tEvent: t, tKnown: t, utilPct: reset5 == nil ? 0 : u5.rounded(), resetsAt: reset5,
                                   active: reset5 != nil))
            r7.append(ArenaReading(tEvent: t, tKnown: t, utilPct: reset7 == nil ? 0 : u7.rounded(), resetsAt: reset7,
                                   active: reset7 != nil))
            t += step
        }
        return ArenaHistoryStore(meters: [ArenaMeterID(account: "A1", windowKind: "five_hour"): r5,
                                          ArenaMeterID(account: "A1", windowKind: "seven_day"): r7],
                                 spend: ["A1": spend], tzOffsetMin: -240, dataStart: start)
    }
}

extension CombinedTimingTests {
    /// One forecast of each model, including its self-backtests, on a
    /// 120-day synthetic history: cold (nothing memoized), then the next
    /// forecast an hour (five-hour) or three hours (weekly) later, which
    /// shares every cut but the newest, then g2-06 on g1-08's history cut.
    @Test func perForecast() throws {
        guard TimestralTestWeights.url(FMWeights.timestral123M) != nil else { print("123M weights not here"); return }
        let end: Millis = 1_790_000_000_000
        let store = CombinedSynthetic.history(days: 120, end: end)
        let services = TimestralTestWeights.services()
        var lines: [String] = []
        // Wall time and this process's CPU time, with Accelerate on one
        // thread: on a busy Mac the CPU time is the steadier number.
        FMBackends.setBLASThreading(singleThreaded: true)
        defer { FMBackends.setBLASThreading(singleThreaded: false) }
        func cpu() -> Double {
            var u = rusage()
            getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1e3 + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e3
        }
        var lastCPU = 0.0
        func ms(_ f: () throws -> Void) rethrows -> Double {
            let s = DispatchTime.now().uptimeNanoseconds
            let c0 = cpu()
            try f()
            lastCPU = cpu() - c0
            return Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6
        }
        for (target, later) in [(ArenaTarget.meterFiveHour, ArenaTime.hour), (.meterSevenDay, 3 * ArenaTime.hour)] {
            let full = ArenaHistory(store: store, now: end, accounts: ["A1"])
            // The latest moment at or before `end - later` with the window active.
            var t0 = end - later
            var req0: ArenaRequest?
            while req0 == nil && t0 > end - 3 * ArenaTime.day {
                let r = ArenaRunner.request(history: full.asOf(t0), targets: [target])
                if !r.targets.isEmpty { req0 = r } else { t0 -= 5 * ArenaTime.minute }
            }
            guard let r0 = req0 else { lines.append("\(target.rawValue): no active window"); continue }
            let cache = FMCalCutCache(capacity: 4096)
            for (label, t) in [("cold", t0), ("an update later", t0 + later)] {
                let h = full.asOf(t)
                let req = label == "cold" ? r0 : ArenaRunner.request(history: h, targets: [target])
                guard !req.targets.isEmpty else { lines.append("\(target.rawValue) \(label): window idle"); continue }
                let runner = ArenaRunner(registry: ArenaRegistry.all, services: services)
                let spec = ArenaRegistry.spec("g1-08-opus-fm")!
                let ctx = ArenaContext(spec: spec, seed: 1, services: services, runner: runner, history: { h })
                let m = try G108OpusFM(context: ctx)
                m.meters.cutCache = cache
                m.fit(h)
                let before = (cache.hits, cache.misses)
                let t1 = try ms { _ = try m.forecast(req) }
                let c1 = lastCPU
                let gspec = ArenaRegistry.spec("g2-06-opus-fmgate2")!
                let gctx = ArenaContext(spec: gspec, seed: 1, services: services, runner: runner, history: { h })
                let g = try G206OpusFMGate2(context: gctx)
                g.fm.cutCache = cache
                g.fit(h)
                let t2 = try ms { _ = try g.forecast(req) }
                lines.append(String(format: "%@ %@: g1-08 %.0f ms wall / %.0f ms CPU (%d cuts computed, %d memoized), then g2-06 on the same cut %.1f ms wall / %.1f ms CPU",
                                    target.rawValue, label, t1, c1, cache.misses - before.1, cache.hits - before.0, t2, lastCPU))
            }
        }
        print("Combined per-forecast timings (120-day synthetic history)\n" + lines.joined(separator: "\n"))
    }
}

extension CombinedTimingTests {
    /// Whether a series' answer depends on its batch-mates (it must not, for
    /// the cut memo to batch).
    @Test func batchedRowsAreBitIdentical() throws {
        guard let fc = try TimestralTestWeights.forecaster("123m") else { return }
        for (t, h) in [(576, 60), (288, 672)] {
            let ctxs = (0..<5).map { Self.context(t, seed: UInt64(11 + $0)) }
            let batch = try FMBackends.quantiles(fc, context: ctxs.map { [$0] }, horizon: h)
            var diff = 0, maxd = 0.0
            for (i, c) in ctxs.enumerated() {
                let one = try FMBackends.quantiles(fc, context: [[c]], horizon: h).curve()
                let b = batch.curve(i)
                for (r1, r2) in zip(one, b) { for (x, y) in zip(r1, r2) where x != y { diff += 1; maxd = max(maxd, abs(x - y)) } }
            }
            print("batch vs single, context \(t), horizon \(h): \(diff) values differ, max |Δ| \(maxd)")
        }
    }
}

extension CombinedTimingTests {
    /// The background scorer's shape on a 120-day synthetic history: the
    /// newest completed cycles, newest first, each at 8 cut points, both
    /// models on each cut (one shared history cut, one runner per window,
    /// the cut memo shared), as a first install would run them.
    @Test func backfill() throws {
        guard TimestralTestWeights.url(FMWeights.timestral123M) != nil else { return }
        let end: Millis = 1_790_000_000_000
        let store = CombinedSynthetic.history(days: 120, end: end)
        let services = TimestralTestWeights.services()
        FMBackends.setBLASThreading(singleThreaded: true)
        defer { FMBackends.setBLASThreading(singleThreaded: false) }
        var lines: [String] = []
        for (target, cycles) in [(ArenaTarget.meterFiveHour, 40), (.meterSevenDay, 16)] {
            let id = ArenaMeterID(account: "A1", windowKind: target.windowKind)
            let resets = Array(Set(store.meters[id]!.compactMap(\.resetsAt)).filter { $0 <= end }.sorted().reversed().prefix(cycles))
            let cache = FMCalCutCache(capacity: 4096)
            let runner = ArenaRunner(registry: ArenaRegistry.all, services: services)
            var n = 0, declined = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for reset in resets {
                for f in stride(from: 0.1, through: 0.8, by: 0.1) {
                    let now = reset - target.windowMillis + Millis(Double(target.windowMillis) * f)
                    let cut = ArenaHistory(store: store, now: now, accounts: ["A1"])
                    let req = ArenaRunner.request(history: cut, targets: [target])
                    guard !req.targets.isEmpty else { declined += 1; continue }
                    for name in ["g1-08-opus-fm", "g2-06-opus-fmgate2"] {
                        let spec = ArenaRegistry.spec(name)!
                        let ctx = ArenaContext(spec: spec, seed: 1, services: services, runner: runner, history: { cut })
                        let m: any ArenaModel = name.hasPrefix("g1") ? try G108OpusFM(context: ctx) : try G206OpusFMGate2(context: ctx)
                        (m as? G108OpusFM)?.meters.cutCache = cache
                        (m as? G206OpusFMGate2)?.fm.cutCache = cache
                        try m.fit(cut)
                        _ = try m.forecast(req)
                        n += 1
                    }
                }
            }
            let s = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            lines.append(String(format: "%@: %d cycles, %d forecasts (%d cuts idle) in %.1f s, %.0f ms a forecast; %d network cuts, %d memo answers, %d kept",
                                target.rawValue, resets.count, n, declined, s, s * 1000 / Double(max(n, 1)),
                                cache.misses, cache.hits, cache.count))
        }
        print("Combined backfill (120-day synthetic history, Accelerate on one thread)\n" + lines.joined(separator: "\n"))
    }
}
