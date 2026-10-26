import Foundation
import Testing
@testable import PacerCore

/// The TimesFM 2.5 network, ported, against the arena's PyTorch reference
/// (`timesfm==3.0.2` through `kit/fm/backends.py` `TimesFM25Backend`, CPU,
/// float32), on the synthetic port cases only:
///
/// - `timesfm-meter.json`: `arena.cli_portfix port-fixtures --model
///   fm-timesfm25-meter --snapshot port-fixtures --seed 42 --cases 20` (the
///   shared `cases.json`, identical to the one already here), with the
///   network's raw quantiles for the five-hour cases;
/// - `timesfm-raw.json`: the backend's raw quantiles on the weekly cases'
///   contexts (every 16th step: the autoregressive decode past 128 steps)
///   and on edge contexts the meter cases never reach (front padding off
///   the patch grid, NaN gaps, a constant and a negative series, a horizon
///   past the continuous quantile head).
///
/// Both from `ArenaFixtures/timesfm-generator.py`. Skips when the weights
/// are not on this Mac.
@Suite struct TimesFMNetworkTests {
    static let outLevels = [0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95]

    static func backend() throws -> TimesFM25Backend? {
        guard let dir = TimestralTestWeights.url(FMWeights.timesfm25) else {
            print("TimesFM 2.5 weights not on this Mac, skipped"); return nil
        }
        return try FMBackends.backend(TimesFM25Backend.name, weights: FMWeights.timesfm25,
                                      services: ArenaServices(weights: { $0 == FMWeights.timesfm25 ? dir : nil }))
            as? TimesFM25Backend
    }

    static func rawMatrix(_ v: JSONValue?) -> [[Double]]? {
        v?.array?.map { row in row.array?.compactMap(\.number) ?? [] }
    }

    @Test func configAndTensorsLoad() throws {
        guard let be = try Self.backend() else { return }
        let net = be.fc.network
        #expect(net.config == TimesFMConfig())
        #expect(net.layers.count == 20)
        #expect(net.parameterCount == 231_289_280)
        #expect(net.timescale.count == 40)
    }

