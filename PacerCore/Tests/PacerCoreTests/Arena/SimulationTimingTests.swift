import Foundation
import Testing
@testable import PacerCore

/// Per-forecast wall time of the simulation ports, at the app's 200 paths,
/// on the fixture cases and on a synthetic 120-day history (one account,
/// readings every minute while a five-hour window runs, every ten minutes
/// otherwise, the weekly meter every ten minutes, spend in 5-minute rows).
/// Every forecast is cold: a fresh runner and a fresh history cut (an empty
/// memo), which is what a backfill pays at each cut. Printed, and held
/// under a loose ceiling that catches a pathology, not a regression of a
/// few milliseconds (debug builds are several times slower than the app's).
@Suite struct SimulationTimingTests {
    #if DEBUG
    static let ceilingMs = 5_000.0
    #else
    static let ceilingMs = 100.0
    #endif

    static func ms(_ f: () throws -> Void) rethrows -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try f()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    static func stats(_ xs: [Double]) -> String {
        let s = xs.sorted()
        return String(format: "median %.1f ms, max %.1f ms (n=%d)", s[s.count / 2], s.last ?? 0, s.count)
    }

    @Test func onTheFixtureCases() throws {
        let runner = { SimulationPoolTests.runner() }
        for (model, file) in [(G208FableBurst.name, "cases-spend"), (G208FableBurst.name, "cases"),
                              (G207OpusLimit.name, "cases"), (G207OpusLimit.name, "cases-spend")] {
            var times: [Double] = []
            for c in try ArenaFixtures.cases(file).cases {
                guard let spec = ArenaRegistry.spec(model), spec.targets.contains(ArenaTarget(rawValue: c.request.target)!)
                else { continue }
                let h = ArenaFixtures.history(c), req = ArenaFixtures.request(c)
                times.append(try Self.ms { _ = try runner().forecast(model: model, history: h, request: req) })
            }
            print("timing \(model) on \(file): \(Self.stats(times))")
            #expect(times.allSatisfy { $0 < Self.ceilingMs })
        }
    }

    @Test func onA120DayHistory() throws {
        let (store, end) = SyntheticHistory.make(days: 120, seed: 7)
        let acct = SyntheticHistory.account
        // Cuts in the last two weeks where the five-hour window is running.
        var cuts: [Millis] = []
        var t = end - 14 * ArenaTime.day
        while t < end && cuts.count < 12 {
            let h = ArenaHistory(store: store, now: t, accounts: [acct])
            if ArenaRunner.targetRequest(history: h, meter: ArenaMeterID(account: acct, windowKind: "five_hour")) != nil {
                cuts.append(t)
                t += 23 * ArenaTime.hour
            } else {
                t += 17 * ArenaTime.minute
            }
        }
        #expect(cuts.count >= 6)
        let models: [(String, Set<ArenaTarget>)] = [
            (G208FableBurst.name, [.meterFiveHour]), (G207OpusLimit.name, [.meterFiveHour]),
            (G207OpusLimit.name, [.meterSevenDay]), (G208FableBurstMix.name, [.meterFiveHour]),
            (G207OpusPool.name, [.meterFiveHour, .meterSevenDay]),
        ]
        for (model, targets) in models {
            var cold: [Double] = [], warm: [Double] = []
            for t in cuts {
                let h = ArenaHistory(store: store, now: t, accounts: [acct])
                let req = ArenaRunner.request(history: h, targets: targets)
                #expect(!req.targets.isEmpty)
                cold.append(try Self.ms { _ = try SimulationPoolTests.runner().forecast(model: model, history: h, request: req) })
                // The same cut again with a fresh runner: what every other
                // model run on this cut, and the live refit, pays once the
                // cut's memo holds the derived tables.
                warm.append(try Self.ms { _ = try SimulationPoolTests.runner().forecast(model: model, history: h, request: req) })
            }
            let what = targets.map(\.rawValue).sorted().joined(separator: "+")
            print("timing \(model) [\(what)] on 120 days: cold \(Self.stats(cold)); memo warm \(Self.stats(warm))")
            #expect(cold.allSatisfy { $0 < Self.ceilingMs })
        }
        let n5 = store.meters[ArenaMeterID(account: acct, windowKind: "five_hour")]?.count ?? 0
        let n7 = store.meters[ArenaMeterID(account: acct, windowKind: "seven_day")]?.count ?? 0
        print("synthetic 120 days: \(n5) five-hour readings, \(n7) weekly, \(store.spend[acct]?.count ?? 0) spend rows")
    }
}

