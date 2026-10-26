import Foundation
import Testing
@testable import PacerCore

/// The live meter (`kit/spend.live_detail`), the conversion's details, the
/// hourly series and port-live-meter against the Python, on the synthetic
/// spend cases at four moments each (`ArenaFixtures/spend-live.json`, made
/// by `live_fixture.py` under `arena.cli_portfix.fixture_pricing`; its source
/// is at the end of this file). The values are stored at full precision.
@Suite struct SpendLiveParityTests {
    struct File: Decodable { let levels: [Double]; let cases: [Case] }
    struct Case: Decodable { let `case`: String; let moments: [Moment] }
    struct Moment: Decodable {
        let now: Int64
        let fit: Fit?
        let live: Live?
        let live_rates: Live?
        let hourly: [Double]?
        let port_live: PortLive?
    }
    struct Fit: Decodable {
        let rates: [Double]; let weak: Bool; let r2: Double; let pooled: Double; let own: Bool
        let rise: Double; let n_rows: Int
    }
    struct Live: Decodable {
        let shown: Double; let percent: Double; let exact: Double; let reading: Double
        let reading_t: Int64; let anchor_t: Int64; let added: Double; let spend_usd: Double
        let carry: Double; let restarted: Bool
    }
    struct PortLive: Decodable { let centre: Double; let latest: Double; let n_near: Int?; let quantiles: [Double]? }

    static func close(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol * max(1, abs(b)) }

    func checkLive(_ mine: KitSpend.LiveValue?, _ want: Live?, _ id: String) {
        #expect((mine == nil) == (want == nil), "\(id) live presence")
        guard let mine, let want else { return }
        #expect(Self.close(mine.shown, want.shown) && Self.close(mine.percent, want.percent), "\(id) shown/percent")
        #expect(Self.close(mine.exact, want.exact) && Self.close(mine.added, want.added), "\(id) exact/added \(mine.added) vs \(want.added)")
        #expect(Self.close(mine.carry, want.carry), "\(id) carry \(mine.carry) vs \(want.carry)")
        #expect(Self.close(mine.spendUSD, want.spend_usd), "\(id) usd")
        #expect(mine.reading == want.reading && mine.readingT == want.reading_t && mine.anchorT == want.anchor_t, "\(id) anchor")
        #expect(mine.restarted == want.restarted, "\(id) restarted")
    }

    @Test func liveMeterFitAndHourlyMatchThePython() throws {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: ArenaFixtures.url("spend-live")))
        let cases = Dictionary(uniqueKeysWithValues: try ArenaFixtures.cases("cases-spend").cases.map { ($0.id, $0) })
        var moments = 0, lives = 0, portLives = 0
        for fc in file.cases {
            let c = try #require(cases[fc.case])
            let full = ArenaFixtures.history(c)
            let acct = c.inputs.account, kind = c.inputs.window_kind
            for m in fc.moments {
                let h = full.asOf(m.now)
                let id = "\(fc.case) @\(m.now)"
                let d = KitSpend.fitDetails(h, account: acct, windowKind: kind)
                #expect((d == nil) == (m.fit == nil), "\(id) fit presence")
                if let d, let f = m.fit {
                    #expect(d.conversion.weak == f.weak && d.own == f.own && d.nRows == f.n_rows, "\(id) fit flags")
                    #expect(zip(d.rates, f.rates).allSatisfy { Self.close($0, $1) }, "\(id) rates \(d.rates) vs \(f.rates)")
                    #expect(Self.close(d.conversion.r2, f.r2) && Self.close(d.pooled, f.pooled), "\(id) r2/pooled")
                    #expect(d.rise == f.rise, "\(id) rise")
                    checkLive(KitSpend.liveDetail(h, account: acct, windowKind: kind, rates: d.rates), m.live_rates,
                              "\(id) live(rates)")
                }
                let live = KitSpend.liveDetail(h, account: acct, windowKind: kind)
                checkLive(live, m.live, "\(id) live")
                if m.live != nil { lives += 1 }
                if let hourly = m.hourly {
                    let mine = KitSpend.hourlySeries(h, accounts: [acct], hours: 24).values
                    #expect(zip(mine, hourly).allSatisfy { Self.close($0, $1, 1e-12) }, "\(id) hourly")
                }
                if let pl = m.port_live {
                    let req = ArenaFixtures.request(c)
                    let runner = ArenaRunner(registry: ArenaRegistry.all)
                    let tf = try #require(try runner.forecast(model: "port-live-meter", history: h, request: req)
                        .byKey[req.targets[0].key])
                    if let q = pl.quantiles {
                        for (lv, want) in zip(file.levels, q) {
                            let got = tf.quantile(lv)
                            #expect(got.allSatisfy { Self.close($0, want) }, "\(id) port-live q\(lv) \(got[0]) vs \(want)")
                        }
                        portLives += 1
                    } else {
                        #expect(tf.median.allSatisfy { $0 == pl.centre }, "\(id) port-live point")
                    }
                }
                moments += 1
            }
        }
        #expect(moments == 48)
        print("live meter parity: \(moments) moments, \(lives) live values, \(portLives) port-live-meter spreads")
    }
}

