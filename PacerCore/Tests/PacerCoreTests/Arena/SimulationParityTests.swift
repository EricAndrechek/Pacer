import Foundation
import Testing
@testable import PacerCore

/// The simulation ports (g2-08-fable-burst, g2-07-opus-limit) against the
/// arena's Python on the port fixtures' own synthetic cases.
///
/// No `arena port-fixtures` output exists for simulations (`kit.detq` has no
/// deterministic quantiles for them), so the references in
/// `ArenaFixtures/sim-*.json` were made by running each Python model through
/// the same in-process harness on `snapshot_from_case(case)` with 4000 paths
/// (`detq.MC_PATHS`), quantiles and `mc_bounds` as `detq.from_sampled` makes
/// them (the estimate ∓ 4√2 standard errors of an n-path quantile), by
/// `ArenaFixtures/sim-generator.py` (its docstring has the commands).
///
/// Deterministic intermediates (the state now, rates, hazards, ceilings)
/// must match to the decimals stored; the quantiles, from two independent
/// random streams, must fall inside the bounds at all but 0.5 % of the
/// (level, grid time) points (port-spec § Tolerances).
@Suite struct SimulationParityTests {
    static let mcPaths = 4000
    static let maxOutside = 0.005

    @Test func fableBurstMatchesTheArenaOnSpendCases() throws {
        let cov = try SimParity.fableBurst(cases: "cases-spend", reference: "sim-g2-08-fable-burst-spend")
        print("g2-08-fable-burst (spend cases): \(cov.summary)")
        #expect(cov.compared == 6)
        #expect(cov.fraction <= Self.maxOutside, "\(cov.summary)")
        #expect(cov.detailMismatches.isEmpty, "\(cov.detailMismatches)")
    }

    @Test func fableBurstMatchesTheArenaOnReadingOnlyCases() throws {
        // No turns in these cases: the model falls back to the times the meter rose.
        let cov = try SimParity.fableBurst(cases: "cases", reference: "sim-g2-08-fable-burst")
        print("g2-08-fable-burst (reading-only cases): \(cov.summary)")
        #expect(cov.compared == 10)
        #expect(cov.fraction <= Self.maxOutside, "\(cov.summary)")
        #expect(cov.detailMismatches.isEmpty, "\(cov.detailMismatches)")
    }

    @Test func opusLimitMatchesTheArena() throws {
        var total = SimParity.Coverage()
        for (cases, ref) in [("cases", "sim-g2-07-opus-limit"), ("cases-spend", "sim-g2-07-opus-limit-spend")] {
            let cov = try SimParity.opusLimit(cases: cases, reference: ref)
            print("g2-07-opus-limit (\(cases)): \(cov.summary)")
            total.merge(cov)
        }
        #expect(total.compared == 32)
        #expect(total.fraction <= Self.maxOutside, "\(total.summary)")
        #expect(total.detailMismatches.isEmpty, "\(total.detailMismatches)")
    }

    /// Two accounts in view: the other's history pooled into the behaviour
    /// and the ceilings at half weight, (m02) an account with no past of its
    /// own borrowing the other's burn at half scale, and (m04) a scoped
    /// weekly cap.
    @Test func opusLimitMatchesTheArenaWithTwoAccounts() throws {
        let cov = try SimParity.opusLimit(cases: "sim-cases-multi", reference: "sim-g2-07-opus-limit-multi")
        print("g2-07-opus-limit (two-account cases): \(cov.summary)")
        #expect(cov.compared == 5)
        #expect(cov.fraction <= Self.maxOutside, "\(cov.summary)")
        #expect(cov.detailMismatches.isEmpty, "\(cov.detailMismatches)")
    }

