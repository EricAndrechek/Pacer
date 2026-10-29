import Foundation
import Testing
@testable import PacerCore

/// The ensemble ports against the Python (`ArenaFixtures/ens-*.json`, made by
/// builder G's `ens_fixtures.py` from the committed port-fixture cases:
/// synthetic data only).
///
/// g1-05 runs over six deterministic stub children named as its real ones
/// (`Stub`, the twin of the fixture's `stubmodel/model.py`), so everything
/// the combiner does (backtests, ledger, scoring, the band fits, the blend,
/// the nowcast head) is compared on identical child forecasts.
@Suite struct EnsembleParityTests {
    struct StubFile: Decodable {
        let outputs: [StubOutput]
    }

    struct StubOutput: Decodable {
        let `case`: String
        let levels: [Double]
        let quantiles: [[Double]]
        let p_hit_limit: Double
        let cells: [StubCell]
        let groups: [StubGroup]
    }

    struct StubCell: Decodable {
        let kind: String
        let children: [String]
        let band: Int
        let w: [Double]
        let scale: Double
        let rise: Double
        let n: Int
    }

    struct StubGroup: Decodable {
        let origin: Int64
        let key: String
        let n_y: Int
    }

    /// `stubmodel/model.py`: the meter now plus Aᵢ · shapeᵢ(f) · multₚ, f the
    /// lead as a share of the window, multₚ = (p + 0.5) / n · 2.
    final class Stub: ArenaModel {
        static let A: [Double] = [10.0, 25.0, 5.0, 0.0, 40.0, 15.0]
        let i: Int
        var h: ArenaHistory?
        init(context: ArenaContext) { i = context.config.int("stub", 0) }
        func fit(_ history: ArenaHistory) { h = history }
        func forecast(_ request: ArenaRequest) throws -> ArenaForecast {
            var out: [String: ArenaTargetForecast] = [:]
            for tr in request.targets {
                let latest = KitBaselines.meterNow(h!, tr).latest
                let win: Millis = tr.target == .meterFiveHour ? 5 * 3_600_000 : 7 * 86_400_000
                let n = tr.nPaths
                let k = i % 3
                let shape = tr.grid.map { g -> Double in
                    let f = Double(g - request.now) / Double(win)
                    return k == 0 ? f : (k == 1 ? f.squareRoot() : f * f)
                }
                let paths = (0..<n).map { p -> [Double] in
                    let mult = (Double(p) + 0.5) / Double(n) * 2.0
                    return shape.map { min(latest + (Self.A[i] * $0) * mult, 100.0) }
                }
                out[tr.key] = ArenaTargetForecast(paths: paths)
            }
            return ArenaForecast(byKey: out)
        }
    }

    static let g105 = "g1-05-opus-ens-meter-big"

    /// The registered g1-05 (without its weights pin: the stubs need none)
    /// over the stubs; `override` hands the model the Python's cells.
    static func stubRunner(override: [String: BandedEnsemble.Cell] = [:]) throws -> ArenaRunner {
        var spec = try #require(ArenaRegistry.spec(g105))
        spec.weights = []
        let make = spec.make
        spec.make = { ctx in
            let m = try make(ctx)
            (m as? BandedEnsemble)?.cellOverride = override
            return m
        }
        let stubs = spec.children.enumerated().map { i, name in
            ArenaModelSpec(name: name, targets: spec.targets, config: ["stub": .int(i)]) { Stub(context: $0) }
        }
        return ArenaRunner(registry: [spec] + stubs)
    }

    static func caseNamed(_ id: String) throws -> ArenaFixtures.Case {
        try #require(try ArenaFixtures.cases().cases.first { $0.id == id })
    }

    func maxDiff(_ a: [[Double]], _ b: [[Double]]) -> Double {
        zip(a, b).map { zip($0, $1).map { abs($0 - $1) }.max() ?? 0 }.max() ?? 0
    }

