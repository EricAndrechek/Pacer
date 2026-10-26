import Foundation
import Testing
@testable import PacerCore

/// The store's cycle index against the arena's per-cut table, and what a
/// forecast costs over a long history.
@Suite struct AnalogTableTests {
    static let five = ArenaRegistry.fableAnalog.config.table("meter").table("five_hour")

    /// The index's table at `h.now`, or nil when it defers to the per-cut
    /// build; and the per-cut build itself.
    static func both(_ h: ArenaHistory, kind: String = "five_hour")
        -> (indexed: [Analog.CycleCuts]?, perCut: Analog.MeterTable) {
        let cfg = ArenaRegistry.fableAnalog.config.table("meter").table(kind)
        let step = Millis(cfg.int("step_min", 5)) * Analog.MIN, M = cfg.int("M", 60)
        let tz = Analog.tzMs(h, h.accounts[0])
        let indexed = FableAnalogModel.indexedBlocks(h, kind: kind, cap: nil, accounts: h.accounts, tz: tz,
                                                     step: step, M: M)
        let perCut = Analog.buildMeterTable(h, accounts: h.accounts, kind: kind, cap: nil, tz: tz, step: step, M: M,
                                            maxCycles: FableAnalogModel.maxCycles)
        return (indexed, perCut)
    }

