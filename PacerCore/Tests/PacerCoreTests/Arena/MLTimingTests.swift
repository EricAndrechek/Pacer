import Foundation
import Testing
@testable import PacerCore

/// Wall time of `ml-gbm-quantile`: training (the walk-forward set, three
/// calibration folds and the final boosters, seven levels each) and a
/// forecast once trained, on the parity fixture's history and on a
/// synthetic 120-day one (two accounts, five-hour and seven-day meters and
/// spend every five minutes while active), each kind at the history's end,
/// with the boosters fitted in parallel and serially. Opt-in
/// (`PACER_ML_BENCH=1`), and meaningful only in a release build
/// (`swift test -c release -Xswiftc -enable-testing`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PACER_ML_BENCH"] != nil))
struct MLTimingTests {
    /// A synthetic history: per account, two active spells a day (local
    /// working hours, random lengths), spend per family every 5 minutes
    /// while active, a five-hour cycle that opens on activity and a weekly
    /// one anchored on the first day; readings every 5 minutes while
    /// active, hourly otherwise.
    static func synthetic(days: Int, accounts: [String], seed: UInt64) -> ArenaHistoryStore {
        let H = ArenaTime.hour, M = ArenaTime.minute
        let t0: Millis = 1_780_000_000_000 - 1_780_000_000_000 % ArenaTime.day
        var meters: [ArenaMeterID: [ArenaReading]] = [:]
        var spend: [String: [ArenaSpendRow]] = [:]
        var rng = ArenaRNG(seed: seed)
        for (ai, a) in accounts.enumerated() {
            var r5: [ArenaReading] = [], r7: [ArenaReading] = [], sp: [ArenaSpendRow] = []
            var reset5: Millis? = nil, u5 = 0.0
            var reset7 = t0 + 7 * ArenaTime.day, u7 = 0.0
            let k5 = 0.6 + 0.2 * Double(ai), k7 = 0.07
            var t = t0
            let end = t0 + Millis(days) * ArenaTime.day
            var spells: [(Millis, Millis)] = []
            for d in 0..<days {
                let day = t0 + Millis(d) * ArenaTime.day
                if rng.uniform() < 0.15 { continue }       // a day off
                let a0 = day + 13 * H + Millis(rng.uniform() * 2 * Double(H))
                spells.append((a0, a0 + Millis((1.5 + 2.5 * rng.uniform()) * Double(H))))
                let b0 = day + 18 * H + Millis(rng.uniform() * 2 * Double(H))
                spells.append((b0, b0 + Millis((1 + 3 * rng.uniform()) * Double(H))))
            }
            var si = 0
            var lastReading: Millis = t0 - 2 * H
            while t < end {
                while si < spells.count && spells[si].1 <= t { si += 1 }
                let active = si < spells.count && spells[si].0 <= t
                if let r = reset5, t >= r { reset5 = nil; u5 = 0 }
                if t >= reset7 { reset7 += 7 * ArenaTime.day; u7 = 0 }
                if active {
                    if reset5 == nil { reset5 = t + 5 * H }
                    for f in ["opus", "sonnet"] where rng.uniform() < 0.7 {
                        let c = (0.1 + 1.4 * rng.uniform()) * (f == "opus" ? 1.0 : 0.3)
                        sp.append(ArenaSpendRow(tEvent: t + 4 * M, tKnown: t + 4 * M + 20_000, family: f, costUSD: c))
                        u5 = min(100, u5 + k5 * c); u7 = min(100, u7 + k7 * c)
                    }
                }
                if active || t - lastReading >= H {
                    let tk = t + 5 * M
                    r5.append(ArenaReading(tEvent: tk, tKnown: tk + 2_000, utilPct: (u5 * 10).rounded() / 10,
                                           resetsAt: reset5, active: reset5 != nil))
                    r7.append(ArenaReading(tEvent: tk, tKnown: tk + 2_000, utilPct: (u7 * 10).rounded() / 10,
                                           resetsAt: reset7, active: true))
                    lastReading = t
                }
                t += 5 * M
            }
            meters[ArenaMeterID(account: a, windowKind: "five_hour")] = r5
            meters[ArenaMeterID(account: a, windowKind: "seven_day")] = r7
            spend[a] = sp
        }
        return ArenaHistoryStore(meters: meters, spend: spend, tzOffsetMin: -300)
    }

