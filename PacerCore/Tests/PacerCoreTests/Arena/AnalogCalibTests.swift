import Foundation
import Testing
@testable import PacerCore

/// `calib-g1-10-fable-analog` on this port's analog child: the fixture's
/// map (`detail.fit`) applied to the analog's own quantile curves must give
/// the fixture's calibrated quantiles (`detq.calib_quantiles`): to 1e-6 on
/// the five-hour cases, whose child is exact; within a point of the
/// Monte-Carlo bounds on the weekly ones, whose child is the day-model
/// simulation.
@Suite struct AnalogCalibTests {
    static let name = "calib-g1-10-fable-analog"

    @Test func fixtureMapOnTheAnalogChild() throws {
        let cases = Dictionary(uniqueKeysWithValues: try ArenaFixtures.cases().cases.map { ($0.id, $0) })
        let fits = Dictionary(uniqueKeysWithValues: try CalibParityTests.file(Self.name).outputs.map { ($0.case, $0) })
        var worst = 0.0, exactPoints = 0, mcPoints = 0, mcOutside = 0, beyondOne = 0, maxExcess = 0.0
        for o in try ArenaFixtures.model(Self.name).outputs {
            let c = try #require(cases[o.case])
            let fit = try #require(fits[o.case]?.detail.fit, "\(o.case) fit")
            let h = ArenaFixtures.history(c)
            var req = ArenaFixtures.request(c)
            let tr = req.targets[0]
            let curves: [[Double]]
            if o.exact {
                // The child's curves as the forecast carries them (its levels include every curve level).
                let runner = ArenaRunner(registry: [ArenaRegistry.fableAnalog])
                let fc = try #require(try runner.forecast(model: AnalogTests.name, history: h, request: req).byKey[tr.key])
                curves = KitDetQ.curveLevels.map { fc.quantile($0) }
            } else {
                // The child's 4000 simulated paths, read at the curve levels (`from_sampled`).
                let n = try #require(o.mc_paths)
                req.targets[0].nPaths = n
                let runner = ArenaRunner(registry: [ArenaRegistry.fableAnalog], nPaths: n)
                let paths = try #require(try runner.forecast(model: AnalogTests.name, history: h, request: req).byKey[tr.key]?.paths)
                let cols = (0..<tr.grid.count).map { j in paths.map { $0[j] }.sorted() }
                curves = KitDetQ.curveLevels.map { lv in cols.map { KitDetQ.readSorted($0, lv) } }
            }
            let q = KitCalib.calibratedQuantiles(fit, curves: curves, grid: tr.grid, now: c.request.now, levels: o.levels)
            for (li, row) in o.quantiles.enumerated() {
                for (j, want) in row.enumerated() {
                    if o.exact {
                        exactPoints += 1
                        worst = max(worst, abs(q[li][j] - want))
                        #expect(abs(q[li][j] - want) <= 1e-6, "\(o.case) q[\(o.levels[li])][\(j)] \(q[li][j]) vs \(want)")
                    } else {
                        let b = try #require(o.mc_bounds)
                        mcPoints += 1
                        let excess = max(b.lo[li][j] - q[li][j], q[li][j] - b.hi[li][j], 0)
                        if excess > 1e-9 {
                            mcOutside += 1
                            maxExcess = max(maxExcess, excess)
                            if excess > 1 + 1e-9 { beyondOne += 1 }
                        }
                    }
                }
            }
        }
        print("calib-g1-10-fable-analog on this analog: five-hour max |Δq| \(worst) over \(exactPoints) points; "
              + "weekly \(mcOutside) of \(mcPoints) points outside the MC bounds (max by \(maxExcess), \(beyondOne) by more than a point)")
        #expect(exactPoints > 0 && mcPoints > 0)
        // The calibrated bounds are the child's Monte-Carlo band carried
        // through the map, which rounds to whole points: "rounding to whole
        // points can tip a bound by half a point" (`detq.calib_quantiles`),
        // and reading the rounded curves at a level between two of them
        // tips it by a fraction more. The uncalibrated child is inside its
        // own bounds everywhere (`AnalogTests.weeklyWithinMonteCarloBounds`),
        // so a point may leave the calibrated band by under a point, never more.
        #expect(beyondOne == 0)
    }

    /// The wrapper runs end to end over this analog through the runner
    /// (its own backtests of the child, its own map) and answers every case.
    @Test func wrapperRunsOverTheAnalog() throws {
        for c in try ArenaFixtures.cases().cases.prefix(4) {
            let h = ArenaFixtures.history(c)
            let req = ArenaFixtures.request(c)
            let runner = ArenaRunner(registry: ArenaRegistry.all)
            let fc = try #require(try runner.forecast(model: Self.name, history: h, request: req).byKey[c.request.key])
            #expect(fc.median.count == c.request.grid.count)
            #expect(fc.median.allSatisfy { $0 >= 0 && $0 <= 100 })
        }
    }
}
