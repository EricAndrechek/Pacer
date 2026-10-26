import Foundation
import Testing
@testable import PacerCore

/// spend-decay against the Python reference (`spend-decay-30m.json`,
/// `spend-decay-6h.json` on `cases-spend.json`): the intermediates first
/// (`detail`), then the quantiles, at port-spec § Tolerances.
@Suite struct SpendDecayParityTests {
    /// Stored to 6 decimals: half a unit in the last place, plus float noise.
    static let sixDecimals = 5.0e-7 + 1e-9

    static func model(_ name: String, history h: ArenaHistory) throws -> SpendDecayModel {
        let spec = try #require(ArenaRegistry.spec(name))
        let runner = ArenaRunner(registry: ArenaRegistry.all)
        let ctx = ArenaContext(spec: spec, seed: 1, services: ArenaServices(), runner: runner, history: { h })
        let m = SpendDecayModel(context: ctx)
        m.fit(h)
        return m
    }

    struct Report { var detailMax = 0.0; var quantileMax = 0.0; var checked = 0 }

    func check(_ name: String) throws -> Report {
        let cases = Dictionary(uniqueKeysWithValues: try ArenaFixtures.cases("cases-spend").cases.map { ($0.id, $0) })
        var rep = Report()
        for o in try ArenaFixtures.model(name).outputs {
            let c = try #require(cases[o.case])
            let d = try #require(o.detail)
            let h = ArenaFixtures.history(c)
            let tr = ArenaFixtures.request(c).targets[0]
            let m = try Self.model(name, history: h)
            let p = m.parts(tr)
            let id = "\(name) \(o.case)"
            #expect(p.mode.rawValue == d["mode"]?.string, "\(id) mode")
            if p.mode != .flat {
                for (f, want) in (d["rates"]?.numbers ?? []).enumerated() {
                    let diff = abs(p.rates[f] - (want ?? .nan))
                    rep.detailMax = max(rep.detailMax, diff)
                    #expect(diff <= Self.sixDecimals, "\(id) rates[\(f)] \(p.rates[f]) vs \(want ?? .nan)")
                }
                #expect(p.weak == d["weak"]?.bool, "\(id) weak")
                let r2 = abs(p.r2 - (d["r2"]?.number ?? .nan))
                #expect(r2 <= Self.sixDecimals, "\(id) r2 \(p.r2) vs \(d["r2"]?.number ?? .nan)")
                let st = try #require(p.state)
                for (k, v) in [("now_value", st.nowValue), ("burn", st.burn), ("ratio", st.ratio), ("used", st.used)] {
                    let diff = abs(v - (d["state"]?[k]?.number ?? .nan))
                    rep.detailMax = max(rep.detailMax, diff)
                    #expect(diff <= Self.sixDecimals, "\(id) state.\(k) \(v) vs \(d["state"]?[k]?.number ?? .nan)")
                }
                #expect(abs(p.uNow - (d["u_now"]?.number ?? .nan)) <= Self.sixDecimals, "\(id) u_now")
                #expect(p.tauH == d["tau_h"]?.number, "\(id) tau_h \(p.tauH) vs \(d["tau_h"]?.number ?? .nan)")
                #expect(Double(p.nCases) == d["n_cases"]?.number, "\(id) n_cases \(p.nCases) vs \(d["n_cases"]?.number ?? .nan)")
                if p.mode == .cases {
                    #expect(Double(p.picked) == d["picked"]?.number, "\(id) picked \(p.picked) vs \(d["picked"]?.number ?? .nan)")
                }
                let centre = d["centre"]?.numbers ?? []
                #expect(centre.count == p.centre.count, "\(id) centre length")
                for (j, want) in centre.enumerated() where j < p.centre.count {
                    let diff = abs(p.centre[j] - (want ?? .nan))
                    rep.detailMax = max(rep.detailMax, diff)
                    #expect(diff <= Self.sixDecimals, "\(id) centre[\(j)] \(p.centre[j]) vs \(want ?? .nan)")
                }
            }
            #expect(o.exact)
            let q = KitDetQ.spendDecayQuantiles(p, gridCount: tr.grid.count, levels: o.levels)
            for (li, row) in o.quantiles.enumerated() {
                for (j, want) in row.enumerated() {
                    let diff = abs(q[li][j] - want)
                    rep.quantileMax = max(rep.quantileMax, diff)
                    #expect(diff <= 1e-6, "\(id) q[\(o.levels[li])][\(j)] \(q[li][j]) vs \(want)")
                }
            }
            // The model's own answer reads the same values at those levels.
            let fc = try m.forecast(ArenaFixtures.request(c))
            let tf = try #require(fc.byKey[tr.key])
            for (li, lv) in o.levels.enumerated() {
                for (a, b) in zip(tf.quantile(lv), o.quantiles[li]) { #expect(abs(a - b) <= 1e-6, "\(id) forecast at \(lv)") }
            }
            for (a, b) in zip(tf.median, o.median) { #expect(abs(a - b) <= 1e-6, "\(id) median") }
            rep.checked += 1
        }
        return rep
    }

    @Test func fiveHourMatchesThePython() throws {
        let r = try check("spend-decay-30m")
        #expect(r.checked == 6)
        print("spend-decay-30m parity: detail max |Δ| \(r.detailMax), quantile max |Δ| \(r.quantileMax)")
    }

    @Test func weeklyMatchesThePython() throws {
        let r = try check("spend-decay-6h")
        #expect(r.checked == 6)
        print("spend-decay-6h parity: detail max |Δ| \(r.detailMax), quantile max |Δ| \(r.quantileMax)")
    }

    /// The other two variants, from reference files of our own made the
    /// way `arena port-fixtures` makes them (`spend-decay-1h.json`,
    /// `spend-decay-1d.json`; the generator, which reproduces the committed
    /// -30m and -6h files exactly, is at the end of this file).
    @Test func otherVariantsMatchThePython() throws {
        let r1h = try check("spend-decay-1h")
        let r1d = try check("spend-decay-1d")
        #expect(r1h.checked == 6 && r1d.checked == 6)
        print("spend-decay-1h parity: detail \(r1h.detailMax), quantiles \(r1h.quantileMax); spend-decay-1d: detail \(r1d.detailMax), quantiles \(r1d.quantileMax)")
    }

    @Test func ndtriIsScipys() {
        // scipy.special.ndtri at these levels (printed with repr).
        #expect(abs(KitDetQ.ndtri(0.05) - -1.6448536269514729) < 1e-14)
        #expect(abs(KitDetQ.ndtri(0.0025) - -2.8070337683438042) < 1e-13)
        #expect(abs(KitDetQ.ndtri(0.9975) - 2.8070337683438114) < 1e-13)
        #expect(KitDetQ.ndtri(0.5) == 0)
    }

    @Test func forecastLevelsAreIncreasing() {
        let l = KitDetQ.forecastLevels
        #expect(l.count == 207)
        #expect(zip(l, l.dropFirst()).allSatisfy { $0 < $1 })
        #expect(KitDetQ.levelsOut.allSatisfy { l.contains($0) })
    }
}

/// The other spend models: registered as their `model.toml`s say, and
/// well-formed on every spend case (port-live-meter has no fixture).
@Suite struct SpendModelsTests {
    @Test func registeredAsTheirTomls() throws {
        let names = ArenaRegistry.spendModels.map(\.name)
        for n in ["spend-decay-30m", "spend-decay-1h", "spend-decay-6h", "spend-decay-1d", "port-live-meter"] {
            #expect(names.contains(n), "\(n) registered")
        }
        let s30 = try #require(ArenaRegistry.spec("spend-decay-30m"))
        #expect(s30.targets == [.meterFiveHour] && s30.config.int("lookback_min", 0) == 30)
        #expect(s30.config.int("case_days", 0) == 60)
        #expect(s30.config.table("default_tau_h").double("seven_day", 0) == 16)
        let s1d = try #require(ArenaRegistry.spec("spend-decay-1d"))
        #expect(s1d.targets == [.meterSevenDay, .meterScoped] && s1d.config.int("lookback_min", 0) == 1440)
        #expect(s1d.config.int("case_days", 0) == 120)
    }

    @Test func everySpendModelAnswersEveryCase() throws {
        for c in try ArenaFixtures.cases("cases-spend").cases {
            // Weights where the Timestral tests find them: a wrapper over an
            // fm-timestral model needs them (and is skipped without them).
            let runner = ArenaRunner(registry: ArenaRegistry.all, services: TimestralTestWeights.services())
            let h = ArenaFixtures.history(c)
            let req = ArenaFixtures.request(c)
            let tr = req.targets[0]
            let latest = KitBaselines.meterNow(h, tr).latest
            // A wrapper whose child is another port's runs once that port
            // is merged in.
            let known = Set(ArenaRegistry.all.map(\.name))
            for spec in ArenaRegistry.spendModels
            where spec.targets.contains(tr.target) && spec.children.allSatisfy(known.contains) {
                let chain = spec.children.compactMap { ArenaRegistry.spec($0) }.flatMap(\.weights) + spec.weights
                if chain.contains(where: { TimestralTestWeights.url($0) == nil }) { continue }
                let fc = try runner.forecast(model: spec.name, history: h, request: req)
                let tf = try #require(fc.byKey[tr.key], "\(spec.name) \(c.id)")
                #expect(tf.gridCount == tr.grid.count)
                let lo = tf.quantile(0.05), md = tf.median, hi = tf.quantile(0.95)
                for j in 0..<tr.grid.count {
                    #expect(lo[j] <= md[j] + 1e-12 && md[j] <= hi[j] + 1e-12, "\(spec.name) \(c.id) levels cross")
                    #expect(lo[j] >= latest - 1e-9 && hi[j] <= max(100, latest) + 1e-9, "\(spec.name) \(c.id) range")
                }
                #expect(zip(md, md.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 }, "\(spec.name) \(c.id) median falls")
            }
        }
    }

    /// A per-model weekly cap ("Fable"): only that family's spend is
    /// fitted, the calibration map is the cap's own kind, and both models
    /// answer the scoped target.
    @Test func scopedCapCountsItsFamilyOnly() throws {
        let (store, end) = SpendTimingTests.synthetic(days: 40, scoped: true)
        let h = ArenaHistory(store: store, now: end - 5 * ArenaTime.hour, accounts: ["S1"])
        let d = try #require(KitSpend.fitDetails(h, account: "S1", windowKind: "weekly_scoped", scopeModel: "Fable"))
        #expect(d.rates[0] > 0 && d.rates[1...].allSatisfy { $0 == 0 }, "rates \(d.rates)")
        #expect(abs(d.rates[0] - 0.4) < 0.05, "the synthetic cap moves 0.4 pt per Fable dollar: \(d.rates[0])")
        let req = ArenaRunner.request(history: h, targets: [.meterScoped])
        let tr = try #require(req.targets.first)
        #expect(tr.cap == "Fable" && tr.key == "meter.scoped:S1:Fable")
        let runner = ArenaRunner(registry: ArenaRegistry.all)
        for name in ["spend-decay-6h", "calib-spend-decay-6h"] {
            let fc = try runner.forecast(model: name, history: h, request: req)
            let tf = try #require(fc.byKey[tr.key], "\(name)")
            let m = KitBaselines.meterNow(h, tr)
            #expect(tf.median.allSatisfy { $0 >= m.latest - 1e-9 && $0 <= 100 }, "\(name)")
        }
        #expect(KitCalib.kindOf(.meterScoped, cap: "Fable") == "weekly_scoped:Fable")
    }

    @Test func refusedDayAndUnfittedModel() throws {
        let c = try ArenaFixtures.cases("cases-spend").cases[0]
        let h = ArenaFixtures.history(c)
        let tomorrow = KitSpend.localDayStart(h) + ArenaTime.day
        #expect(KitSpend.fitOnDay(h, account: c.inputs.account, windowKind: c.inputs.window_kind, scopeModel: nil,
                                  dayStart: tomorrow) == nil)
        let spec = try #require(ArenaRegistry.spec("spend-decay-30m"))
        let ctx = ArenaContext(spec: spec, seed: 1, services: ArenaServices(), runner: ArenaRunner(registry: []),
                               history: { nil })
        #expect(throws: ArenaError.self) { try SpendDecayModel(context: ctx).forecast(ArenaFixtures.request(c)) }
    }

