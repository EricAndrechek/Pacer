import Foundation
import Testing
@testable import PacerCore

/// The calibration layer against the Python reference (`calib-*.json`):
/// the map refit from the fixtures' own records (`fit_parity` →
/// `fits.scale`, to 1e-9 relative), the fixture's map applied to this
/// port's own child quantiles (1e-6 plus the 6-decimal rounding), and the
/// wrapper end to end through the runner.
@Suite struct CalibParityTests {
    struct File: Decodable {
        let model: String
        let outputs: [Output]
        let fit_parity: [FitParity]
    }

    struct Output: Decodable {
        let `case`: String
        let levels: [Double]
        let quantiles: [[Double]]
        let median: [Double]
        let exact: Bool
        let detail: Detail
    }

    struct Detail: Decodable {
        let fit: KitCalib.KindFit?
        let child_exact: Bool
    }

    struct FitParity: Decodable {
        let kind: String
        let n0: Double
        let n0_bin: Double
        let min_origins: Int
        let s_max: Double
        let m_levels: Int
        let `case`: String
        let records: Recs
        let fits: Fits
    }

    struct Recs: Decodable {
        let q: [[Double]]
        let y: [Double]
        let lead_s: [Double]
        let origin: [Int64]
        let floor: [Double]
        let whole: [Bool]
    }

    struct Fits: Decodable { let scale: KitCalib.KindFit }

    static func file(_ name: String) throws -> File {
        try JSONDecoder().decode(File.self, from: Data(contentsOf: ArenaFixtures.url(name)))
    }

    /// Refit from exactly the fixture's (rounded) records: every `s`, `n`
    /// and `n_bin` of `fits.scale`.
    @Test(arguments: ["calib-spend-decay-30m", "calib-spend-decay-6h", "calib-g1-10-fable-analog",
                      "calib-fm-timestral-5m-meter"])
    func mapRefitFromTheRecords(_ name: String) throws {
        var worst = 0.0
        for fp in try Self.file(name).fit_parity {
            let r = KitCalib.Records(q: fp.records.q, y: fp.records.y, leadS: fp.records.lead_s,
                                     origin: fp.records.origin, floor: fp.records.floor, whole: fp.records.whole)
            #expect(r.m == fp.m_levels)
            let fit = KitCalib.fitKind(fp.kind, r, method: "scale", n0: fp.n0, n0Bin: fp.n0_bin,
                                       minOrigins: fp.min_origins, sMax: fp.s_max)
            let want = fp.fits.scale
            #expect(fit.n == want.n, "\(name) \(fp.kind) n")
            #expect(fit.nBin == want.nBin, "\(name) \(fp.kind) n_bin \(fit.nBin) vs \(want.nBin)")
            #expect(fit.centersS == want.centersS)
            for (b, row) in want.s.enumerated() {
                for (k, w) in row.enumerated() {
                    let rel = abs(fit.s[b][k] - w) / abs(w)
                    worst = max(worst, rel)
                    #expect(rel <= 1e-9, "\(name) \(fp.kind) s[\(b)][\(k)] \(fit.s[b][k]) vs \(w)")
                }
            }
        }
        print("\(name) map refit: max relative |Δs| \(worst)")
    }