    @Test func g105MatchesThePythonOnStubChildren() throws {
        let file = try JSONDecoder().decode(StubFile.self, from: Data(contentsOf: ArenaFixtures.url("ens-g1-05-stub")))
        var report: [String] = []
        var worstW = 0.0, worstQ = 0.0
        for out in file.outputs {
            let c = try Self.caseNamed(out.case)
            let runner = try Self.stubRunner()
            let h = ArenaFixtures.history(c)
            let req = ArenaFixtures.request(c)
            var model: BandedEnsemble?
            let spec = runner.registry[Self.g105]!
            // Run it directly (as the runner does), keeping the instance.
            let ctx = ArenaContext(spec: spec, seed: 1, services: ArenaServices(), runner: runner, history: { h })
            model = try spec.make(ctx) as? BandedEnsemble
            let m = try #require(model)
            try m.fit(h)
            let fc = try m.forecast(req)
            let tf = try #require(fc.byKey[c.request.key])
            // The ledger's groups: the same origins, the same truth counts.
            let groups = m.ledger.groups.sorted { $0.origin < $1.origin }
            #expect(groups.map(\.origin) == out.groups.map(\.origin), "case \(out.case): origins")
            #expect(groups.map(\.y.count) == out.groups.map(\.n_y), "case \(out.case): truth counts")
            // The cells: counts and spread factors exactly, weights to the
            // optimizer's tolerance.
            for pc in out.cells {
                let sc = try #require(m.cells[BandedEnsemble.cellKey(pc.kind, pc.children, pc.band)],
                                      "case \(out.case): no cell \(pc.kind) band \(pc.band)")
                #expect(sc.n == pc.n, "case \(out.case) band \(pc.band): n \(sc.n) vs \(pc.n)")
                #expect(sc.scale == pc.scale, "case \(out.case) band \(pc.band): scale \(sc.scale) vs \(pc.scale)")
                let dw = zip(sc.w, pc.w).map { abs($0 - $1) }.max() ?? 0
                worstW = max(worstW, dw)
                #expect(dw < 1e-4, "case \(out.case) band \(pc.band): weights \(sc.w) vs \(pc.w)")
            }
            let q = out.levels.map { tf.quantile($0) }
            let dq = maxDiff(q, out.quantiles)
            worstQ = max(worstQ, dq)
            #expect(abs((tf.extras["p_hit_limit"] ?? -1) - out.p_hit_limit) < 1e-12)
            report.append("\(out.case): max|Δw| \(dw(m, out)) max|Δq| \(dq)")
        }
        print("g1-05 stub parity (fitted weights): max |Δw| \(worstW), max |Δq| \(worstQ)\n  " + report.joined(separator: "\n  "))
        #expect(worstQ < 1e-3)
    }

    func dw(_ m: BandedEnsemble, _ out: StubOutput) -> Double {
        out.cells.compactMap { pc in
            m.cells[BandedEnsemble.cellKey(pc.kind, pc.children, pc.band)].map { sc in
                zip(sc.w, pc.w).map { abs($0 - $1) }.max() ?? 0
            }
        }.max() ?? 0
    }

    /// The registered g1-05 over its real children (those registered on this
    /// branch; Timestral-123M needed, skipped without it), on a five-hour
    /// spend case: it answers 200 finite paths, never falling, from the live
    /// level to 100, with its cells fitted on the children that answered.
    @Test func g105RunsOnItsRealChildren() throws {
        guard TimestralTestWeights.url(FMWeights.timestral123M) != nil else {
            print("g1-05 real children: Timestral-123M weights not on this Mac, skipped")
            return
        }
        let c = try #require(try ArenaFixtures.cases("cases-spend").cases.first { $0.id == "s04" })
        let h = ArenaFixtures.history(c)
        let runner = ArenaRunner(registry: ArenaRegistry.all, services: TimestralTestWeights.services())
        let spec = runner.registry[Self.g105]!
        let ctx = ArenaContext(spec: spec, seed: 1, services: TimestralTestWeights.services(), runner: runner,
                               history: { h })
        let m = try #require(try spec.make(ctx) as? BandedEnsemble)
        try m.fit(h)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let fc = try m.forecast(ArenaFixtures.request(c))
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let p = try #require(fc.byKey[c.request.key]?.paths)
        let level = KitMLCombine.levelAt(h.readings(account: c.inputs.account, windowKind: "five_hour"), asof: h.now)
        #expect(p.count == 200)
        #expect(p.allSatisfy { row in row.allSatisfy { $0.isFinite && $0 >= level - 1e-9 && $0 <= 100 } })
        #expect(p.allSatisfy { row in zip(row, row.dropFirst()).allSatisfy { $0 <= $1 } })
        let present = spec.children.filter { ArenaRegistry.spec($0) != nil }
        let cells = (0..<m.nb).compactMap { m.cell("five_hour", present, band: $0) }
        #expect(cells.count == m.nb)
        print(String(format: "g1-05 on its real children (%@), case s04: %.0f ms; ", present.joined(separator: ","), ms)
              + cells.map { "n=\($0.n) s=\($0.scale) w=" + $0.w.map { String(format: "%.2f", $0) }.joined(separator: "/") }
                .joined(separator: "; "))
    }

    /// A scoped weekly cap is its own kind (`weekly_scoped:<cap>`), backtested
    /// on the weekly lattice: the same readings as a weekly case, filed under
    /// a cap, give the same cells as the weekly meter does.
    @Test func g105ScopedCapIsItsOwnKind() throws {
        let c = try Self.caseNamed("c01")
        let weekly = ArenaFixtures.history(c)
        let rows = weekly.store.meters.values.first!
        let id = ArenaMeterID(account: c.inputs.account, windowKind: "weekly_scoped", scopeModel: "Fable")
        let store = ArenaHistoryStore(meters: [id: rows], spend: [:], tzOffsetMin: c.inputs.tz_offset_min,
                                      dataStart: c.inputs.history_start)
        let h = ArenaHistory(store: store, now: c.request.now, accounts: [c.inputs.account], start: c.inputs.history_start)
        let tr = try #require(ArenaRunner.targetRequest(history: h, meter: id))
        #expect(tr.key == "meter.scoped:\(c.inputs.account):Fable")
        let runner = try Self.stubRunner()
        let spec = runner.registry[Self.g105]!
        let ctx = ArenaContext(spec: spec, seed: 1, services: ArenaServices(), runner: runner, history: { h })
        let m = try #require(try spec.make(ctx) as? BandedEnsemble)
        try m.fit(h)
        let fc = try m.forecast(ArenaRequest(now: h.now, accounts: [c.inputs.account], targets: [tr]))
        #expect(fc.byKey[tr.key]?.paths?.count == 200)
        let kinds = Set(m.cells.keys.map { $0.split(separator: "|")[0] })
        #expect(kinds == ["weekly_scoped:Fable"])
        // The weekly meter's own run, for the same cells.
        let wm = try #require(try spec.make(ArenaContext(spec: spec, seed: 1, services: ArenaServices(), runner: runner,
                                                         history: { weekly })) as? BandedEnsemble)
        try wm.fit(weekly)
        _ = try wm.forecast(ArenaFixtures.request(c))
        for b in 0..<m.nb {
            let s = try #require(m.cell("weekly_scoped:Fable", m.children, band: b))
            let w = try #require(wm.cell("seven_day", wm.children, band: b))
            #expect(s.n == w.n && s.scale == w.scale && s.w == w.w, "band \(b)")
        }
    }

    /// With the Python's own cells, everything after the fit (the per-band
    /// pools, the spread factors, the band blend, the nowcast head, the
    /// floor, monotonicity) matches to float precision.
    @Test func g105AfterTheFitIsExact() throws {
        let file = try JSONDecoder().decode(StubFile.self, from: Data(contentsOf: ArenaFixtures.url("ens-g1-05-stub")))
        var worst = 0.0
        for out in file.outputs {
            let c = try Self.caseNamed(out.case)
            var override: [String: BandedEnsemble.Cell] = [:]
            for pc in out.cells {
                override[BandedEnsemble.cellKey(pc.kind, pc.children, pc.band)] =
                    BandedEnsemble.Cell(w: pc.w, scale: pc.scale, n: pc.n, rise: pc.rise)
            }
            let runner = try Self.stubRunner(override: override)
            let fc = try runner.forecast(model: Self.g105, history: ArenaFixtures.history(c),
                                         request: ArenaFixtures.request(c))
            let tf = try #require(fc.byKey[c.request.key])
            let d = maxDiff(out.levels.map { tf.quantile($0) }, out.quantiles)
            worst = max(worst, d)
            #expect(d < 1e-6, "case \(out.case): max |Δq| \(d)")
        }
        print("g1-05 stub parity (Python's cells): max |Δq| \(worst)")
    }
}