    /// Every cut where the index answers, it answers the per-cut table,
    /// block for block; with rows known when written (the app) it always
    /// answers.
    @Test(arguments: [Millis(0), 20 * ArenaTime.minute])
    func indexMatchesThePerCutTable(knownLag: Millis) throws {
        let store = AnalogSynthetic.store(days: 30, knownLag: knownLag)
        let cuts = AnalogSynthetic.cuts(store)
        var compared = 0, deferred = 0
        for (i, t) in cuts.enumerated() where i % 3 == 0 {
            for kind in ["five_hour", "seven_day"] {
                let h = ArenaHistory(store: store, now: t, accounts: ["A1"], start: AnalogSynthetic.t0)
                let (indexed, perCut) = Self.both(h, kind: kind)
                guard let indexed else { deferred += 1; continue }
                compared += 1
                #expect(indexed == perCut.blocks, "cut \(t) \(kind)")
            }
        }
        print("analog index (lag \(knownLag / ArenaTime.minute) min): \(compared) cuts matched, \(deferred) deferred to the per-cut table")
        #expect(compared > 50)
        if knownLag == 0 { #expect(deferred == 0) }
    }

    /// The same on every fixture case, at a cut every 2 h 7 min of its history.
    @Test func indexMatchesThePerCutTableOnTheFixtures() throws {
        var compared = 0, deferred = 0
        for c in try ArenaFixtures.cases().cases {
            let full = ArenaFixtures.history(c)
            var t = c.inputs.history_start + ArenaTime.day
            while t <= c.request.now {
                let (indexed, perCut) = Self.both(full.asOf(t), kind: c.inputs.window_kind)
                if let indexed { compared += 1; #expect(indexed == perCut.blocks, "\(c.id) at \(t)") } else { deferred += 1 }
                t += 127 * ArenaTime.minute
            }
        }
        print("analog index on the fixtures: \(compared) cuts matched, \(deferred) deferred")
        #expect(compared > 100)
    }

    /// What one forecast costs on a 120-day history, the way the backfill
    /// runs it: a fresh runner per cut, every cut of a completed cycle.
    @Test func timingsOverA120DayHistory() throws {
        let store = AnalogSynthetic.store(days: 120)
        let top = ArenaHistory(store: store, now: AnalogSynthetic.t0 + 120 * ArenaTime.day, accounts: ["A1"],
                               start: AnalogSynthetic.t0)
        let cuts = AnalogSynthetic.cuts(store).filter { $0 <= top.now }
        let clock = ContinuousClock()
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) * 1e-15 }

        // The index, built on the first forecast at a cut (once per store).
        let lastCut = try #require(cuts.last)
        var indexBuild = Duration.zero
        do {
            let h = top.asOf(lastCut)
            let cfg = Self.five
            let tz = Analog.tzMs(h, "A1")
            indexBuild = clock.measure {
                _ = Analog.CycleIndex(store: store, account: "A1", kind: "five_hour", cap: nil, start: h.start,
                                      tz: tz, step: 5 * Analog.MIN, M: cfg.int("M", 60))
            }
        }
        // Five-hour forecasts at the latest 160 cuts (every table is near its full size there).
        var fiveTotal = Duration.zero, n5 = 0, rows = 0
        for t in cuts.suffix(160) {
            let h = top.asOf(t)
            let req = ArenaRunner.request(history: h, targets: [.meterFiveHour])
            guard !req.targets.isEmpty else { continue }
            let runner = ArenaRunner(registry: [ArenaRegistry.fableAnalog])
            var fc: ArenaForecast?
            fiveTotal += try clock.measure { fc = try runner.forecast(model: AnalogTests.name, history: h, request: req) }
            n5 += 1
            #expect(fc?.byKey[req.targets[0].key] != nil)
        }
        // The same forecasts in parts: the query (the cycle now, from every
        // reading known then), the table (the index's selection), the
        // weights, the quantiles.
        var parts = [Duration](repeating: .zero, count: 4)
        for t in cuts.suffix(160) {
            let h = top.asOf(t)
            let req = ArenaRunner.request(history: h, targets: [.meterFiveHour])
            guard let tr = req.targets.first else { continue }
            let m = AnalogTests.fitted(h)
            var Q: FableAnalogModel.Query?
            parts[0] += clock.measure { Q = m.query(h, tr) }
            let q = Q!
            var T: Analog.MeterTable?
            parts[1] += clock.measure { T = m.table(h, kind: q.kind, cap: q.cap, accounts: q.accounts, tz: q.tz, q.cfg) }
            var w: [Double] = []
            parts[2] += clock.measure { w = Analog.meterWeights(T!, q.q, q.cfg).w }
            parts[3] += clock.measure {
                _ = Analog.analogQuantiles(T!, q.q, tr.grid, w: w, levels: KitDetQ.forecastLevels, q.cfg)
            }
        }
        print(String(format: "analog five-hour forecast in parts (ms): query %.2f, table %.2f, weights %.2f, quantiles %.2f",
                     ms(parts[0]) / Double(max(n5, 1)), ms(parts[1]) / Double(max(n5, 1)),
                     ms(parts[2]) / Double(max(n5, 1)), ms(parts[3]) / Double(max(n5, 1))))
        // The per-cut table alone (the arena's way), at a few of them.
        var perCutTotal = Duration.zero, nPer = 0
        for t in cuts.suffix(160).enumerated().filter({ $0.offset % 16 == 0 }).map(\.element) {
            let h = top.asOf(t)
            perCutTotal += clock.measure { rows = Self.both(h).perCut.count }
            nPer += 1
        }
        // Weekly forecasts (the day model, 200 paths).
        var weekTotal = Duration.zero, n7 = 0
        for t in cuts.suffix(160).enumerated().filter({ $0.offset % 8 == 0 }).map(\.element) {
            let h = top.asOf(t)
            let req = ArenaRunner.request(history: h, targets: [.meterSevenDay])
            guard !req.targets.isEmpty else { continue }
            let runner = ArenaRunner(registry: [ArenaRegistry.fableAnalog])
            weekTotal += try clock.measure { _ = try runner.forecast(model: AnalogTests.name, history: h, request: req) }
            n7 += 1
        }
        let readings = store.meters.values.map(\.count).reduce(0, +)
        print(String(format: "analog timings, 120 days (%d readings, %d cycles, table %d rows): index build %.1f ms once; "
                     + "five-hour forecast %.2f ms (n=%d); per-cut table build alone %.2f ms (n=%d); weekly forecast %.2f ms (n=%d)",
                     readings, cuts.count / 8, rows, ms(indexBuild), ms(fiveTotal) / Double(max(n5, 1)), n5,
                     ms(perCutTotal) / Double(max(nPer, 1)), nPer, ms(weekTotal) / Double(max(n7, 1)), n7))
        #expect(n5 > 100 && n7 > 5)
    }