    /// The pools end to end against the Python with the real networks
    /// (Timestral-123M under the burst mix, Timestral-5M under the opus
    /// pool): the simulation child, the network child (builder C's port)
    /// and the pooling together, within the bounds. Skipped when the
    /// weights are not on this Mac.
    @Test func poolsMatchTheArenaWithTheRealNetworks() throws {
        for (pool, size, refs) in [
            (G208FableBurstMix.name, "123m", [("cases-spend", "sim-g2-08-fable-burst-mix-spend"), ("cases", "sim-g2-08-fable-burst-mix")]),
            (G207OpusPool.name, "5m", [("cases", "sim-g2-07-opus-pool"), ("cases-spend", "sim-g2-07-opus-pool-spend")]),
        ] {
            guard let id = TimestralTestWeights.ids[size], TimestralTestWeights.url(id) != nil else {
                print("\(pool): Timestral-\(size) weights not on this Mac, skipped"); continue
            }
            var cov = SimParity.Coverage()
            for (cases, ref) in refs {
                let file = try ArenaFixtures.cases(cases)
                for out in try ArenaFixtures.model(ref).outputs {
                    let c = try #require(file.cases.first { $0.id == out.case })
                    let runner = ArenaRunner(registry: ArenaRegistry.all, services: TimestralTestWeights.services())
                    let fc = try runner.forecast(model: pool, history: ArenaFixtures.history(c),
                                                 request: SimParity.request(c, nPaths: ArenaParityConstants.mcPaths))
                    let paths = try #require(fc.byKey[c.request.key]?.paths)
                    #expect(paths.count == ArenaParityConstants.mcPaths)
                    SimParity.checkQuantiles(SimParity.quantiles(paths), out, into: &cov)
                }
            }
            print("\(pool) with Timestral-\(size): \(cov.summary)")
            #expect(cov.compared == (pool == G207OpusPool.name ? 32 : 16))
            #expect(cov.fraction <= Self.maxOutside, "\(cov.summary)")
        }
    }

    /// One seed, one forecast: the runner seeds a model from (seed, name,
    /// now), so a backfill re-run reproduces every path.
    @Test func forecastsAreReproducible() throws {
        let c = try #require(try ArenaFixtures.cases("cases-spend").cases.first { $0.id == "s04" })
        for name in [G208FableBurst.name, G207OpusLimit.name] {
            func once() throws -> [[Double]] {
                let runner = ArenaRunner(registry: ArenaRegistry.simulationModels)
                let fc = try runner.forecast(model: name, history: ArenaFixtures.history(c), request: ArenaFixtures.request(c))
                return try #require(fc.byKey[c.request.key]?.paths)
            }
            let a = try once(), b = try once()
            #expect(a == b, "\(name)")
            #expect(a.count == 200)
            #expect(a.allSatisfy { p in zip(p, p.dropFirst()).allSatisfy { $0 <= $1 } && p.allSatisfy { $0 >= 0 && $0 <= 100 } })
        }
    }
}

enum SimParity {
    static let levels = [0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95]

    struct Coverage {
        var compared = 0
        var points = 0
        var outside = 0
        var skipped: [String] = []
        var worst: [String] = []
        var detailMismatches: [String] = []
        var fraction: Double { points > 0 ? Double(outside) / Double(points) : 0 }
        var summary: String {
            "\(compared) cases, \(outside)/\(points) points outside the MC bounds (\(String(format: "%.3f", 100 * fraction)) %)"
                + (skipped.isEmpty ? "" : ", skipped \(skipped)") + (worst.isEmpty ? "" : ", outside at \(worst.prefix(12))")
        }
        mutating func merge(_ o: Coverage) {
            compared += o.compared; points += o.points; outside += o.outside
            skipped += o.skipped; worst += o.worst; detailMismatches += o.detailMismatches
        }
    }

    /// `kit.calib.read_sorted`: the value at position `level · n − 0.5` of the
    /// sorted samples, linear between order statistics, clamped to the ends.
    static func readSorted(_ s: [Double], _ q: Double) -> Double {
        let n = s.count
        let pos = min(max(q * Double(n) - 0.5, 0), Double(n - 1))
        let i0 = Int(pos.rounded(.down)), i1 = min(i0 + 1, n - 1)
        let a = pos - Double(i0)
        return s[i0] * (1 - a) + s[i1] * a
    }

    static func quantiles(_ paths: [[Double]]) -> [[Double]] {
        let g = paths[0].count
        let cols = (0..<g).map { j in paths.map { $0[j] }.sorted() }
        return levels.map { q in cols.map { readSorted($0, q) } }
    }

