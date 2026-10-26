import Foundation
import Testing
@testable import PacerCore

/// The calibration wrappers whose children other ports provide
/// (`calib-g1-10-fable-analog`, `calib-fm-timestral-5m-meter`, on
/// `cases.json`). On this branch the children are not registered and the
/// checks are skipped; once they are merged in:
///
/// - the fixture's map (`detail.fit`) on the child's own quantile curves
///   reproduces the calibrated quantiles where the fixture is exact,
///   provided the child answers at the 200 curve levels (or with paths);
/// - the wrapper end to end rests on exactly the Python's backtest origins
///   (`n`, `n_bin` of its own fit equal the fixture's).
///
/// A child that answers at other levels, or with Monte-Carlo output, is
/// reported rather than failed: its calibrated quantiles can only be as
/// close as its own.
@Suite struct CalibChildrenTests {
    static let wrappers = [("calib-g1-10-fable-analog", "g1-10-fable-analog"),
                           ("calib-fm-timestral-5m-meter", "fm-timestral-5m-meter")]

    @Test(arguments: wrappers)
    func fixtureMapOnTheirChild(_ names: (String, String)) throws {
        let (name, child) = names
        guard ArenaRegistry.spec(child) != nil else {
            print("\(name): child \(child) not registered on this branch; skipped")
            return
        }
        let file = try CalibParityTests.file(name)
        let cases = Dictionary(uniqueKeysWithValues: try ArenaFixtures.cases().cases.map { ($0.id, $0) })
        var exactWorst = 0.0, mcWorst = 0.0, exactChecked = 0, skipped: [String] = []
        for o in file.outputs {
            let c = try #require(cases[o.case])
            let req = ArenaFixtures.request(c)
            let tr = req.targets[0]
            let runner = ArenaRunner(registry: ArenaRegistry.all)
            let tf: ArenaTargetForecast
            do {
                guard let f = try runner.forecast(model: child, history: ArenaFixtures.history(c), request: req)
                    .byKey[tr.key] else { skipped.append(o.case); continue }
                tf = f
            } catch {
                skipped.append("\(o.case) (\(error))")
                continue
            }
            let curvesExact = tf.paths == nil && KitDetQ.curveLevels.allSatisfy { lv in tf.levels?.contains(lv) ?? false }
            let q = KitCalib.calibratedQuantiles(o.detail.fit, curves: KitCalib.curves(tf), grid: tr.grid,
                                                 now: c.request.now, levels: o.levels)
            var worst = 0.0
            for (li, row) in o.quantiles.enumerated() {
                for (j, want) in row.enumerated() { worst = max(worst, abs(q[li][j] - want)) }
            }
            if o.exact && curvesExact {
                #expect(worst <= 1e-6 + 5e-7, "\(name) \(o.case) max |Δq| \(worst)")
                exactWorst = max(exactWorst, worst); exactChecked += 1
            } else {
                mcWorst = max(mcWorst, worst)
            }
        }
        print("\(name) fixture map on \(child): exact cases checked \(exactChecked), max |Δq| \(exactWorst); "
              + "other cases max |Δq| \(mcWorst); skipped \(skipped)")
    }

    @Test(arguments: wrappers)
    func wrapperRestsOnThePythonsOrigins(_ names: (String, String)) throws {
        let (name, child) = names
        guard ArenaRegistry.spec(child) != nil else {
            print("\(name): child \(child) not registered on this branch; skipped")
            return
        }
        let file = try CalibParityTests.file(name)
        let cases = Dictionary(uniqueKeysWithValues: try ArenaFixtures.cases().cases.map { ($0.id, $0) })
        var checked = 0, failed: [String] = []
        for o in file.outputs.prefix(6) {
            let c = try #require(cases[o.case])
            let h = ArenaFixtures.history(c)
            let req = ArenaFixtures.request(c)
            let tr = req.targets[0]
            let runner = ArenaRunner(registry: ArenaRegistry.all)
            let spec = try #require(ArenaRegistry.spec(name))
            let ctx = ArenaContext(spec: spec, seed: 1, services: ArenaServices(), runner: runner, history: { h })
            let model = try CalibModel(context: ctx)
            try model.fit(h)
            do { _ = try model.forecast(req) } catch {
                failed.append("\(o.case) (\(error))")
                continue
            }
            let mine = try #require(model.fits[KitCalib.kindOf(tr.target, cap: tr.cap)], "\(name) \(o.case)")
            let want = try #require(o.detail.fit)
            #expect(mine.n == want.n && mine.nBin == want.nBin,
                    "\(name) \(o.case) n \(mine.n)/\(want.n) n_bin \(mine.nBin)/\(want.nBin)")
            checked += 1
        }
        print("\(name) end to end: \(checked) cases on the Python's origins; could not run \(failed)")
    }
}
