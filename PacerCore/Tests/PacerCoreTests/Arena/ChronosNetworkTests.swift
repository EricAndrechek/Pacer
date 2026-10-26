import Foundation
import Testing
@testable import PacerCore

/// Where the tests find Chronos-2's weights (the store's places, a checkout's
/// `Vendor/ForecastWeights`, the local Hugging Face cache: the same lookup as
/// Timestral's), and the pipeline loaded once per test process.
enum ChronosTestWeights {
    static func url() -> URL? { TimestralTestWeights.url(ChronosWeights.chronos2) }
    static func services() -> ArenaServices { ArenaServices(weights: { TimestralTestWeights.url($0) }) }
    static func pipeline() throws -> ChronosPipeline? {
        guard let u = url() else { return nil }
        return try ArenaChronos.pipeline(ChronosWeights.chronos2, directory: u)
    }
}

/// The Chronos-2 network, ported, against the arena's PyTorch reference
/// (chronos-forecasting 2.3.2 through `kit.fm.backends.Chronos2Backend`):
///
/// - `chronos-fm-chronos2-meter.json` (`python -m arena.cli_portfix
///   port-fixtures --model fm-chronos2-meter --snapshot port-fixtures --seed
///   42 --cases 20`, synthetic snapshot `arena synth --seed 42`): its
///   five-hour cases keep the network's raw quantiles;
/// - `chronos-raw.json` (`chronos-generator.py` beside it): the raw
///   quantiles of every weekly case's context, and two contexts as one
///   two-variate series and as two series.
///
/// Network output within float32 `1e-3 · max(1, |x|)`. Skips when the
/// weights are not on this Mac.
@Suite struct ChronosNetworkTests {
    static let fixture = "chronos-fm-chronos2-meter"

    static func rawMatrix(_ v: JSONValue?) -> [[Double]]? {
        v?.array?.map { row in row.array?.compactMap(\.number) ?? [] }
    }

    static func context(_ out: ArenaFixtures.Output) -> [Double]? {
        out.detail?["context"]?.numbers?.map { $0 ?? .nan }
    }

    struct Raw: Decodable {
        let levels: [Double]
        let weekly: [Weekly]
        let multi: Multi
        struct Weekly: Decodable { let `case`: String; let horizon: Int; let steps: [Int]; let raw: [[Double]] }
        struct Multi: Decodable {
            let cases: [String]; let horizon: Int; let steps: [Int]
            let multivariate: [[[Double]]]   // [V][step][Q]
            let batch: [[[Double]]]          // [B][step][Q]
        }
    }

    static func raw() throws -> Raw {
        try JSONDecoder().decode(Raw.self, from: Data(contentsOf: ArenaFixtures.url("chronos-raw")))
    }

    static func check(_ got: [[Double]], _ want: [[Double]], _ label: String, worst: inout Double) {
        #expect(got.count == want.count, "\(label): \(got.count) rows vs \(want.count)")
        for (gr, wr) in zip(got, want) {
            #expect(gr.count == wr.count, "\(label)")
            for (g, w) in zip(gr, wr) {
                let err = abs(g - w) / max(1, abs(w))
                worst = max(worst, err)
                #expect(err <= 1e-3, "\(label): \(g) vs \(w)")
            }
        }
    }

    @Test func configAndWeightsLoad() throws {
        guard let p = try ChronosTestWeights.pipeline() else { print("Chronos-2 weights not on this Mac, skipped"); return }
        let c = p.config
        #expect(c.d_model == 768 && c.d_kv == 64 && c.d_ff == 3072 && c.num_layers == 12 && c.num_heads == 12)
        #expect(c.chronos_config.use_reg_token && c.chronos_config.use_arcsinh)
        #expect(c.patch_size == 16 && c.chronos_config.max_output_patches == 64 && c.time_encoding_scale == 8192)
        #expect(p.quantileLevels.count == 21 && p.quantileLevels.first == 0.01 && p.quantileLevels.last == 0.99)
        #expect(p.network.parameterCount == 119_477_664)
    }

