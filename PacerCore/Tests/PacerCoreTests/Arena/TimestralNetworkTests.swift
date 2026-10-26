import Foundation
import Testing
@testable import PacerCore

/// The Timestral network, ported, against the arena's PyTorch reference
/// (`fm-timestral-5m-meter.json`, port-spec § Parity): the network's raw
/// output on each five-hour case's context (float32: `|Δ| <= 1e-3 ·
/// max(1, |x|)`), the meter quantiles from the fixture's own `raw` (1e-6),
/// and the model end to end. Skips when the 5M weights are not on this Mac.
@Suite struct TimestralNetworkTests {
    static let outLevels = [0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95]

    static func rawMatrix(_ v: JSONValue?) -> [[Double]]? {
        v?.array?.map { row in row.array?.compactMap(\.number) ?? [] }
    }

    @Test func safetensorsHeaderAndConfigLoad() throws {
        guard let id = TimestralTestWeights.ids["5m"], let dir = TimestralTestWeights.url(id) else { return }
        let net = try TimestralNetwork(directory: dir)
        #expect(net.config.d_model == 192)
        #expect(net.config.block_schedule.count == 8)
        #expect(net.parameterCount == 5_208_960)
        #expect(net.config.quantile_knots.count == 21)
        #expect(net.config.supports_known_covariates)
    }

    /// Every fixture: the 5M one from the port spec, and the larger sizes'
    /// and the extended-context weekly model, made the same way
    /// (`arena.cli_portfix port-fixtures --snapshot port-fixtures --seed 42
    /// --cases 20`, synthetic snapshot `arena synth --seed 42`).
    static let fixtures: [(model: String, size: String)] = [
        ("fm-timestral-5m-meter", "5m"), ("fm-timestral-28m-meter", "28m"),
        ("fm-timestral-123m-meter", "123m"), ("fm-timestral-209m-meter", "209m"),
        ("g2-01-haiku-weekly-209m-extended", "209m"),
    ]

    @Test(arguments: fixtures)
    func rawOutputMatchesPyTorch(_ model: String, _ size: String) throws {
        guard let fc = try TimestralTestWeights.forecaster(size) else {
            print("\(model): Timestral-\(size) weights not on this Mac, skipped"); return
        }
        let fm = try ArenaFixtures.model(model)
        var worst = 0.0, checked = 0
        for out in fm.outputs {
            guard let d = out.detail, let want = Self.rawMatrix(d["raw"]), let ctx = d["context"]?.numbers else { continue }
            let horizon = Int(d["horizon_steps"]?.number ?? 0)
            let got = try FMBackends.quantiles(fc, context: [[ctx.map { $0 ?? .nan }]], horizon: horizon).curve()
            #expect(got.count == want.count, "case \(out.case)")
            for (gr, wr) in zip(got, want) {
                for (g, w) in zip(gr, wr) {
                    let err = abs(g - w) / max(1, abs(w))
                    worst = max(worst, err)
                    #expect(err <= 1e-3, "\(model) case \(out.case): \(g) vs \(w)")
                }
            }
            checked += 1
        }
        // The fixtures keep `raw` for five-hour cases only (c06 sits at 100: flat, no network call).
        #expect(checked == (model.hasPrefix("g2-01") ? 0 : 9))
        print("\(model) raw parity: \(checked) cases, worst |Δ|/max(1,|x|) = \(worst)")
    }

    @Test func meterQuantilesFromTheFixturesRaw() throws {
        let cases = try ArenaFixtures.cases().cases
        let fm = try ArenaFixtures.model("fm-timestral-5m-meter")
        var worst = 0.0
        for out in fm.outputs {
            guard let d = out.detail, let raw = Self.rawMatrix(d["raw"]),
                  let rawLevels = d["raw_levels"]?.numbers?.compactMap({ $0 }),
                  let ctx = d["context"]?.numbers, let cLast = ctx.last ?? nil else { continue }
            let c = try #require(cases.first { $0.id == out.case })
            let (levels, q) = FMMeterModel.meterQuantiles(
                raw: raw, rawLevels: rawLevels, used: d["used"]?.number ?? 0, cLast: cLast,
                step: Millis(d["step_ms"]?.number ?? 0), horizon: Int(d["horizon_steps"]?.number ?? 0),
                now: c.request.now, grid: c.request.grid)
            #expect(levels == (d["levels_ext"]?.numbers?.compactMap { $0 } ?? []))
            for (li, lv) in Self.outLevels.enumerated() {
                for (j, row) in q.enumerated() {
                    let got = ArenaMath.interp(lv, xs: levels, ys: row)
                    let want = out.quantiles[li][j]
                    worst = max(worst, abs(got - want))
                    #expect(abs(got - want) <= 1e-6, "case \(out.case) level \(lv) grid \(j): \(got) vs \(want)")
                }
            }
        }
        print("Timestral meter quantiles from the fixture's raw: worst |Δ| = \(worst)")
    }

