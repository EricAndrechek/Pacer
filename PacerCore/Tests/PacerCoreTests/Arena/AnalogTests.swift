import Foundation
import Testing
@testable import PacerCore

/// `g1-10-fable-analog` against the Python reference's port fixtures
/// (`ArenaFixtures/g1-10-fable-analog.json`): the five-hour cases exactly
/// (whole points, every level and grid time), the weekly day-model
/// simulation within the fixtures' Monte-Carlo bounds, and the query
/// features and table of cuts to the 6 decimals stored.
@Suite struct AnalogTests {
    static let name = "g1-10-fable-analog"

    struct Pair {
        let c: ArenaFixtures.Case
        let o: ArenaFixtures.Output
    }

    static func pairs() throws -> [Pair] {
        let cases = try ArenaFixtures.cases().cases
        let outputs = try ArenaFixtures.model(name).outputs
        return outputs.map { o in Pair(c: cases.first { $0.id == o.case }!, o: o) }
    }

    /// A model fitted on the case's history, outside a runner, for its
    /// intermediates.
    static func fitted(_ h: ArenaHistory) -> FableAnalogModel {
        let spec = ArenaRegistry.fableAnalog
        let runner = ArenaRunner(registry: [spec])
        let ctx = ArenaContext(spec: spec, seed: 1, services: ArenaServices(), runner: runner, history: { h })
        let m = FableAnalogModel(context: ctx)
        m.fit(h)
        return m
    }

    static func close(_ a: Double, _ b: Double?, _ tol: Double = 5e-7) -> Bool {
        guard let b else { return false }
        return abs(a - b) <= tol
    }

    @Test func registered() throws {
        let spec = try #require(ArenaRegistry.spec(Self.name))
        #expect(spec.targets == [.meterFiveHour, .meterSevenDay, .meterScoped])
        #expect(spec.children.isEmpty && spec.weights.isEmpty)
        #expect(spec.config.table("meter").table("five_hour").double("shrink", 1) == 0.85)
        let mix = try #require(ArenaRegistry.spec("g1-10-fable-mix"))
        #expect(mix.children == ["g1-10-fable-analog", "port-engine-recent-rate", "spend-decay-1d"])
    }

