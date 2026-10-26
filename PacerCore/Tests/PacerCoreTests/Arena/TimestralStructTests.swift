import Foundation
import Testing
@testable import PacerCore

/// `struct-timestral-5m` and its child `fm-timestral-5m-spend` against the
/// Python on the port fixtures' 12 spend cases (`struct-timestral-5m-ref.json`,
/// made by a short script over `arena.cli_portfix`'s own harness: the same
/// synthetic snapshot, cases and pseudo-turn pricing as `cases-spend.json`,
/// the child asked for 4000 paths). Checked: the meter now, the live start,
/// the rates the struct model uses, the child's quantiles (deterministic:
/// what its AR(1) paths are drawn from; float32 network tolerance), and the
/// struct model's quantiles inside the Monte-Carlo bounds of the Python's
/// own 4000 paths (the two random streams differ). Skips without the 5M
/// weights.
@Suite struct TimestralStructTests {
    struct Ref: Decodable {
        let child_paths: Int
        let cases: [Case]
        struct Case: Decodable {
            let `case`: String
            let used: Double
            let live: Double?
            let weak: Bool?
            let conv_rates: [String: Double]?
            let rates: [String: Double]
            let hours: Int
            let child: [Child]
            let levels: [Double]
            let quantiles: [[Double]]
            let mc_bounds: ArenaFixtures.Bounds
        }
        struct Child: Decodable { let levels: [Double]; let q: [[Double]] }
    }

    static func ref() throws -> Ref {
        try JSONDecoder().decode(Ref.self, from: Data(contentsOf: ArenaFixtures.url("struct-timestral-5m-ref")))
    }

    static func request(_ c: ArenaFixtures.Case, nPaths: Int) -> ArenaRequest {
        var r = ArenaFixtures.request(c)
        r.targets = r.targets.map { var t = $0; t.nPaths = nPaths; return t }
        return r
    }

    @Test func intermediatesMatchThePython() throws {
        let ref = try Self.ref()
        let cases = try ArenaFixtures.cases("cases-spend").cases
        for rc in ref.cases {
            let c = try #require(cases.first { $0.id == rc.case })
            let h = ArenaFixtures.history(c)
            let wk = c.inputs.window_kind, acct = c.inputs.account
            let s = FMSeries.meterSeries(h, account: acct, windowKind: wk, now: c.request.now)
            #expect(s.usedNow(c.request.reset_at) ?? s.lastActiveUtil ?? 0 == rc.used, "\(rc.case) used")
            let ctx = ArenaContext(spec: ArenaRegistry.spec("struct-timestral-5m")!, seed: 1, services: ArenaServices(),
                                   runner: ArenaRunner(registry: ArenaRegistry.all), history: { h })
            let model = try FMStructModel(context: ctx)
            model.fit(h)
            let (conv, fitted) = model.conversion(h, account: acct, wk: wk, cap: nil)
            #expect((conv == nil) == (rc.conv_rates == nil), "\(rc.case) conversion")
            if let conv, let want = rc.conv_rates {
                #expect(conv.weak == rc.weak, "\(rc.case) weak")
                for (f, v) in want { #expect(abs((conv.pointsPerUSD[f] ?? 0) - v) <= 1e-9 * max(1, abs(v)), "\(rc.case) \(f)") }
            }
            if conv != nil {
                let live = KitSpend.liveValue(h, account: acct, windowKind: wk)
                #expect(live.map { a in rc.live.map { abs(a - $0) < 1e-9 } ?? false } ?? (rc.live == nil), "\(rc.case) live")
            }
            var rates = fitted
            if rates.count > 1 { rates = [nil: model.blend(h, account: acct, rates: rates)] }
            #expect(rates.count == rc.rates.count, "\(rc.case) rate count")
            for (k, v) in rc.rates {
                let got = rates[k == "total" ? nil : k] ?? .nan
                #expect(abs(got - v) <= 1e-9 * max(1, abs(v)), "\(rc.case) rate \(k): \(got) vs \(v)")
            }
        }
    }

    @Test func childQuantilesMatchThePython() throws {
        guard TimestralTestWeights.url(FMWeights.timestral5M) != nil else { print("5M weights not here, skipped"); return }
        let ref = try Self.ref()
        let cases = try ArenaFixtures.cases("cases-spend").cases
        let spec = try #require(ArenaRegistry.spec("fm-timestral-5m-spend"))
        var worst = 0.0
        for rc in ref.cases {
            let c = try #require(cases.first { $0.id == rc.case })
            let h = ArenaFixtures.history(c)
            let now = c.request.now, acct = c.inputs.account
            let child = try FMSpendModel(config: spec.config, services: TimestralTestWeights.services(), seed: 1)
            child.fit(h)
            let fam: String? = rc.rates.keys.first == "total" ? nil : rc.rates.keys.first
            let tr = FMSpendModel.HourlyTarget(key: "k", accounts: [acct], family: fam,
                                               grid: (1...rc.hours).map { now + FMSeries.hourMs * Millis($0) })
            let (levels, q) = try #require(try child.hourlyQuantiles([tr], now: now)["k"])
            let want = try #require(rc.child.first)
            #expect(levels == want.levels)
            #expect(q.count == want.q.count, "\(rc.case) hours")
            for (gr, wr) in zip(q, want.q) {
                for (g, w) in zip(gr, wr) {
                    let err = abs(g - w) / max(1, abs(w))
                    worst = max(worst, err)
                    #expect(err <= 1e-3, "\(rc.case): \(g) vs \(w)")
                }
            }
        }
        print("fm-timestral-5m-spend quantiles vs Python: worst |Δ|/max(1,|x|) = \(worst)")
    }

    @Test func structQuantilesWithinMonteCarloBounds() throws {
        guard TimestralTestWeights.url(FMWeights.timestral5M) != nil else { print("5M weights not here, skipped"); return }
        let ref = try Self.ref()
        let cases = try ArenaFixtures.cases("cases-spend").cases
        var spec = try #require(ArenaRegistry.spec("struct-timestral-5m"))
        spec.config.values["child_paths"] = .int(ref.child_paths)
        let runner = ArenaRunner(registry: [spec, ArenaRegistry.spec("fm-timestral-5m-spend")!],
                                 services: TimestralTestWeights.services())
        var points = 0, outside = 0, worst = 0.0
        for rc in ref.cases {
            let c = try #require(cases.first { $0.id == rc.case })
            let fc = try runner.forecast(model: spec.name, history: ArenaFixtures.history(c),
                                         request: Self.request(c, nPaths: ref.child_paths))
            let tf = try #require(fc.byKey[c.request.key])
            #expect(tf.paths?.count == ref.child_paths)
            for (li, lv) in rc.levels.enumerated() {
                let got = tf.quantile(lv)
                for j in got.indices {
                    points += 1
                    let lo = rc.mc_bounds.lo[li][j] - 1e-6, hi = rc.mc_bounds.hi[li][j] + 1e-6
                    if got[j] < lo || got[j] > hi { outside += 1 }
                    worst = max(worst, abs(got[j] - rc.quantiles[li][j]))
                }
            }
        }
        print("struct-timestral-5m: \(outside) of \(points) points outside the MC bounds, worst |Δ| vs the Python's estimate \(worst)")
        #expect(Double(outside) <= 0.005 * Double(points))
    }
}