    @Test func rawFiveHourMatchesPyTorch() throws {
        guard let be = try Self.backend() else { return }
        let fm = try ArenaFixtures.model("timesfm-meter")
        var worst = 0.0, checked = 0
        for out in fm.outputs {
            guard let d = out.detail, let want = Self.rawMatrix(d["raw"]), let ctx = d["context"]?.numbers else { continue }
            let horizon = Int(d["horizon_steps"]?.number ?? 0)
            let got = try be.quantiles(context: [[ctx.map { $0 ?? .nan }]], horizon: horizon).curve()
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
        #expect(checked == 9)   // the ten five-hour cases but c06, flat at 100
        print("TimesFM 2.5 five-hour raw parity: \(checked) cases, worst |Δ|/max(1,|x|) = \(worst)")
    }

    struct RawFile: Decodable {
        let levels: [Double]
        let cases: [Case]
        struct Case: Decodable {
            let `case`: String
            let horizon: Int
            let every: Int
            let context: [Double?]?
            let raw: [[Double]]
        }
    }

    @Test func rawWeeklyAndEdgeContextsMatchPyTorch() throws {
        guard let be = try Self.backend() else { return }
        let ref = try JSONDecoder().decode(RawFile.self, from: Data(contentsOf: ArenaFixtures.url("timesfm-raw")))
        #expect(ref.levels == TimesFM25Backend.levels)
        let fm = try ArenaFixtures.model("timesfm-meter")
        var worstBy: [String: Double] = [:]
        for rc in ref.cases {
            let ctx = try rc.context ?? #require(fm.outputs.first { $0.case == rc.case }?.detail?["context"]?.numbers)
            let got = try be.quantiles(context: [[ctx.map { $0 ?? .nan }]], horizon: rc.horizon).curve()
            #expect(got.count == rc.horizon)
            var worst = 0.0
            for (i, want) in rc.raw.enumerated() {
                for (g, w) in zip(got[i * rc.every], want) {
                    let err = abs(g - w) / max(1, abs(w))
                    worst = max(worst, err)
                    #expect(err <= 1e-3, "\(rc.case) step \(i * rc.every): \(g) vs \(w)")
                }
            }
            worstBy[rc.case] = worst
        }
        print("TimesFM 2.5 raw parity (weekly + edge): " + worstBy.sorted { $0.key < $1.key }
            .map { "\($0.key) \(String(format: "%.2e", $0.value))" }.joined(separator: ", "))
    }

    @Test func meterQuantilesFromTheFixturesRaw() throws {
        let cases = try ArenaFixtures.cases().cases
        let fm = try ArenaFixtures.model("timesfm-meter")
        var worst = [Double](repeating: 0, count: Self.outLevels.count), checked = 0
        for out in fm.outputs {
            guard let d = out.detail, let raw = Self.rawMatrix(d["raw"]),
                  let rawLevels = d["raw_levels"]?.numbers?.compactMap({ $0 }),
                  let ctx = d["context"]?.numbers, let cLast = ctx.last ?? nil else { continue }
            let c = try #require(cases.first { $0.id == out.case })
            let (levels, q) = FMMeterModel.meterQuantiles(
                raw: raw, rawLevels: rawLevels, used: d["used"]?.number ?? 0, cLast: cLast,
                step: Millis(d["step_ms"]?.number ?? 0), horizon: Int(d["horizon_steps"]?.number ?? 0),
                now: c.request.now, grid: c.request.grid)
            // TimesFM's 0.1…0.9 head, its tails extended to 0.01 and 0.99.
            #expect(levels == (d["levels_ext"]?.numbers?.compactMap { $0 } ?? []))
            #expect(levels.first == 0.01 && levels.last == 0.99 && levels.count == 11)
            // 1e-6 inside the head's 0.1…0.9. At 0.05 / 0.95 the meter reads
            // the tails extrapolated from the two outermost levels
            // (`extend_tails`: slope (z(0.01) − z(0.1)) / (z(0.1) − z(0.2))
            // ≈ 2.37), which carries the fixture's own 6-decimal rounding of
            // `raw`, the context and the answer (5e-7 each) through it;
            // Timestral's 21 levels need no extension, so 1e-6 holds there.
            for (li, lv) in Self.outLevels.enumerated() {
                let tol = (lv < 0.1 || lv > 0.9) ? 1.5e-6 * (1 + 2 * 2.38) : 1e-6
                for (j, row) in q.enumerated() {
                    let got = ArenaMath.interp(lv, xs: levels, ys: row)
                    let want = out.quantiles[li][j]
                    worst[li] = max(worst[li], abs(got - want))
                    #expect(abs(got - want) <= tol, "case \(out.case) level \(lv) grid \(j): \(got) vs \(want)")
                }
            }
            checked += 1
        }
        #expect(checked == 9)
        print("TimesFM meter quantiles from the fixture's raw: worst |Δ| per level "
            + zip(Self.outLevels, worst).map { "\($0) \(String(format: "%.2e", $1))" }.joined(separator: ", "))
    }

    @Test func meterModelEndToEnd() throws {
        guard let dir = TimestralTestWeights.url(FMWeights.timesfm25) else { return }
        let cases = try ArenaFixtures.cases().cases
        let fm = try ArenaFixtures.model("timesfm-meter")
        let runner = ArenaRunner(registry: ArenaRegistry.all,
                                 services: ArenaServices(weights: { $0 == FMWeights.timesfm25 ? dir : TimestralTestWeights.url($0) }))
        var worst = (fiveHour: 0.0, weekly: 0.0)
        for out in fm.outputs {
            let c = try #require(cases.first { $0.id == out.case })
            let fc = try runner.forecast(model: "fm-timesfm25-meter", history: ArenaFixtures.history(c),
                                         request: ArenaFixtures.request(c))
            let tf = try #require(fc.byKey[c.request.key])
            if let d = out.detail, let ctx = d["context"]?.numbers {
                let s = FMSeries.meterSeries(ArenaFixtures.history(c), account: c.inputs.account,
                                             windowKind: c.inputs.window_kind, scopeModel: c.inputs.scope_model,
                                             now: c.request.now)
                let grid = FMSeries.regularGrid(now: c.request.now, stepMs: Millis(d["step_ms"]?.number ?? 0), n: ctx.count)
                let mine = FMSeries.resampleLast(times: s.times, values: s.cum, grid: grid)
                #expect(zip(mine, ctx).allSatisfy { a, b in b.map { abs(a - $0) < 1e-6 } ?? a.isNaN }, "\(out.case) context")
            }
            let weekly = c.request.target == "meter.seven_day"
            for (li, lv) in Self.outLevels.enumerated() {
                let got = tf.quantile(lv)
                for (j, w) in out.quantiles[li].enumerated() {
                    let e = abs(got[j] - w)
                    if weekly { worst.weekly = max(worst.weekly, e) } else { worst.fiveHour = max(worst.fiveHour, e) }
                    #expect(e <= 0.02, "case \(out.case) level \(lv) grid \(j): \(got[j]) vs \(w)")
                }
            }
        }
        print("fm-timesfm25-meter end to end: \(fm.outputs.count) cases, worst |Δ| five-hour \(worst.fiveHour), weekly \(worst.weekly) points")
    }
}
