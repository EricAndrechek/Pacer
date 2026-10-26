import Foundation
import Testing
@testable import PacerCore

/// g2-05-sonnet-final against the Python (`ens-g2-05.json`,
/// `ens-g2-05-layer.json`; synthetic port-fixture cases). The zero-mass
/// layer is deterministic: its inputs (the meter now, the flat share) and
/// its output on the same samples match to float precision. End to end the
/// network's float32 differences carry through.
@Suite struct EnsembleSonnetFinalTests {
    struct File: Decodable { let outputs: [Output] }
    struct Output: Decodable {
        let `case`: String
        let spend: Bool
        let b: Double?
        let flat_share: [Double]?
        let levels: [Double]
        let quantiles: [[Double]]
        let mc_quantiles: [[Double]]
        let mc_big_n: Int
        let mc_big_quantiles: [[Double]]
    }
    struct LayerFile: Decodable { let outputs: [LayerOutput] }
    struct LayerOutput: Decodable {
        let `case`: String
        let spend: Bool
        let x: [[Double]]
        let q: [[Double]]
    }

    static let name = "g2-05-sonnet-final"

    static func caseNamed(_ id: String, spend: Bool) throws -> ArenaFixtures.Case {
        try #require(try ArenaFixtures.cases(spend ? "cases-spend" : "cases").cases.first { $0.id == id })
    }

    /// A fitted instance, built as the runner builds it (the runner is
    /// returned too: a context holds it unowned).
    static func model(_ h: ArenaHistory, services: ArenaServices = ArenaServices()) throws
        -> (SonnetFinalModel, ArenaRunner) {
        let spec = try #require(ArenaRegistry.spec(name))
        let runner = ArenaRunner(registry: [spec], services: services)
        let ctx = ArenaContext(spec: spec, seed: 1, services: services, runner: runner, history: { h })
        let m = try #require(try spec.make(ctx) as? SonnetFinalModel)
        try m.fit(h)
        return (m, runner)
    }

    func maxDiff(_ a: [[Double]], _ b: [[Double]]) -> Double {
        zip(a, b).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
    }

    @Test func meterNowAndFlatShareMatch() throws {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: ArenaFixtures.url("ens-g2-05")))
        let cfg = try #require(ArenaRegistry.spec(Self.name)).config
        var worst = 0.0
        for out in file.outputs {
            let c = try Self.caseNamed(out.case, spend: out.spend)
            let h = ArenaFixtures.history(c)
            let s = FMSeries.meterSeries(h, account: c.inputs.account, windowKind: c.inputs.window_kind,
                                         scopeModel: nil, now: c.request.now)
            #expect(s.usedNow(c.request.reset_at) == out.b, "case \(out.case)")
            let fs = SonnetFinalModel.flatShare(s, now: c.request.now, resetAt: c.request.reset_at, cfg: cfg)
            #expect((fs == nil) == (out.flat_share == nil), "case \(out.case)")
            if let fs, let py = out.flat_share {
                let d = zip(fs, py).map { abs($0 - $1) }.max() ?? 0
                worst = max(worst, d)
                #expect(d < 1e-9, "case \(out.case): flat share \(fs) vs \(py)")
            }
        }
        print("g2-05 flat share: max |Δ| \(worst)")
    }

    /// The layer alone, on the Python's own (rounded) samples.
    @Test func layerIsExactOnTheSameSamples() throws {
        let file = try JSONDecoder().decode(LayerFile.self, from: Data(contentsOf: ArenaFixtures.url("ens-g2-05-layer")))
        #expect(!file.outputs.isEmpty)
        var worst = 0.0
        for out in file.outputs {
            let c = try Self.caseNamed(out.case, spend: out.spend)
            let h = ArenaFixtures.history(c)
            let (m, runner) = try Self.model(h)
            defer { withExtendedLifetime(runner) {} }
            let tr = ArenaFixtures.request(c).targets[0]
            let tf = m.layer(tr, ArenaTargetForecast(paths: out.x), now: c.request.now)
            let q = try #require(tf.paths)
            #expect(q.count == out.q.count)
            let d = maxDiff(q, out.q)
            worst = max(worst, d)
            #expect(d < 1e-6, "case \(out.case): max |Δ| \(d)")
        }
        print("g2-05 layer on the Python's samples: max |Δ| \(worst)")
    }

    /// End to end on this Mac's Timestral-123M (skipped without it): the
    /// Python's layer on its deterministic child samples, against the port.
    /// Five-hour cases are the Python's own answer (its paths are stratified,
    /// not drawn); weekly ones replace its random mixture by the exact one,
    /// and the Python's Monte-Carlo answer is reported beside it.
    @Test func endToEndWithTheNetwork() throws {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: ArenaFixtures.url("ens-g2-05")))
        guard TimestralTestWeights.url(FMWeights.timestral123M) != nil else {
            print("g2-05 end to end: Timestral-123M weights not on this Mac, skipped")
            return
        }
        let services = TimestralTestWeights.services()
        var lines: [String] = []
        var worst = 0.0
        for out in file.outputs {
            let c = try Self.caseNamed(out.case, spend: out.spend)
            let runner = ArenaRunner(registry: ArenaRegistry.all, services: services)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let fc = try runner.forecast(model: Self.name, history: ArenaFixtures.history(c),
                                         request: ArenaFixtures.request(c))
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            let tf = try #require(fc.byKey[c.request.key])
            let q = out.levels.map { tf.quantile($0) }
            let d = maxDiff(q, out.quantiles)
            let dmc = maxDiff(q, out.mc_quantiles)
            worst = max(worst, d)
            // With many paths: the Python's Monte-Carlo answer converges to
            // the port's (five-hour: it is the same, its paths stratified).
            var big = ArenaFixtures.request(c)
            big.targets[0].nPaths = out.mc_big_n
            let fcBig = try ArenaRunner(registry: ArenaRegistry.all, services: services)
                .forecast(model: Self.name, history: ArenaFixtures.history(c), request: big)
            let tfBig = try #require(fcBig.byKey[c.request.key])
            let dBig = maxDiff(out.levels.map { tfBig.quantile($0) }, out.mc_big_quantiles)
            if c.request.target == "meter.five_hour" { #expect(dBig < 0.05, "case \(out.case): \(dBig)") }
            lines.append(String(format: "%@ (%@): max |Δ| vs deterministic %.4g, vs the Python's MC %.4g (200 paths), %.4g (%d paths), %.0f ms",
                                out.case, c.request.target, d, dmc, dBig, out.mc_big_n, ms))
            // float32 network differences (about 1e-3 of a point) through
            // the layer's thresholds (a sample within delta of the reading).
            #expect(d < 0.05, "case \(out.case): max |Δ| \(d)")
        }
        print("g2-05 end to end: worst \(worst)\n  " + lines.joined(separator: "\n  "))
    }
}