/* How ArenaFixtures/spend-live.json was made (synthetic cases only), from
   research/arena: uv run python -I live_fixture.py cases-spend.json spend-live.json

"""Reference outputs for the Swift port of kit/spend.py's live meter and
port-live-meter, on the SYNTHETIC spend fixture cases (cases-spend.json).

Usage (from research/arena): uv run python <this> <cases-spend.json> <out.json>
"""
import json
import sys

import numpy as np

from arena.cli_portfix import Local, fixture_pricing, snapshot_from_case
from arena.types import Scope
from kit import detq
from kit import spend as S

MIN = 60_000


def num(x):
    if x is None:
        return None
    x = float(x)
    return x if np.isfinite(x) else None


def live_json(v):
    if v is None:
        return None
    return {"shown": v.shown, "percent": v.percent, "exact": v.exact, "reading": v.reading,
            "reading_t": int(v.reading_t), "anchor_t": int(v.anchor_t), "added": v.added,
            "spend_usd": v.spend_usd, "carry": v.carry, "restarted": bool(v.restarted)}


def main(src, dst):
    cases = json.load(open(src))["cases"]
    out = []
    for c in cases:
        inp, rq = c["inputs"], c["request"]
        acct, kind = inp["account"], inp["window_kind"]
        small = snapshot_from_case(c)
        local = Local(small, tz_offset_min=inp["tz_offset_min"])
        view = small.view(Scope((acct,), "scope_only"), "current_code", inp["history_start"])
        rec = {"case": c["id"], "moments": []}
        with fixture_pricing():
            for back in (0, 7, 23, 61):
                now = int(rq["now"]) - back * MIN
                h = local.history(view, now)
                d = S.fit_details(h, acct, kind, None)
                m = {"now": now, "fit": None, "live": live_json(S.live_detail(h, acct, kind, None))}
                if d is not None:
                    m["fit"] = {"rates": [float(x) for x in d.rates], "weak": bool(d.conversion.weak),
                                "r2": float(d.conversion.r2), "pooled": float(d.pooled), "own": bool(d.own),
                                "rise": float(d.rise), "n_rows": int(len(d.rows)),
                                "r2_interval": num(d.extra["r2_interval"])}
                    # The live mechanics with the fit's rates, weak or not.
                    m["live_rates"] = live_json(S.live_detail(h, acct, kind, None, rates=d.rates))
                if back == 0:
                    m["hourly"] = [float(x) for x in S.hourly_series(h, (acct,), 24)[1]]
                    # port-live-meter: its centre and the residuals it draws from.
                    live = S.live_detail(h, acct, kind, None)
                    from kit import baselines as B
                    from arena.types import TargetRequest, Target
                    tgt = Target.METER_5H if kind == "five_hour" else Target.METER_7D
                    tr = TargetRequest(rq["key"], tgt, (acct,), np.asarray(rq["grid"], dtype=np.int64), "pct", 200,
                                       None, None, rq["reset_at"])
                    mn = B.meter_now(h, tr)
                    centre = live.shown if live is not None else mn.latest
                    added = live.added if live is not None else 0.0
                    pl = {"centre": float(centre), "latest": float(mn.latest)}
                    if d is not None and len(d.residuals):
                        order = np.argsort(d.fitted, kind="stable")
                        fitted, resid = d.fitted[order], d.residuals[order]
                        i = int(np.searchsorted(fitted, added))
                        k = 400
                        lo = max(0, min(i - k // 2, len(fitted) - k))
                        near = resid[lo:lo + k]
                        vals = np.clip(centre + np.sort(near), mn.latest, 100.0)
                        q = detq.weighted_type1(vals[:, None], np.ones(len(vals)), detq.LEVELS_OUT)[:, 0]
                        pl.update(lo=lo, n_near=int(len(near)), quantiles=[float(x) for x in q])
                    m["port_live"] = pl
                rec["moments"].append(m)
        out.append(rec)
    json.dump({"format": "fm-spend-live/1", "source": "cases-spend.json (synthetic, seed 42)",
               "made_by": "live_fixture.py: kit.spend.live_detail / fit_details / hourly_series, port-live-meter's "
                          "residual neighbours, run under arena.cli_portfix.fixture_pricing",
               "levels": list(detq.LEVELS_OUT), "cases": out}, open(dst, "w"))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
*/