    @Test(arguments: fixtures)
    func meterModelEndToEnd(_ model: String, _ size: String) throws {
        guard TimestralTestWeights.url(TimestralTestWeights.ids[size]!) != nil else {
            print("\(model): Timestral-\(size) weights not on this Mac, skipped"); return
        }
        let cases = try ArenaFixtures.cases().cases
        let fm = try ArenaFixtures.model(model)
        let runner = ArenaRunner(registry: ArenaRegistry.all, services: TimestralTestWeights.services())
        var worst = 0.0
        for out in fm.outputs {
            let c = try #require(cases.first { $0.id == out.case })
            let fc = try runner.forecast(model: model, history: ArenaFixtures.history(c), request: ArenaFixtures.request(c))
            let tf = try #require(fc.byKey[c.request.key])
            // The intermediates first: the context and the meter now.
            if let d = out.detail, let ctx = d["context"]?.numbers {
                let wk = c.inputs.window_kind
                let s = FMSeries.meterSeries(ArenaFixtures.history(c), account: c.inputs.account, windowKind: wk,
                                             scopeModel: c.inputs.scope_model, now: c.request.now)
                let step = Millis(d["step_ms"]?.number ?? 0)
                let grid = FMSeries.regularGrid(now: c.request.now, stepMs: step, n: ctx.count)
                let mine = FMSeries.resampleLast(times: s.times, values: s.cum, grid: grid)
                #expect(zip(mine, ctx).allSatisfy { a, b in b.map { abs(a - $0) < 1e-6 } ?? a.isNaN }, "\(model) \(out.case) context")
            }
            for (li, lv) in Self.outLevels.enumerated() {
                let got = tf.quantile(lv)
                for (j, w) in out.quantiles[li].enumerated() {
                    worst = max(worst, abs(got[j] - w))
                    #expect(abs(got[j] - w) <= 0.02, "\(model) case \(out.case) level \(lv) grid \(j): \(got[j]) vs \(w)")
                }
            }
        }
        print("\(model) end to end: \(fm.outputs.count) cases, worst |Δ| = \(worst) points")
    }

    /// Two decode blocks (a horizon of 1100 steps, past the 32-patch block):
    /// the median fed back as context and the refine frames over 35 patches,
    /// against the Python on two fixture contexts (`timestral-5m-multiblock.json`,
    /// `TimestralForecaster.forecast(..., prediction_length=1100)`, every 10th step).
    @Test func multiBlockDecodeMatchesPyTorch() throws {
        guard let fc = try TimestralTestWeights.forecaster("5m") else { return }
        struct Ref: Decodable { let cases: [C]; struct C: Decodable { let `case`: String; let horizon: Int; let every: Int; let raw: [[Double]] } }
        let ref = try JSONDecoder().decode(Ref.self, from: Data(contentsOf: ArenaFixtures.url("timestral-5m-multiblock")))
        let fm = try ArenaFixtures.model("fm-timestral-5m-meter")
        var worst = 0.0
        for rc in ref.cases {
            let ctx = try #require(fm.outputs.first { $0.case == rc.case }?.detail?["context"]?.numbers)
            let got = try fc.forecast(context: [[ctx.map { Float($0 ?? .nan) }]], predictionLength: rc.horizon).curve(0, 0)
            for (i, want) in rc.raw.enumerated() {
                for (g, w) in zip(got[i * rc.every], want) {
                    let err = abs(Double(g) - w) / max(1, abs(w))
                    worst = max(worst, err)
                    #expect(err <= 1e-3, "\(rc.case) step \(i * rc.every): \(g) vs \(w)")
                }
            }
        }
        print("Timestral-5M two-block decode: worst |Δ|/max(1,|x|) = \(worst)")
    }
}