/// A synthetic account: work comes in spells during the local day, each
/// active 5-minute bin spends and moves both meters, readings are whole
/// points with a jittering reset, as the server sends them.
enum SyntheticHistory {
    static let account = "S1"

    static func make(days: Int, seed: UInt64) -> (ArenaHistoryStore, Millis) {
        var rng = ArenaRNG(seed: seed)
        let tz = -240
        let start: Millis = 1_760_000_000_000 - 1_760_000_000_000 % ArenaTime.day
        let end = start + Millis(days) * ArenaTime.day
        let bin = 5 * ArenaTime.minute
        var five: [ArenaReading] = [], seven: [ArenaReading] = []
        var spend: [ArenaSpendRow] = []
        var active = false
        var cycleReset: Millis?
        var u5 = 0.0, u7 = 0.0
        var weekReset = start + 7 * ArenaTime.day
        var t = start
        while t < end {
            let hour = Int(SimRandom.pmod(t + Millis(tz) * ArenaTime.minute, ArenaTime.day) / ArenaTime.hour)
            let day = hour >= 9 && hour < 23
            active = active ? rng.uniform() > 0.12 : rng.uniform() < (day ? 0.07 : 0.008)
            if t >= weekReset { weekReset += 7 * ArenaTime.day; u7 = 0 }
            if let r = cycleReset, t >= r { cycleReset = nil; u5 = 0 }
            var cost = 0.0
            if active {
                if cycleReset == nil { cycleReset = t + 5 * ArenaTime.hour }
                cost = SimRandom.exponential(0.9, rng: &rng)
                let last = t + Millis(rng.uniform() * Double(bin - 1))
                let opus = rng.uniform() < 0.3
                spend.append(ArenaSpendRow(tEvent: last, tKnown: last, family: opus ? "opus" : "fable", costUSD: cost,
                                           turns: 1 + Int(rng.uniform() * 6), tokens: 50_000))
                u5 = min(u5 + cost * 1.1, 100)
                u7 = min(u7 + cost * 0.09, 100)
            }
            // Readings: every minute while a five-hour window runs, every ten otherwise.
            let every: Millis = cycleReset != nil ? ArenaTime.minute : 10 * ArenaTime.minute
            var s = t
            while s < t + bin {
                if let r = cycleReset {
                    let jitter = Millis(rng.uniform() * 900)
                    five.append(ArenaReading(tEvent: s, tKnown: s, utilPct: u5.rounded(.down), resetsAt: r + jitter, active: true))
                } else {
                    five.append(ArenaReading(tEvent: s, tKnown: s, utilPct: 0, resetsAt: nil, active: false))
                }
                if SimRandom.pmod(s, 10 * ArenaTime.minute) == 0 {
                    seven.append(ArenaReading(tEvent: s, tKnown: s, utilPct: u7.rounded(.down),
                                              resetsAt: weekReset + Millis(rng.uniform() * 900), active: true))
                }
                s += every
            }
            t += bin
        }
        let store = ArenaHistoryStore(
            meters: [ArenaMeterID(account: account, windowKind: "five_hour"): five,
                     ArenaMeterID(account: account, windowKind: "seven_day"): seven],
            spend: [account: spend], tzOffsetMin: tz)
        return (store, end)
    }
}
