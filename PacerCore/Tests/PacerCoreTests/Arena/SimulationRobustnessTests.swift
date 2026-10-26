import Foundation
import Testing
@testable import PacerCore

/// The simulation ports at every kind of moment a backfill asks them about:
/// a cut every 37 minutes through a synthetic history from its first hours
/// (cold start: no past cycle, few turns) to day 10, every meter target with
/// a cycle in progress. No forecast may fall back (each fallback logs), and
/// every answer is 200 paths of the grid's length inside [0, 100].
@Suite struct SimulationRobustnessTests {
    final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        func add(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    }

    @Test func everyCutOfASyntheticHistory() throws {
        let (store, end) = SyntheticHistory.make(days: 10, seed: 3)
        let acct = SyntheticHistory.account
        let log = LogBox()
        var asked = [String: Int]()
        var t = end - 10 * ArenaTime.day + 20 * ArenaTime.minute
        while t < end {
            defer { t += 37 * ArenaTime.minute }
            let h = ArenaHistory(store: store, now: t, accounts: [acct])
            let req = ArenaRunner.request(history: h, targets: [.meterFiveHour, .meterSevenDay])
            if req.targets.isEmpty { continue }
            let runner = ArenaRunner(registry: SimulationPoolTests.runner().registry.values.map { $0 },
                                     services: ArenaServices(log: { log.add("\($0): \($1)") }))
            for name in [G208FableBurst.name, G207OpusLimit.name] {
                let spec = try #require(ArenaRegistry.spec(name))
                let mine = req.targets.filter { spec.targets.contains($0.target) }
                if mine.isEmpty { continue }
                let fc = try runner.forecast(model: name, history: h,
                                             request: ArenaRequest(now: t, accounts: req.accounts, targets: mine))
                for tr in mine {
                    asked["\(name) \(tr.target.rawValue)", default: 0] += 1
                    let p = try #require(fc.byKey[tr.key]?.paths, "\(name) \(tr.key) at \(t)")
                    #expect(p.count == 200 && p.allSatisfy { $0.count == tr.grid.count })
                    // g2-07 reads its paths at the grid by linear interpolation,
                    // as the Python does: between two steps at 100 that can land
                    // an ulp above it.
                    #expect(p.allSatisfy { $0.allSatisfy { $0 >= -1e-9 && $0 <= 100 + 1e-9 } }, "\(name) \(tr.key) at \(t)")
                    if name == G208FableBurst.name {
                        #expect(p.allSatisfy { zip($0, $0.dropFirst()).allSatisfy { $0 <= $1 } })
                    }
                }
            }
        }
        print("robustness: \(asked.sorted { $0.key < $1.key }), fallbacks \(log.lines.count)")
        #expect(log.lines.isEmpty, "\(log.lines.prefix(5))")
        #expect(asked.values.allSatisfy { $0 >= 20 })
    }

    /// `couple_weekly`: an account whose seven-day meter reads 100 is blocked
    /// until that resets, so g2-07 holds its five-hour meter where it is.
    @Test func aBlockedWeekHoldsTheFiveHourMeter() throws {
        let (base, end) = SyntheticHistory.make(days: 20, seed: 5)
        let acct = SyntheticHistory.account
        let fiveID = ArenaMeterID(account: acct, windowKind: "five_hour")
        let sevenID = ArenaMeterID(account: acct, windowKind: "seven_day")
        // A moment with a five-hour window running, and the week read at 100 since a day before it.
        var t = end - 3 * ArenaTime.day
        while ArenaRunner.targetRequest(history: ArenaHistory(store: base, now: t, accounts: [acct]), meter: fiveID) == nil {
            t += 7 * ArenaTime.minute
        }
        let weekReset = t + 2 * ArenaTime.day
        let seven = (base.meters[sevenID] ?? []).map { r -> ArenaReading in
            guard r.tEvent >= t - ArenaTime.day else { return r }
            return ArenaReading(tEvent: r.tEvent, tKnown: r.tKnown, utilPct: 100, resetsAt: weekReset, active: true)
        }
        let blocked = ArenaHistoryStore(meters: [fiveID: base.meters[fiveID] ?? [], sevenID: seven],
                                        spend: base.spend, tzOffsetMin: base.tzOffsetMin)
        let h = ArenaHistory(store: blocked, now: t, accounts: [acct])
        let tr = try #require(ArenaRunner.targetRequest(history: h, meter: fiveID))
        let fc = try ArenaRunner(registry: ArenaRegistry.simulationModels)
            .forecast(model: G207OpusLimit.name, history: h, request: ArenaRequest(now: t, accounts: [acct], targets: [tr]))
        let p = try #require(fc.byKey[tr.key]?.paths)
        let u0 = try #require(FMSeries.meterSeries(h, account: acct, windowKind: "five_hour", now: t).usedNow(tr.resetAt!))
        // Every path holds at the meter now, unless the history it copies
        // was parked at 100 (the Python's parked-step swap runs after the hold).
        let held = p.filter { $0.allSatisfy { $0 == u0 } }.count
        #expect(held >= 190, "\(held) of 200 paths held at \(u0)")
        // Unblocked, the same moment burns on.
        let free = try ArenaRunner(registry: ArenaRegistry.simulationModels)
            .forecast(model: G207OpusLimit.name, history: ArenaHistory(store: base, now: t, accounts: [acct]),
                      request: ArenaRequest(now: t, accounts: [acct], targets: [tr]))
        let pf = try #require(free.byKey[tr.key]?.paths)
        #expect(pf.filter { $0.allSatisfy { $0 == u0 } }.count < held)
    }
}