    static func request(_ c: ArenaFixtures.Case, nPaths: Int) -> ArenaRequest {
        var r = ArenaFixtures.request(c)
        r.targets = r.targets.map { var t = $0; t.nPaths = nPaths; return t }
        return r
    }

    /// A model instance built as the runner builds one (same seed rule), so
    /// a test can read what it decided.
    static func instance<M: ArenaModel>(_ name: String, _ make: (ArenaContext) -> M, history: ArenaHistory) -> M {
        let runner = ArenaRunner(registry: ArenaRegistry.simulationModels)
        let spec = runner.registry[name]!
        let ctx = ArenaContext(spec: spec, seed: ArenaRunner.deriveSeed(runner.seed, name, history.now),
                               services: runner.services, runner: runner, history: { history })
        return make(ctx)
    }

    static func checkQuantiles(_ q: [[Double]], _ out: ArenaFixtures.Output, into cov: inout Coverage) {
        guard let b = out.mc_bounds else { return }
        cov.compared += 1
        for l in levels.indices {
            for j in q[l].indices {
                cov.points += 1
                let v = q[l][j]
                if v < b.lo[l][j] - 1e-6 || v > b.hi[l][j] + 1e-6 {          // the bounds are stored to 6 decimals
                    cov.outside += 1
                    cov.worst.append("\(out.case)@q\(levels[l])[\(j)]=\(v)∉[\(b.lo[l][j]),\(b.hi[l][j])]")
                }
            }
        }
    }

    static func near(_ a: Double, _ b: Double?, _ tol: Double) -> Bool {
        guard let b else { return false }
        return abs(a - b) <= tol + 1e-9 * max(1, abs(b))
    }

    // MARK: g2-08

    static func fableBurst(cases: String, reference: String) throws -> Coverage {
        let file = try ArenaFixtures.cases(cases)
        let ref = try ArenaFixtures.model(reference)
        var cov = Coverage()
        for out in ref.outputs {
            let c = try #require(file.cases.first { $0.id == out.case })
            let d = out.detail
            let h = ArenaFixtures.history(c)
            let m = instance(G208FableBurst.name, { G208FableBurst(context: $0) }, history: h)
            try m.fit(h)
            let fc = try m.forecast(request(c, nPaths: ArenaParityConstants.mcPaths))
            let paths = try #require(fc.byKey[c.request.key]?.paths)
            #expect(paths.count == ArenaParityConstants.mcPaths)
            if let d, d["u0"] != nil {
                let diag = m.lastDiag
                func cmp(_ k: String, _ tol: Double) {
                    let py: Double? = d[k]?.bool.map { $0 ? 1 : 0 } ?? d[k]?.number
                    if !near(diag[k] ?? .nan, py, tol) { cov.detailMismatches.append("\(out.case).\(k): swift \(diag[k] ?? .nan) py \(py ?? .nan)") }
                }
                for k in ["u0", "act", "age", "n_rec", "proxy", "n_an"] { cmp(k, 0) }
                for k in ["live", "r_hat", "r_rec", "r_cyc", "lr", "lead_h"] { cmp(k, 0.005) }
            }
            checkQuantiles(quantiles(paths), out, into: &cov)
        }
        return cov
    }

    // MARK: g2-07