    /// What a memoized forecast holds: equal quantile rows share storage.
    @Test func equalRowsShareStorage() throws {
        var report: [String] = []
        for c in try ArenaFixtures.cases("cases-spend").cases {
            let name = c.inputs.window_kind == "five_hour" ? "spend-decay-30m" : "spend-decay-6h"
            let runner = ArenaRunner(registry: ArenaRegistry.all)
            let req = ArenaFixtures.request(c)
            let tf = try #require(try runner.forecast(model: name, history: ArenaFixtures.history(c), request: req)
                .byKey[req.targets[0].key])
            guard let q = tf.quantiles else { continue }
            var buffers = Set<UInt>()
            for row in q { _ = row.withUnsafeBufferPointer { buffers.insert(UInt(bitPattern: $0.baseAddress)) } }
            var distinct = 1
            for i in q.indices.dropFirst() where q[i] != q[i - 1] { distinct += 1 }
            #expect(buffers.count == distinct, "case \(c.id)")
            report.append("\(c.id) \(buffers.count)/\(q.count)")
        }
        print("stored quantile rows per forecast: " + report.joined(separator: ", "))
    }
}

/* How ArenaFixtures/spend-decay-1h.json and spend-decay-1d.json were made
   (synthetic cases only), from research/arena:
   uv run python -I variants_fixture.py cases-spend.json <out-dir>

"""spend-decay-1h (five-hour cases) and spend-decay-1d (weekly cases) through
kit.detq on the SYNTHETIC spend fixture cases, as `arena port-fixtures`
writes them (same levels, same detail), without touching any snapshot.

Usage (from research/arena): uv run python -I <this> <cases-spend.json> <out-dir>
"""
import json
import sys
from pathlib import Path

import numpy as np

from arena.cli_portfix import (MODELS_DIR, Local, _arr, detail_json, fixture_pricing, snapshot_from_case)
from arena.episodes import target_key
from arena.registry import Registry
from arena.types import Request, Scope, Target, TargetRequest
from kit import detq


def main(src, out_dir):
    cases = json.load(open(src))["cases"]
    reg = Registry([MODELS_DIR])
    for name, kind in (("spend-decay-1h", "five_hour"), ("spend-decay-1d", "seven_day")):
        info = reg.load(name)
        outs = []
        for c in cases:
            inp, rq = c["inputs"], c["request"]
            if inp["window_kind"] != kind:
                continue
            acct = inp["account"]
            target = Target(rq["target"])
            small = snapshot_from_case(c)
            local = Local(small, tz_offset_min=inp["tz_offset_min"])
            grid = np.asarray(rq["grid"], dtype=np.int64)
            key = target_key(target, (acct,))
            req = Request(rq["now"], Scope((acct,), "scope_only"),
                          (TargetRequest(key, target, (acct,), grid, "pct", 200, None, None, rq["reset_at"]),))
            view = small.view(req.scope, "current_code", inp["history_start"])
            with fixture_pricing():
                model = local.instance(info, view, rq["now"])
                det = detq.quantiles(model, req, detq.LEVELS_OUT)[key]
            outs.append({"case": c["id"], "levels": list(detq.LEVELS_OUT), "quantiles": _arr(det.q),
                         "median": _arr(det.median), "exact": bool(det.exact), "mc_paths": int(det.mc_paths),
                         "detail": detail_json(dict(det.detail))})
        json.dump({"format": "pacer-arena-port-fixture/1", "spec": "docs/port-spec.md#parity", "model": name,
                   "snapshot": "cases-spend.json (synthetic, seed 42)", "seed": 42, "outputs": outs},
                  open(Path(out_dir) / f"{name}.json", "w"))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
*/
