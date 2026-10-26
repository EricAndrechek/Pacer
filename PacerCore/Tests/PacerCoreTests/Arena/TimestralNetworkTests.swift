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

    @Test func rawOutputMatchesPyTorch() throws {
        guard let fc = try TimestralTestWeights.forecaster("5m") else { return }
        let fm = try ArenaFixtures.model("fm-timestral-5m-meter")
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
                    #expect(err <= 1e-3, "case \(out.case): \(g) vs \(w)")
                }
            }
            checked += 1
        }
        #expect(checked == 9)   // the ten five-hour cases, less c06 (at 100: flat, no network call)
        print("Timestral-5M raw parity: \(checked) cases, worst |Δ|/max(1,|x|) = \(worst)")
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

    @Test func meterModelEndToEnd() throws {
        guard TimestralTestWeights.url(TimestralTestWeights.ids["5m"]!) != nil else { return }
        let cases = try ArenaFixtures.cases().cases
        let fm = try ArenaFixtures.model("fm-timestral-5m-meter")
        let runner = ArenaRunner(registry: ArenaRegistry.all, services: TimestralTestWeights.services())
        var worst = 0.0
        for out in fm.outputs {
            let c = try #require(cases.first { $0.id == out.case })
            let fc = try runner.forecast(model: "fm-timestral-5m-meter", history: ArenaFixtures.history(c),
                                         request: ArenaFixtures.request(c))
            let tf = try #require(fc.byKey[c.request.key])
            for (li, lv) in Self.outLevels.enumerated() {
                let got = tf.quantile(lv)
                for (j, w) in out.quantiles[li].enumerated() {
                    worst = max(worst, abs(got[j] - w))
                    #expect(abs(got[j] - w) <= 0.02, "case \(out.case) level \(lv) grid \(j): \(got[j]) vs \(w)")
                }
            }
        }
        print("fm-timestral-5m-meter end to end: worst |Δ| = \(worst) points")
    }
}