    /// The fixture's map applied to this port's own spend-decay quantile
    /// curves reproduces the calibrated quantiles.
    @Test(arguments: [("calib-spend-decay-30m", "spend-decay-30m"), ("calib-spend-decay-6h", "spend-decay-6h")])
    func fixtureMapOnOurChild(_ names: (String, String)) throws {
        let (name, child) = names
        let cases = Dictionary(uniqueKeysWithValues: try ArenaFixtures.cases("cases-spend").cases.map { ($0.id, $0) })
        var worst = 0.0
        let file = try Self.file(name)
        #expect(file.outputs.count == 6)
        for o in file.outputs {
            let c = try #require(cases[o.case])
            let h = ArenaFixtures.history(c)
            let tr = ArenaFixtures.request(c).targets[0]
            let m = try SpendDecayParityTests.model(child, history: h)
            let curves = KitDetQ.spendDecayQuantiles(m.parts(tr), gridCount: tr.grid.count, levels: KitDetQ.curveLevels)
            let fit = try #require(o.detail.fit)
            #expect(!fit.isIdentity)
            let q = KitCalib.calibratedQuantiles(fit, curves: curves, grid: tr.grid, now: c.request.now, levels: o.levels)
            for (li, row) in o.quantiles.enumerated() {
                for (j, want) in row.enumerated() {
                    let d = abs(q[li][j] - want)
                    worst = max(worst, d)
                    #expect(d <= 1e-6, "\(name) \(o.case) q[\(o.levels[li])][\(j)] \(q[li][j]) vs \(want)")
                }
            }
            let med = KitCalib.calibratedQuantiles(fit, curves: curves, grid: tr.grid, now: c.request.now, levels: [0.5])[0]
            for (a, b) in zip(med, o.median) { #expect(abs(a - b) <= 1e-6, "\(name) \(o.case) median") }
        }
        print("\(name) fixture map on our child: max |Δq| \(worst)")
    }

    /// The wrapper end to end: its own backtests, its own records, its own
    /// map. The Python learned its map from Monte-Carlo paths, so only the
    /// plumbing is exact (which origins have records: `n`, `n_bin`); the
    /// scales and quantiles are reported.
    @Test(arguments: [("calib-spend-decay-30m", "spend-decay-30m"), ("calib-spend-decay-6h", "spend-decay-6h")])
    func wrapperEndToEnd(_ names: (String, String)) throws {
        let (name, _) = names
        let cases = Dictionary(uniqueKeysWithValues: try ArenaFixtures.cases("cases-spend").cases.map { ($0.id, $0) })
        var worstS = 0.0, worstQ = 0.0, outside = 0, points = 0
        for o in try Self.file(name).outputs {
            let c = try #require(cases[o.case])
            let h = ArenaFixtures.history(c)
            let req = ArenaFixtures.request(c)
            let tr = req.targets[0]
            let runner = ArenaRunner(registry: ArenaRegistry.all)
            let spec = try #require(ArenaRegistry.spec(name))
            let ctx = ArenaContext(spec: spec, seed: 1, services: ArenaServices(), runner: runner, history: { h })
            let model = try CalibModel(context: ctx)
            try model.fit(h)
            let fc = try model.forecast(req)
            let mine = try #require(model.fits[KitCalib.kindOf(tr.target, cap: tr.cap)], "\(name) \(o.case) fit")
            let want = try #require(o.detail.fit)
            #expect(mine.n == want.n, "\(name) \(o.case) n \(mine.n) vs \(want.n)")
            #expect(mine.nBin == want.nBin, "\(name) \(o.case) n_bin \(mine.nBin) vs \(want.nBin)")
            for (a, b) in zip(mine.s.joined(), want.s.joined()) { worstS = max(worstS, abs(log(a / b))) }
            let tf = try #require(fc.byKey[tr.key])
            for (li, lv) in o.levels.enumerated() {
                for (a, b) in zip(tf.quantile(lv), o.quantiles[li]) {
                    worstQ = max(worstQ, abs(a - b)); points += 1
                    if abs(a - b) > 1 { outside += 1 }
                }
            }
            // Through the runner too (memoized child, same answer).
            let viaRunner = try runner.forecast(model: name, history: h, request: req)
            #expect(viaRunner.byKey[tr.key]?.median == tf.median)
        }
        print("\(name) end to end: max |log s/s_py| \(worstS), max |Δq| \(worstQ), \(outside)/\(points) points off by > 1 pt")
    }

    @Test func applyKeepsTheMedianAndOrder() {
        // Twenty comonotone curves, a widening map: the median stays, the
        // ends move out, levels never cross.
        let grid: [Millis] = [60_000, 600_000, 3_600_000, 10_800_000]
        let curves = (0..<20).map { i in grid.indices.map { j in 10 + Double(i) * 0.1 * Double(j + 1) } }
        var fit = KitCalib.KindFit.identity("five_hour", method: "scale", n: 10)
        fit.s = [[2, 2, 2], [2, 2, 2], [2, 2, 2]]
        let out = KitCalib.apply(fit, curves, grid: grid, now: 0, roundWhole: true)
        for j in grid.indices {
            let before = curves.map { $0[j] }, after = out.map { $0[j] }
            #expect(abs(KitDetQ.median(before) - KitDetQ.median(after)) < 1e-12)
            #expect(after.min()! <= before.min()! + 1e-12)
            #expect(after.max()! >= before.max()! - 1e-12)
            #expect(zip(after, after.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 })
        }
        // Identity and nil leave it alone.
        #expect(KitCalib.apply(nil, curves, grid: grid, now: 0) == curves)
        #expect(KitCalib.apply(.identity("five_hour", method: "scale"), curves, grid: grid, now: 0) == curves)
    }

    @Test func isotonicIsPAVA() {
        #expect(KitCalib.isotonic([1, 3, 2, 4]) == [1, 2.5, 2.5, 4])
        #expect(KitCalib.isotonic([3, 2, 1]) == [2, 2, 2])
        #expect(KitCalib.isotonic([1, 2, 3]) == [1, 2, 3])
        #expect(KitCalib.midRanks([5, 1, 5, 3]) == [0.75, 0.125, 0.75, 0.375])
    }

    @Test func leadBinsAndKinds() {
        #expect(KitCalib.leadBin("five_hour", 1800) == 0)
        #expect(KitCalib.leadBin("five_hour", 1801) == 1)
        #expect(KitCalib.leadBin("five_hour", 7201) == 2)
        #expect(KitCalib.leadBin("seven_day", 300_000) == 3)
        #expect(KitCalib.kindOf(.meterScoped, cap: "Fable") == "weekly_scoped:Fable")
        #expect(KitCalib.kindOf(.meterSevenDay, cap: nil) == "seven_day")
        #expect(KitCalib.windowOf("weekly_scoped:Fable") == "weekly_scoped")
    }

    @Test func wrappersRegistered() throws {
        for (name, child) in [("calib-spend-decay-30m", "spend-decay-30m"), ("calib-spend-decay-6h", "spend-decay-6h"),
                              ("calib-g1-10-fable-analog", "g1-10-fable-analog"),
                              ("calib-fm-timestral-5m-meter", "fm-timestral-5m-meter")] {
            let s = try #require(ArenaRegistry.spec(name))
            #expect(s.children == [child])
            #expect(s.config.string("child", "") == child)
            #expect(s.config.table("backtest_every_h").double("five_hour", 0) == 2)
        }
        #expect(ArenaRegistry.spec("calib-spend-decay-30m")?.targets == [.meterFiveHour])
        #expect(ArenaRegistry.spec("calib-spend-decay-6h")?.targets == [.meterSevenDay, .meterScoped])
    }
}