    /// The latest moment before `end` (5-minute steps back) at which every
    /// account's five-hour and seven-day cycles are active.
    static func lastActive(_ store: ArenaHistoryStore, accounts: [String], end: Millis) -> Millis {
        var t = end
        while true {
            let h = ArenaHistory(store: store, now: t, accounts: accounts)
            let ok = accounts.allSatisfy { a in
                ["five_hour", "seven_day"].allSatisfy { k in
                    ArenaRunner.cycleAt(h.readings(account: a, windowKind: k), now: t).map { $0.resetAt - t >= 3_600_000 } ?? false
                }
            }
            if ok { return t }
            t -= 5 * ArenaTime.minute
        }
    }

    func time(_ store: ArenaHistoryStore, accounts: [String], now: Millis, parallel: Bool) throws -> [String] {
        let spec = ArenaRegistry.spec("ml-gbm-quantile")!
        var lines: [String] = []
        for (kind, target) in [("five_hour", ArenaTarget.meterFiveHour), ("seven_day", .meterSevenDay)] {
            let h = ArenaHistory(store: store, now: now, accounts: accounts)
            let meter = ArenaMeterID(account: accounts[0], windowKind: kind)
            guard let tr = ArenaRunner.targetRequest(history: h, meter: meter) else { continue }
            let runner = ArenaRunner(registry: [spec])
            final class Log: @unchecked Sendable { var lines: [String] = []; let lock = NSLock() }
            let log = Log()
            let services = ArenaServices(log: { _, m in log.lock.lock(); log.lines.append(m); log.lock.unlock() })
            let ctx = ArenaContext(spec: spec, seed: 42, services: services, runner: runner, history: { h })
            let model = try MLGBMQuantileModel(context: ctx)
            model.parallel = parallel
            let req = ArenaRequest(now: now, accounts: accounts, targets: [tr])
            let t0 = DispatchTime.now().uptimeNanoseconds
            try model.fit(h)
            _ = try model.forecast(req)
            let train = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
            let n = 20
            let t1 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<n { _ = try model.forecast(req) }
            let fc = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6 / Double(n)
            lines.append(String(format: "  %@ (%@): train+first forecast %.2f s, each later forecast %.2f ms; %@",
                                kind, parallel ? "parallel" : "serial", train, fc, log.lines.first ?? ""))
        }
        return lines
    }

    @Test func timings() throws {
        var lines: [String] = []
        let (store, hist) = try MLParityTests.store()
        lines.append("fixture (2 accounts, 36 days), at its end:")
        for par in [true, false] { lines += try time(store, accounts: hist.accounts, now: hist.now, parallel: par) }
        let accounts = ["S1", "S2"]
        let syn = Self.synthetic(days: 120, accounts: accounts, seed: 11)
        let end = syn.meters.values.compactMap { $0.last?.tKnown }.max()!
        let now = Self.lastActive(syn, accounts: accounts, end: end)
        lines.append("synthetic 120 days (2 accounts), at its end:")
        for par in [true, false] { lines += try time(syn, accounts: accounts, now: now, parallel: par) }
        let one = Self.synthetic(days: 120, accounts: ["S1"], seed: 11)
        lines.append("synthetic 120 days (1 account), at its end:")
        lines += try time(one, accounts: ["S1"], now: Self.lastActive(one, accounts: ["S1"], end: end), parallel: true)
        print("ml-gbm-quantile timings\n" + lines.joined(separator: "\n"))
    }
}