    /// The query (`u`, elapsed, remaining, rates, hour, weekday, tz), the
    /// table (rows, cycles) and the weights (ESS, bandwidth scale), for
    /// every case, five-hour and weekly.
    @Test func queryTableAndWeightsMatchTheDetail() throws {
        for p in try Self.pairs() {
            let h = ArenaFixtures.history(p.c)
            let tr = ArenaFixtures.request(p.c).targets[0]
            let m = Self.fitted(h)
            let Q = m.query(h, tr)
            let d = try #require(p.o.detail)
            #expect(Q.kind == d["kind"]?.string, "\(p.c.id)")
            #expect(Self.close(Q.q.u, d["u"]?.number), "\(p.c.id) u")
            #expect(Q.q.e == d["elapsed_ms"]?.number, "\(p.c.id) elapsed")
            #expect(Q.q.remaining == d["remaining_ms"]?.number, "\(p.c.id) remaining")
            let rates = try #require(d["rates"]?.numbers)
            #expect(rates.count == Q.q.rates.count && zip(Q.q.rates, rates).allSatisfy { Self.close($0, $1) },
                    "\(p.c.id) rates \(Q.q.rates) vs \(rates)")
            #expect(Self.close(Q.q.hour, d["hour"]?.number), "\(p.c.id) hour \(Q.q.hour)")
            #expect(Double(Q.q.dow) == d["dow"]?.number, "\(p.c.id) dow")
            #expect(Double(Q.tz) == d["tz_ms"]?.number, "\(p.c.id) tz")
            let T = m.table(h, kind: Q.kind, cap: Q.cap, accounts: Q.accounts, tz: Q.tz, Q.cfg)
            #expect(Double(T.count) == d["table_rows"]?.number, "\(p.c.id) rows \(T.count)")
            #expect(Double(T.nCycles) == d["table_cycles"]?.number, "\(p.c.id) cycles \(T.nCycles)")
            let (_, scale, ess) = Analog.meterWeights(T, Q.q, Q.cfg)
            #expect(Self.close(ess, d["ess"]?.number, 1e-6), "\(p.c.id) ess \(ess) vs \(d["ess"]?.number ?? .nan)")
            #expect(Self.close(scale, d["bw_scale"]?.number), "\(p.c.id) scale \(scale)")
        }
    }

    /// Every five-hour case is exact in the fixtures: every level at every
    /// grid time must be the same whole point, and the shrink's median too.
    @Test func fiveHourQuantilesMatchExactly() throws {
        var points = 0, off: [String] = []
        for p in try Self.pairs() where p.o.exact {
            let h = ArenaFixtures.history(p.c)
            let req = ArenaFixtures.request(p.c)
            let runner = ArenaRunner(registry: [ArenaRegistry.fableAnalog])
            let fc = try #require(try runner.forecast(model: Self.name, history: h, request: req).byKey[p.c.request.key])
            #expect(fc.paths == nil, "\(p.c.id): an exact case answers with quantiles")
            for (li, level) in p.o.levels.enumerated() {
                let got = fc.quantile(level)
                for j in got.indices {
                    points += 1
                    if got[j] != p.o.quantiles[li][j] {
                        off.append("\(p.c.id) level \(level) grid \(j): \(got[j]) vs \(p.o.quantiles[li][j])")
                    }
                }
            }
            #expect(fc.median == p.o.median, "\(p.c.id) median")
            // The shrink's median: the weighted type-1 median before the shrink.
            let m = Self.fitted(h)
            let Q = m.query(h, req.targets[0])
            let T = m.table(h, kind: Q.kind, cap: Q.cap, accounts: Q.accounts, tz: Q.tz, Q.cfg)
            let (w, _, _) = Analog.meterWeights(T, Q.q, Q.cfg)
            let (_, med) = Analog.analogQuantiles(T, Q.q, req.targets[0].grid, w: w, levels: KitDetQ.levelsOut, Q.cfg)
            let want = try #require(p.o.detail?["shrink_median"]?.numbers)
            #expect(med?.map(Optional.init) == want, "\(p.c.id) shrink median")
        }
        print("analog five-hour parity: \(points) (level, grid) points, \(off.count) differ")
        #expect(points > 0)
        #expect(off.isEmpty, "\(off.prefix(10))")
    }

    /// The weekly cases are the day-model simulation: the port's own
    /// estimate from as many paths must fall inside the fixture's bounds at
    /// all but 0.5 % of (level, grid time) points.
    @Test func weeklyWithinMonteCarloBounds() throws {
        var points = 0, outside = 0
        var worst: [String] = []
        for p in try Self.pairs() where !p.o.exact {
            let h = ArenaFixtures.history(p.c)
            var req = ArenaFixtures.request(p.c)
            let nPaths = try #require(p.o.mc_paths)
            req.targets[0].nPaths = nPaths
            let runner = ArenaRunner(registry: [ArenaRegistry.fableAnalog], nPaths: nPaths)
            let fc = try #require(try runner.forecast(model: Self.name, history: h, request: req).byKey[p.c.request.key])
            let paths = try #require(fc.paths)
            #expect(paths.count == nPaths)
            let bounds = try #require(p.o.mc_bounds)
            for j in 0..<req.targets[0].grid.count {
                let col = paths.map { $0[j] }.sorted()
                for (li, level) in p.o.levels.enumerated() {
                    points += 1
                    let v = KitDetQ.readSorted(col, level)
                    if v < bounds.lo[li][j] - 1e-9 || v > bounds.hi[li][j] + 1e-9 {
                        outside += 1
                        if worst.count < 12 {
                            worst.append("\(p.c.id) level \(level) grid \(j): \(v) not in [\(bounds.lo[li][j]), \(bounds.hi[li][j])] (ref \(p.o.quantiles[li][j]))")
                        }
                    }
                }
            }
        }
        print("analog weekly MC: \(outside) of \(points) points outside the bounds (\(Double(outside) / Double(max(points, 1)) * 100) %)")
        for w in worst { print("  \(w)") }
        #expect(points > 0)
        #expect(Double(outside) <= 0.005 * Double(points), "\(worst)")
    }
}