    static func opusLimit(cases: String, reference: String) throws -> Coverage {
        let multi = cases.hasPrefix("sim-cases-multi")
        let file = multi ? nil : try ArenaFixtures.cases(cases)
        let multiFile = multi ? try MultiCases.load(cases) : nil
        let ref = try ArenaFixtures.model(reference)
        var cov = Coverage()
        for out in ref.outputs {
            let h: ArenaHistory, req: ArenaRequest, key: String
            if let multiFile {
                let c = try #require(multiFile.cases.first { $0.id == out.case })
                (h, req) = c.historyAndRequest(nPaths: ArenaParityConstants.mcPaths)
                key = c.request.key
            } else {
                let c = try #require(file!.cases.first { $0.id == out.case })
                h = ArenaFixtures.history(c)
                req = request(c, nPaths: ArenaParityConstants.mcPaths)
                key = c.request.key
            }
            let tr = req.targets[0]
            if let d = out.detail {
                let L = OpusLimitMeters.learn(h, now: h.now, tr, cfg: [:], memoPrefix: G207OpusLimit.name)
                let u0 = OpusLimitMeters.currentLevel(L.own, tr.resetAt)
                let free = L.ownH.level.map { $0 < min(L.c.parkFrom, 100) }
                let stay = OpusLimitMeters.stayHours(L.own, tr.resetAt, u0, h.now)
                let ce = try #require(L.ceilings)
                let post = LimitSim.ceilingPosterior(ce, uNow: u0, stayHours: stay) {
                    LimitSim.zeroBurnSurvival(L.ownH, hours: $0, step: L.step, halfLife: L.c.halfLifeDays, free: free)
                }
                let mine: [String: [Double]] = [
                    "u0": [u0], "n_steps": [Double(L.ownH.count)], "burn_sum": [L.ownH.burnSum],
                    "covered": [Double(L.ownH.covered.filter { $0 }.count)], "level_sum": [L.ownH.level.reduce(0, +)],
                    "keep": L.keepLearned, "rebase_per_step": [L.beh.rebasePerStep], "n_falls": [Double(L.nFalls)],
                    "n_tops": [Double(L.nTops)], "ceil_hazard": ce.hazard, "leak": [ce.leakPerHour],
                    "leak_late": [ce.leakLatePerHour], "stay_h": [stay],
                    "idle_h": [OpusLimitMeters.idleHours(L.own, h.now)], "n_hists": [Double(L.nHists)],
                    "borrowed": [L.borrowed ? 1 : 0], "sim_burn_sum": [L.h.burnSum],
                    "post_levels": post.levels.map(Double.init), "post_probs": post.probs,
                ]
                for (k, v) in mine {
                    let py: [Double?] = d[k]?.numbers ?? [d[k]?.number]
                    if py.count != v.count || zip(v, py).contains(where: { !near($0, $1, 5e-7) }) {
                        cov.detailMismatches.append("\(out.case).\(k): swift \(v) py \(py)")
                    }
                }
            }
            let m = instance(G207OpusLimit.name, { G207OpusLimit(context: $0) }, history: h)
            try m.fit(h)
            let fc = try m.forecast(req)
            let paths = try #require(fc.byKey[key]?.paths)
            checkQuantiles(quantiles(paths), out, into: &cov)
        }
        return cov
    }
}

/// `ArenaFixtures/sim-cases-multi.json`: two-account cases (see
/// `sim-generator.py`, `MULTI`), readings per account.
struct MultiCases: Decodable {
    struct Case: Decodable {
        let id: String
        let accounts: [String]
        let window_kind: String
        let scope_model: String?
        let history_start: Int64
        let tz_offset_min: Int?
        let readings: [String: ArenaFixtures.Readings]
        let request: ArenaFixtures.Request

        func historyAndRequest(nPaths: Int) -> (ArenaHistory, ArenaRequest) {
            var meters: [ArenaMeterID: [ArenaReading]] = [:]
            for (acct, r) in readings {
                meters[ArenaMeterID(account: acct, windowKind: window_kind, scopeModel: scope_model)] = r.t_event.indices.map { i in
                    ArenaReading(tEvent: r.t_event[i], tKnown: r.t_known[i], utilPct: r.util_pct[i],
                                 resetsAt: r.resets_at[i], active: r.state[i] == "active")
                }
            }
            let store = ArenaHistoryStore(meters: meters, spend: [:], tzOffsetMin: tz_offset_min, dataStart: history_start)
            let h = ArenaHistory(store: store, now: request.now, accounts: accounts, start: history_start)
            let tr = ArenaTargetRequest(key: request.key, target: ArenaTarget(rawValue: request.target)!,
                                        accounts: [request.account], grid: request.grid, nPaths: nPaths,
                                        cap: scope_model, resetAt: request.reset_at)
            return (h, ArenaRequest(now: request.now, accounts: accounts, targets: [tr]))
        }
    }
    let cases: [Case]

    static func load(_ name: String) throws -> MultiCases {
        try JSONDecoder().decode(MultiCases.self, from: Data(contentsOf: ArenaFixtures.url(name)))
    }
}

enum ArenaParityConstants {
    /// `kit.detq.MC_PATHS`: the references' path count.
    static let mcPaths = 4000
}
