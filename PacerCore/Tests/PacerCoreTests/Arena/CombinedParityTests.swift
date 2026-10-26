import Foundation
import Testing
@testable import PacerCore

/// g1-08-opus-fm and g2-06-opus-fmgate2 (meter targets) against the arena's
/// Python, on the port fixtures' synthetic spend cases (`cases-spend.json`:
/// readings and pseudo-turns), with the Python's own outputs in
/// `comb-g1-08-opus-fm.json` / `comb-g2-06-opus-fmgate2.json`.
///
/// How those were made: `gen_comb_fixtures.py` (kept with the port's
/// hand-back, not in the repo) run from `research/arena` with
/// `uv run --extra fm`, on `cases-spend.json` rebuilt by
/// `arena.cli_portfix.snapshot_from_case` (no snapshot read), Timestral-123M
/// at the pinned revision. Per case and model:
///
/// - `detail.det`: the model with its two random steps pinned (a tied PIT
///   read at the middle of its tie, u = 0.5; no rationing) and a stable sort
///   in `fmcal.wquantile`, so it is exact given the network: the calibrated
///   quantiles (`out` columns at ALPHA indices `cols`), the calibration's maps
///   and effective counts, the self-backtest's cuts and PIT records; g2-06
///   adds the gate's deterministic pieces (idle time, block, resume weights);
/// - `quantiles` / `mc_bounds`: the model as is, 4000 paths, read_sorted at
///   the fixtures' levels ∓ 4√2 standard errors. Those bounds assume
///   independent paths; here every path shares one calibration, itself
///   random (tied PITs), so the Swift estimate is expected outside them at
///   some points: the test reports how many and bounds the error loosely.
///
/// The offline prior is read from the in-repo `model.toml` (it is not in
/// the registered config: see `CombinedModels.swift`).
@Suite struct CombinedParityTests {
    static let outLevels = KitDetQ.levelsOut

    // MARK: - Fixtures and setup

    static var weightsHere: Bool { TimestralTestWeights.url(FMWeights.timestral123M) != nil }