    @Test func fiveHourRawMatchesPyTorch() throws {
        guard let p = try ChronosTestWeights.pipeline() else { return }
        let fm = try ArenaFixtures.model(Self.fixture)
        var worst = 0.0, checked = 0
        for out in fm.outputs {
            guard let d = out.detail, let want = Self.rawMatrix(d["raw"]), let ctx = Self.context(out) else { continue }
            let horizon = Int(d["horizon_steps"]?.number ?? 0)
            let got = try ArenaChronos.quantiles(p, context: [[ctx]], horizon: horizon).curve()
            Self.check(got, want, "five-hour \(out.case)", worst: &worst)
            checked += 1
        }
        // c06 sits at 100: flat, no network call, no raw.
        #expect(checked == 9)
        print("Chronos-2 five-hour raw parity: \(checked) cases, worst |Δ|/max(1,|x|) = \(worst)")
    }

    @Test func weeklyRawMatchesPyTorch() throws {
        guard let p = try ChronosTestWeights.pipeline() else { return }
        let fm = try ArenaFixtures.model(Self.fixture)
        let ref = try Self.raw()
        #expect(ref.levels == p.quantileLevels)
        var worst = 0.0
        for w in ref.weekly {
            let out = try #require(fm.outputs.first { $0.case == w.case })
            let ctx = try #require(Self.context(out))
            #expect(ctx.count == 672)
            let curve = try ArenaChronos.quantiles(p, context: [[ctx]], horizon: w.horizon).curve()
            Self.check(w.steps.map { curve[$0] }, w.raw, "weekly \(w.case)", worst: &worst)
        }
        #expect(ref.weekly.count == 10)
        print("Chronos-2 weekly raw parity: \(ref.weekly.count) cases, worst |Δ|/max(1,|x|) = \(worst)")
    }

    /// The group attention with more than one row: two variates of one
    /// series mix; two series in one batch do not (except where both
    /// tokens are masked, which these contexts never are at once).
    @Test func multiRowMatchesPyTorch() throws {
        guard let p = try ChronosTestWeights.pipeline() else { return }
        let fm = try ArenaFixtures.model(Self.fixture)
        let m = try Self.raw().multi
        let ctxs = m.cases.compactMap { c in fm.outputs.first { $0.case == c }.flatMap(Self.context) }
        try #require(ctxs.count == 2)
        var worst = 0.0
        let mv = try ArenaChronos.quantiles(p, context: [ctxs], horizon: m.horizon)
        for vi in 0..<2 { Self.check(m.steps.map { mv.curve(0, vi)[$0] }, m.multivariate[vi], "multivariate v\(vi)", worst: &worst) }
        let bt = try ArenaChronos.quantiles(p, context: ctxs.map { [$0] }, horizon: m.horizon)
        for bi in 0..<2 { Self.check(m.steps.map { bt.curve(bi, 0)[$0] }, m.batch[bi], "batch b\(bi)", worst: &worst) }
        print("Chronos-2 multi-row raw parity: worst |Δ|/max(1,|x|) = \(worst)")
    }

    /// The meter arithmetic after the network, from the fixture's own raw
    /// (five-hour cases), to 1e-6.
    @Test func meterQuantilesFromTheFixturesRaw() throws {
        let cases = try ArenaFixtures.cases().cases
        let fm = try ArenaFixtures.model(Self.fixture)
        var worst = 0.0, checked = 0
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
            for (li, lv) in out.levels.enumerated() {
                for (j, row) in q.enumerated() {
                    let got = ArenaMath.interp(lv, xs: levels, ys: row)
                    let want = out.quantiles[li][j]
                    worst = max(worst, abs(got - want))
                    #expect(abs(got - want) <= 1e-6, "case \(out.case) level \(lv) grid \(j): \(got) vs \(want)")
                }
            }
            checked += 1
        }
        #expect(checked == 9)
        print("Chronos-2 meter quantiles from the fixture's raw: worst |Δ| = \(worst)")
    }

    @Test func horizonPastOnePassThrows() throws {
        guard let p = try ChronosTestWeights.pipeline() else { return }
        #expect(throws: ArenaError.self) {
            try p.predictQuantiles(context: [[[Float](repeating: 1, count: 64)]], predictionLength: 1025)
        }
    }
}