    /// The scoped weekly cap: an analog table like the five-hour one (no day
    /// model, no shrink), exact quantiles once its cuts suffice.
    @Test func scopedCapAnswersFromItsOwnCuts() throws {
        let store = AnalogSynthetic.store(days: 120)
        let now = AnalogSynthetic.t0 + 119 * ArenaTime.day + 13 * ArenaTime.hour
        let h = ArenaHistory(store: store, now: now, accounts: ["A1"], start: AnalogSynthetic.t0)
        let meter = ArenaMeterID(account: "A1", windowKind: "weekly_scoped", scopeModel: "Fable")
        let tr = try #require(ArenaRunner.targetRequest(history: h, meter: meter))
        #expect(tr.target == .meterScoped && tr.cap == "Fable")
        let runner = ArenaRunner(registry: [ArenaRegistry.fableAnalog])
        let req = ArenaRequest(now: now, accounts: ["A1"], targets: [tr])
        let fc = try #require(try runner.forecast(model: AnalogTests.name, history: h, request: req).byKey[tr.key])
        #expect(fc.paths == nil && fc.levels == KitDetQ.forecastLevels)
        let ess = try #require(fc.extras["ess"])
        #expect(ess >= 8)
        let median = fc.median
        #expect(median.count == tr.grid.count)
        #expect(median.allSatisfy { $0 >= 0 && $0 <= 100 })
        // Non-decreasing in the level at every grid time.
        let lo = fc.quantile(0.05), hi = fc.quantile(0.95)
        #expect(zip(lo, hi).allSatisfy { $0 <= $1 })
        // The same table from the index and from the cut.
        let model = AnalogTests.fitted(h)
        let Q = model.query(h, tr)
        let cfg = Q.cfg
        let step = Millis(cfg.int("step_min", 5)) * Analog.MIN
        let indexed = try #require(FableAnalogModel.indexedBlocks(h, kind: Q.kind, cap: Q.cap, accounts: Q.accounts,
                                                                 tz: Q.tz, step: step, M: cfg.int("M", 60)))
        let perCut = Analog.buildMeterTable(h, accounts: Q.accounts, kind: Q.kind, cap: Q.cap, tz: Q.tz, step: step,
                                            M: cfg.int("M", 60))
        #expect(indexed == perCut.blocks && perCut.count > 1000)
    }

    /// Little history: with no complete cycle every path is the day model's;
    /// with a few, a share `1 - ESS / 8` of them is. Either way paths, in
    /// whole points within [0, 100], shrunk.
    @Test func shortHistoriesFallBackToTheDayModel() throws {
        let store = AnalogSynthetic.store(days: 3)
        let cuts = AnalogSynthetic.cuts(store)
        var simulated = 0
        for t in [AnalogSynthetic.t0 + 9 * ArenaTime.hour] + cuts {
            let h = ArenaHistory(store: store, now: t, accounts: ["A1"], start: AnalogSynthetic.t0)
            let req = ArenaRunner.request(history: h, targets: [.meterFiveHour])
            guard let tr = req.targets.first else { continue }
            let runner = ArenaRunner(registry: [ArenaRegistry.fableAnalog])
            let fc = try #require(try runner.forecast(model: AnalogTests.name, history: h, request: req).byKey[tr.key])
            guard let paths = fc.paths else { continue }   // enough support already: exact
            simulated += 1
            #expect(paths.count == tr.nPaths)
            #expect(paths.allSatisfy { $0.count == tr.grid.count && $0.allSatisfy { $0 >= 0 && $0 <= 100 && $0 == $0.rounded() } })
        }
        #expect(simulated > 0)
    }

    /// A fixture case, end to end through the runner.
    @Test func timingsOnAFixtureCase() throws {
        let c = try #require(try ArenaFixtures.cases().cases.first { $0.inputs.window_kind == "five_hour" })
        let h = ArenaFixtures.history(c)
        let req = ArenaFixtures.request(c)
        let clock = ContinuousClock()
        var total = Duration.zero
        let reps = 20
        for _ in 0..<reps {
            let runner = ArenaRunner(registry: [ArenaRegistry.fableAnalog])
            total += try clock.measure { _ = try runner.forecast(model: AnalogTests.name, history: h, request: req) }
        }
        let ms = (Double(total.components.seconds) * 1e3 + Double(total.components.attoseconds) * 1e-15) / Double(reps)
        print(String(format: "analog timing, fixture %@: %.2f ms per five-hour forecast", c.id, ms))
    }
}