    /// `[config.meter.prior]` of models/g1-08-opus-fm/model.toml, parsed.
    static func prior() throws -> ArenaValue {
        let url = TimestralTestWeights.repoRoot.appendingPathComponent("research/arena/models/g1-08-opus-fm/model.toml")
        let text = try String(contentsOf: url, encoding: .utf8)
        var section: [String] = []
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("[config.") { inside = line == "[config.meter.prior]"; continue }
            if inside { section.append(line) }
        }
        func numbers(_ s: Substring) -> [Double] {
            s.split(whereSeparator: { ",[] ".contains($0) }).compactMap { Double($0) }
        }
        var table: [String: ArenaValue] = [:]
        var key: String?
        var rows: [ArenaValue] = []
        for line in section {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if let eq = t.firstIndex(of: "="), key == nil {
                let k = t[..<eq].trimmingCharacters(in: .whitespaces)
                let rest = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if rest == "[" { key = k; rows = [] } else { table[k] = .array(numbers(rest[...]).map { .double($0) }) }
            } else if key != nil {
                if t == "]" { table[key!] = .array(rows); key = nil } else { rows.append(.array(numbers(t[...]).map { .double($0) })) }
            }
        }
        #expect(table["levels"]?.array?.count == 25)
        #expect(table["five_hour"]?.array?.count == 14)
        #expect(table["seven_day"]?.array?.count == 16)
        return .table(table)
    }

    /// The registered meter config plus the prior (and overrides).
    static func meterConfig(ration: Bool = true) throws -> ArenaValue {
        guard case .table(var t) = ArenaRegistry.g108MeterConfig else { fatalError() }
        t["prior"] = try prior()
        if !ration { t["ration"] = false }
        return .table(t)
    }

    static func g108Spec(ration: Bool = true) throws -> ArenaModelSpec {
        let base = ArenaRegistry.spec("g1-08-opus-fm")!
        var s = base
        s.config = ["meter": try meterConfig(ration: ration)]
        return s
    }

    static func g206Spec() throws -> ArenaModelSpec {
        var s = ArenaRegistry.spec("g2-06-opus-fmgate2")!
        var c = s.config.values
        c["g108"] = ["meter": try meterConfig()]
        s.config = ArenaConfig(c)
        return s
    }

    static func cases() throws -> [String: ArenaFixtures.Case] {
        Dictionary(uniqueKeysWithValues: try ArenaFixtures.cases("cases-spend").cases.map { ($0.id, $0) })
    }

    static func request(_ c: ArenaFixtures.Case, nPaths: Int) -> ArenaRequest {
        var r = ArenaFixtures.request(c)
        r.targets[0].nPaths = nPaths
        return r
    }

    static func matrix(_ v: JSONValue?) -> [[Double]] {
        v?.array?.map { $0.array?.map { $0.number ?? .nan } ?? [] } ?? []
    }

    /// A G108 instance on `h` (its MeterFM reachable, for the det mode).
    static func instance(_ spec: ArenaModelSpec, runner: ArenaRunner, history h: ArenaHistory) throws -> G108OpusFM {
        let ctx = ArenaContext(spec: spec, seed: 42, services: TimestralTestWeights.services(), runner: runner,
                               history: { h })
        let m = try G108OpusFM(context: ctx)
        m.fit(h)
        return m
    }

    // MARK: - Pure pieces

    @Test func pitAndWquantile() {
        let lv = [0.0, 0.1, 0.5, 0.9, 1.0]
        let row = [10.0, 10.0, 12.0, 16.0, 20.0]
        #expect(FMCal.pit(lv, row, 9, 0.3) == 0)
        #expect(FMCal.pit(lv, row, 21, 0.3) == 1)
        // A tie on levels 0 and 0.1: mass from 0 to the midpoint (0.1+0.5)/2.
        #expect(abs(FMCal.pit(lv, row, 10, 0.5) - 0.15) < 1e-12)
        #expect(abs(FMCal.pit(lv, row, 14, 0.9) - 0.7) < 1e-12)
        let q = FMCal.wquantile([0.2, 0.1, 0.4], [1, 1, 2], [0.0, 0.25, 0.5, 1.0])
        // c = [(1-0.5)/4, (2-0.5)/4, (4-1)/4] over x sorted [0.1, 0.2, 0.4]
        #expect(abs(q[1] - (0.1 + (0.25 - 0.125) / 0.25 * 0.1)) < 1e-12)
        #expect(q[0] == 0.1 && q[3] == 0.4)
    }

    @Test func gatePathsMatchPython() throws {
        let doc = try JSONDecoder().decode(GateUnitDoc.self, from: Data(contentsOf: ArenaFixtures.url("comb-g2-06-opus-fmgate2")))
        let u = doc.gate_unit
        let tau = u.tau.map { $0 ?? .infinity }
        for (mode, want) in [("shift", u.shift), ("cut", u.cut)] {
            let got = Gate.gatePaths(u.base, grid: u.grid, now: u.now, u0: u.u0, tau: tau, mode: mode)
            for (g, w) in zip(got.joined(), want.joined()) { #expect(abs(g - w) < 1e-9, "\(mode): \(g) vs \(w)") }
        }
    }

    struct GateUnitDoc: Decodable {
        struct Unit: Decodable {
            let now: Int64, grid: [Int64], u0: Double, base: [[Double]], tau: [Double?], shift: [[Double]], cut: [[Double]]
        }
        let gate_unit: Unit
    }

    /// The gate's deterministic inputs on every case: the meter now, the
    /// account's idle time, the block, and the resume table's weights.
    @Test func gatePiecesMatchPython() throws {
        let cases = try Self.cases()
        let fm = try ArenaFixtures.model("comb-g2-06-opus-fmgate2")
        var worstP = 0.0, checked = 0
        for out in fm.outputs {
            let c = try #require(cases[out.case])
            guard let g = out.detail?["det"]?["gate"] else { Issue.record("no gate detail \(out.case)"); continue }
            let h = ArenaFixtures.history(c)
            let tr = ArenaFixtures.request(c).targets[0]
            let now = c.request.now
            let wk = MeterFM.windowFor[tr.target]!
            let gcfg = ArenaRegistry.spec("g2-06-opus-fmgate2")!.config.table("gate").table(wk)
            let m = KitBaselines.meterNow(h, tr)
            #expect(m.util.last.map { abs($0 - (g["u0"]?.number ?? .nan)) < 1e-6 } ?? (g["u0"]?.number == nil), "\(out.case) u0")
            let book = Gate.TurnBook(h)
            let T = book.times(c.inputs.account).filter { $0 <= now }
            #expect(T.count == Int(g["n_turns"]?.number ?? -1), "\(out.case) turns")
            let d = Gate.idleMs(T, now)
            #expect(g["idle_ms"]?.number.map { $0 == d } ?? d.isInfinite, "\(out.case) idle")
            #expect(try Gate.blockedUntil(h, account: c.inputs.account, now: now) == Millis(g["blocked_until"]?.number ?? -1))
            let tz = Double(KitSpend.tzOffsetMs(h, account: c.inputs.account))
            #expect(tz == g["tz_ms"]?.number)
            if let resid = g["resid"]?.numbers, let p = g["p"]?.numbers {
                let tab = try #require(Gate.resumeTable(T, other: [], now: now, d: d, tzMs: tz, cfg: gcfg))
                #expect(tab.resid.count == resid.count)
                for (a, b) in zip(tab.resid, resid) { #expect(abs(a - (b ?? .nan)) < 1e-6) }
                for (a, b) in zip(tab.p, p) { worstP = max(worstP, abs(a - (b ?? .nan))); #expect(abs(a - (b ?? .nan)) < 1e-12) }
                checked += 1
            }
        }
        print("g2-06 gate pieces: \(fm.outputs.count) cases, \(checked) with a resume table, worst |Δp| = \(worstP)")
    }

    // MARK: - Deterministic mode, end to end

    /// The self-backtest's cuts (meta exact, network rows within the
    /// Timestral float32 tolerance), the PIT records, the calibration and
    /// the calibrated quantiles, every case, with ties at u = 0.5 and no
    /// rationing (the fixtures' det mode).
    @Test(arguments: [false, true])
    func g108DeterministicMatchesPython(relative: Bool) throws {
        guard Self.weightsHere else { print("g1-08: Timestral-123M weights not on this Mac, skipped"); return }
        let cases = try Self.cases()
        let fm = try ArenaFixtures.model("comb-g1-08-opus-fm")
        let spec = try Self.g108Spec(ration: false)
        let runner = ArenaRunner(registry: [spec], services: TimestralTestWeights.services())
        var worstOut = 0.0, worstBq = 0.0, worstPit = 0.0, worstMap = 0.0, pitMoved = 0, pits = 0
        var lines: [String] = []
        for out in fm.outputs {
            let c = try #require(cases[out.case])
            let det = try #require(out.detail?["det"])
            let h = ArenaFixtures.history(c)
            let tr = Self.request(c, nPaths: 200).targets[0]
            let model = try Self.instance(spec, runner: runner, history: h)
            model.meters.tieU01 = 0.5
            model.meters.relativeNetwork = relative
            let L = try model.meters.levels(h, now: c.request.now, tr)
            let bt = try #require(L.base.backtest)
            // The cuts.
            let live = bt.cuts.compactMap(\.cut)
            #expect(bt.cuts.count == Int(det["n_cand"]?.number ?? -1), "\(out.case) candidates")
            #expect(live.map(\.c) == (det["cut_times"]?.numbers ?? []).map { Millis($0 ?? -1) }, "\(out.case) cut times")
            let rowsWanted = (det["cut_rows"]?.numbers ?? []).map { Int($0 ?? -1) }
            for (k, want) in (det["cuts"]?.array ?? []).enumerated() where k < live.count {
                let cut = live[k]
                #expect(abs(cut.cLast - (want["c_last"]?.number ?? .nan)) < 1e-6)
                #expect(abs(cut.usedC - (want["used_c"]?.number ?? .nan)) < 1e-6)
                #expect(cut.resetC == Millis(want["reset_c"]?.number ?? -1))
                #expect(abs(cut.phase - (want["phase"]?.number ?? .nan)) < 1e-6)
                #expect(abs(cut.act - (want["act"]?.number ?? .nan)) < 1e-6)
                let wbq = Self.matrix(want["bq"])
                for (ri, r) in rowsWanted.enumerated() {
                    guard let mine = bt.rows.firstIndex(of: r) else { continue }
                    for (a, b) in zip(cut.bq[mine], wbq[ri]) {
                        let e = abs(Double(a) - b) / max(1, abs(b))
                        worstBq = max(worstBq, e)
                        #expect(e <= 1e-3, "\(out.case) cut \(k) row \(r): \(a) vs \(b)")
                    }
                }
            }
            // The records.
            let recs = bt.records(L.base.series, now: c.request.now, u01: { 0.5 })
            let wli = (det["records"]?["li"]?.numbers ?? []).map { Int($0 ?? -1) }
            let wpit = det["records"]?["pit"]?.numbers ?? []
            #expect(recs.li == wli, "\(out.case) record leads")
            for (a, b) in zip(recs.pit, wpit) {
                let e = abs(a - (b ?? .nan))
                worstPit = max(worstPit, e); pits += 1
                if e > 1e-4 { pitMoved += 1 }
            }
            // The calibration.
            let cal = try #require(L.calibration)
            let cols = (det["cols"]?.numbers ?? []).map { Int($0 ?? 0) }
            let wmaps = Self.matrix(det["cal_maps"])
            for (i, row) in wmaps.enumerated() {
                for (k, a) in cols.enumerated() { worstMap = max(worstMap, abs(cal.maps[i][a] - row[k])) }
            }
            // The calibrated quantiles.
            let got = try #require(L.out)
            let want = Self.matrix(det["out_cols"])
            var caseWorst = 0.0
            for (k, a) in cols.enumerated() {
                for j in 0..<got.count { caseWorst = max(caseWorst, abs(got[j][a] - want[k][j])) }
            }
            worstOut = max(worstOut, caseWorst)
            lines.append("\(out.case) \(c.inputs.window_kind): \(live.count) cuts, \(recs.pit.count) PITs, worst |Δout| \(String(format: "%.4g", caseWorst))")
        }
        print("g1-08 det parity (\(relative ? "relative" : "raw") contexts)\n" + lines.joined(separator: "\n"))
        print(String(format: "g1-08 det, \(relative ? "relative" : "raw") contexts: worst |Δ| bq (rel) %.3g, PIT %.3g (%d of %d PITs moved > 1e-4), map %.3g, quantiles %.4g points",
                     worstBq, worstPit, pitMoved, pits, worstMap, worstOut))
        // Raw contexts, as the Python: the network's float32 noise carried through (the
        // Timestral meters' ~0.01 points). Relative contexts (the app's default): the same
        // network answer to float32 noise, rounded back at the raw magnitude, but a value a hair
        // from a rounding boundary can land on the other side and make or break a tie, which
        // moves that PIT by up to half the tie: the fixtures show 2 such PITs in 9153, 0.06
        // points on the quantiles.
        #expect(worstOut <= (relative ? 0.1 : 0.01))
        #expect(pitMoved <= (relative ? 5 : 0))
    }

    /// The registered config's path: no offline prior, so a lead with too
    /// few PITs takes the nearest shorter lead's map (`comb-g1-08-opus-fm-
    /// noprior.json`: the Python with `prior` removed, deterministic mode).
    @Test(arguments: [false, true])
    func g108WithoutPriorMatchesPython(relative: Bool) throws {
        guard Self.weightsHere else { return }
        let cases = try Self.cases()
        let fm = try ArenaFixtures.model("comb-g1-08-opus-fm-noprior")
        var spec = ArenaRegistry.spec("g1-08-opus-fm")!
        guard case .table(var t) = ArenaRegistry.g108MeterConfig else { fatalError() }
        t["ration"] = false
        spec.config = ["meter": .table(t)]
        let runner = ArenaRunner(registry: [spec], services: TimestralTestWeights.services())
        var worstOut = 0.0, worstMap = 0.0, worstN = 0.0
        for out in fm.outputs {
            let c = try #require(cases[out.case])
            let det = try #require(out.detail?["det"])
            let h = ArenaFixtures.history(c)
            let tr = Self.request(c, nPaths: 200).targets[0]
            let model = try Self.instance(spec, runner: runner, history: h)
            model.meters.tieU01 = 0.5
            model.meters.relativeNetwork = relative
            let L = try model.meters.levels(h, now: c.request.now, tr)
            let cols = (det["cols"]?.numbers ?? []).map { Int($0 ?? 0) }
            let cal = try #require(L.calibration)
            for (i, row) in Self.matrix(det["cal_maps"]).enumerated() {
                for (k, a) in cols.enumerated() { worstMap = max(worstMap, abs(cal.maps[i][a] - row[k])) }
            }
            for (a, b) in zip(cal.n, det["cal_n"]?.numbers ?? []) { worstN = max(worstN, abs(a - (b ?? .nan))) }
            let got = try #require(L.out)
            let want = Self.matrix(det["out_cols"])
            for (k, a) in cols.enumerated() { for j in 0..<got.count { worstOut = max(worstOut, abs(got[j][a] - want[k][j])) } }
        }
        print(String(format: "g1-08 without prior, %@ contexts: worst |Δ| map %.3g, n %.3g, quantiles %.4g points",
                     relative ? "relative" : "raw", worstMap, worstN, worstOut))
        #expect(worstOut <= (relative ? 0.1 : 0.01))
    }

    /// g2-06's shrink and rounding over the same deterministic paths, on the
    /// weekly cases (its weekly gate is off, so nothing else draws).
    @Test func g206WeeklyDeterministicMatchesPython() throws {
        guard Self.weightsHere else { return }
        let cases = try Self.cases()
        let fm = try ArenaFixtures.model("comb-g2-06-opus-fmgate2")
        let spec = try Self.g108Spec(ration: false)
        let runner = ArenaRunner(registry: [spec], services: TimestralTestWeights.services())
        let gspec = try Self.g206Spec()
        var worst = 0.0, off = 0, total = 0
        for out in fm.outputs {
            let c = try #require(cases[out.case])
            guard c.inputs.window_kind == "seven_day" else { continue }
            let h = ArenaFixtures.history(c)
            let tr = Self.request(c, nPaths: 200).targets[0]
            let model = try Self.instance(spec, runner: runner, history: h)
            model.meters.tieU01 = 0.5
            let L = try model.meters.levels(h, now: c.request.now, tr)
            let outQ = try #require(L.out)
            let paths = (0..<200).map { a in outQ.map { $0[a] } }
            let ctx = ArenaContext(spec: gspec, seed: 1, services: TimestralTestWeights.services(), runner: runner,
                                   history: { h })
            let g = try G206OpusFMGate2(context: ctx)
            g.fit(h)
            let post = try g.meterPost(tr, ArenaTargetForecast(paths: paths), now: c.request.now, history: h)
            let P = try #require(post.paths)
            let cols = (out.detail?["det"]?["cols"]?.numbers ?? []).map { Int($0 ?? 0) }
            let want = Self.matrix(out.detail?["det"]?["out_cols"])
            for j in 0..<tr.grid.count {
                let col = P.map { $0[j] }.sorted()
                for (k, a) in cols.enumerated() {
                    let e = abs(col[a] - want[k][j])
                    worst = max(worst, e); total += 1
                    if e > 1e-9 { off += 1 }
                }
            }
        }
        print("g2-06 weekly det: \(off) of \(total) whole-point values differ (rounding a value within float noise of .5), worst \(worst)")
        #expect(worst <= 1.0)
        #expect(Double(off) <= 0.01 * Double(max(total, 1)))
    }

    /// The cut memo is keyed on the context relative to its latest value, so
    /// a view whose start moves later (the app's slides every few minutes)
    /// still finds every cut whose context it holds whole; and g2-06 asked
    /// on g1-08's history cut computes nothing.
    @Test func cutMemoSurvivesASlidingStart() throws {
        guard Self.weightsHere else { return }
        let c = try #require(try Self.cases()["s01"])
        let spec = try Self.g108Spec()
        let runner = ArenaRunner(registry: [spec], services: TimestralTestWeights.services())
        let cache = FMCalCutCache(capacity: 4096)
        let h = ArenaFixtures.history(c)
        let tr = Self.request(c, nPaths: 200).targets[0]
        let a = try Self.instance(spec, runner: runner, history: h)
        a.meters.cutCache = cache
        let first = try #require(try a.meters.levels(h, now: c.request.now, tr).base.backtest)
        let computed = cache.misses
        #expect(computed == first.cuts.compactMap(\.cut).count)
        // Two days later start: the cumulative burn restarts lower.
        let later = ArenaHistory(store: h.store, now: h.now, accounts: h.accounts, start: c.inputs.history_start + 2 * ArenaTime.day)
        let b = try Self.instance(spec, runner: runner, history: later)
        b.meters.cutCache = cache
        let second = try #require(try b.meters.levels(later, now: c.request.now, tr).base.backtest)
        let reused = cache.hits
        let stillWhole = second.cuts.compactMap(\.cut).filter { $0.c - Millis(second.ctxN) * second.step >= later.historyStart + 6 * ArenaTime.hour }
        print("sliding start: \(computed) cuts computed, then \(reused) of \(second.cuts.compactMap(\.cut).count) answered from the memo (\(stillWhole.count) with a whole context)")
        #expect(reused >= stillWhole.count)
        let old = Dictionary(uniqueKeysWithValues: first.cuts.compactMap(\.cut).map { ($0.c, $0) })
        for cut in stillWhole { #expect(old[cut.c]?.bq == cut.bq, "cut \(cut.c)") }
        // g2-06 on the first cut: the network part is the history cut's memo.
        let gctx = ArenaContext(spec: try Self.g206Spec(), seed: 3, services: TimestralTestWeights.services(), runner: runner,
                                history: { h })
        let g = try G206OpusFMGate2(context: gctx)
        g.fm.cutCache = cache
        g.fit(h)
        let before = (cache.hits, cache.misses)
        _ = try g.forecast(Self.request(c, nPaths: 200))
        #expect(cache.hits == before.0 && cache.misses == before.1, "g2-06 reused g1-08's backtest on the same cut")
    }

    // MARK: - As is, Monte-Carlo

    /// The Swift estimate (4000 paths, seed 42) against the Python's bounds;
    /// and, since one calibration is shared by every path of a forecast,
    /// against the spread of the forecast itself over `seeds` seeds: a point
    /// outside the bounds is a parity miss only when the Python's value is
    /// also outside what the Swift model gives over those seeds (± the MC
    /// half-width).
    static func mcCompare(_ model: String, spec: ArenaModelSpec, nPaths: Int = 4000, seeds: Int = 8) throws
        -> (outside: Int, outsideEnvelope: Int, total: Int, worst: Double, lines: [String]) {
        let cases = try Self.cases()
        let fm = try ArenaFixtures.model(model)
        var outside = 0, outsideEnv = 0, total = 0, worst = 0.0
        var lines: [String] = []
        for out in fm.outputs {
            let c = try #require(cases[out.case])
            let req = Self.request(c, nPaths: nPaths)
            let G = c.request.grid.count
            var runs: [[[Double]]] = []                                     // [seed][level][G]
            for k in 0..<seeds {
                let runner = ArenaRunner(registry: [spec], services: TimestralTestWeights.services(), seed: UInt64(42 + k),
                                         nPaths: nPaths)
                let fc = try runner.forecast(model: spec.name, history: ArenaFixtures.history(c), request: req)
                let paths = try #require(fc.byKey[c.request.key]?.paths)
                let sorted = (0..<G).map { j in paths.map { $0[j] }.sorted() }
                runs.append(Self.outLevels.map { lv in (0..<G).map { KitDetQ.readSorted(sorted[$0], lv) } })
            }
            let bounds = try #require(out.mc_bounds)
            var o = 0, oe = 0, cw = 0.0
            for li in Self.outLevels.indices {
                for j in 0..<G {
                    let v = runs[0][li][j], w = out.quantiles[li][j]
                    total += 1
                    cw = max(cw, abs(v - w))
                    guard v < bounds.lo[li][j] - 1e-9 || v > bounds.hi[li][j] + 1e-9 else { continue }
                    o += 1
                    let half = max(w - bounds.lo[li][j], bounds.hi[li][j] - w)
                    let lo = runs.map { $0[li][j] }.min()! - half, hi = runs.map { $0[li][j] }.max()! + half
                    if w < lo - 1e-9 || w > hi + 1e-9 { oe += 1 }
                }
            }
            outside += o
            outsideEnv += oe
            worst = max(worst, cw)
            lines.append("\(out.case) \(c.inputs.window_kind): \(o) of \(Self.outLevels.count * G) outside the bounds, \(oe) outside the seed envelope, worst |Δ| \(String(format: "%.3g", cw))")
        }
        return (outside, outsideEnv, total, worst, lines)
    }

    @Test func g108MonteCarloMatchesPython() throws {
        guard Self.weightsHere else { return }
        let r = try Self.mcCompare("comb-g1-08-opus-fm", spec: try Self.g108Spec())
        print("g1-08 as is (4000 paths): \(r.outside) of \(r.total) points outside the MC bounds, \(r.outsideEnvelope) outside the 8-seed envelope, worst |Δ| \(r.worst)\n"
              + r.lines.joined(separator: "\n"))
        // Bounds assume independent paths; the shared random calibration widens the true spread,
        // so the strict check is the seed envelope (the spec's 0.5 % allowance).
        #expect(Double(r.outside) <= 0.05 * Double(r.total))
        #expect(Double(r.outsideEnvelope) <= 0.005 * Double(r.total))
        #expect(r.worst <= 6)
    }

    @Test func g206MonteCarloMatchesPython() throws {
        guard Self.weightsHere else { return }
        let r = try Self.mcCompare("comb-g2-06-opus-fmgate2", spec: try Self.g206Spec())
        print("g2-06 as is (4000 paths): \(r.outside) of \(r.total) points outside the MC bounds, \(r.outsideEnvelope) outside the 8-seed envelope, worst |Δ| \(r.worst)\n"
              + r.lines.joined(separator: "\n"))
        #expect(Double(r.outside) <= 0.05 * Double(r.total))
        #expect(Double(r.outsideEnvelope) <= 0.005 * Double(r.total))
        #expect(r.worst <= 6)
    }
}
