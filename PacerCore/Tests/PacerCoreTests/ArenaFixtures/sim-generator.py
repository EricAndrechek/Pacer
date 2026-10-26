"""Monte-Carlo reference outputs for the simulation ports (g2-08-fable-burst,
g2-07-opus-limit), on the port fixtures' own synthetic cases.

`arena port-fixtures` cannot make these: `kit.detq` has no deterministic
quantiles for a simulation, and it feeds turns only to `spend-*` models. So
this runs each model through the same in-process harness (`Local`, as
`make_case` does) on `snapshot_from_case(case)` (the reference consumer),
under `fixture_pricing` when the case carries turns, with MC_PATHS paths,
and writes quantiles + `mc_bounds` exactly as `detq.from_sampled` does.

    uv run python gen_sim_fixtures.py MODEL CASES_JSON OUT_JSON [case ids...]

Run from `research/arena` (it imports `arena` and `kit`); synthetic cases
only. The `sim-*.json` files beside this script were made with

    F=<this folder>
    uv run python $F/sim-generator.py g2-08-fable-burst $F/cases-spend.json $F/sim-g2-08-fable-burst-spend.json
    uv run python $F/sim-generator.py g2-08-fable-burst $F/cases.json $F/sim-g2-08-fable-burst.json
    uv run python $F/sim-generator.py g2-07-opus-limit $F/cases.json $F/sim-g2-07-opus-limit.json
    uv run python $F/sim-generator.py g2-07-opus-limit $F/cases-spend.json $F/sim-g2-07-opus-limit-spend.json

    uv run python $F/sim-generator.py --multi $F/cases.json $F/sim-cases-multi.json $F/sim-g2-07-opus-limit-multi.json

`detail` holds what the Swift tests check exactly: g2-08's `last_diag`
(rounded as the model rounds it) and g2-07's intermediates (`g207_detail`).
"""
import json
import sys
from pathlib import Path

import numpy as np

from arena.cli_portfix import (FORMAT, MODELS_DIR, Local, _arr, detail_json, fixture_pricing,
                               snapshot_from_case)
from arena.registry import Registry
from arena.types import Request, Scope, Target, TargetRequest
from kit import detq


def g207_detail(model, req, tr):
    """g2-07-opus-limit's deterministic intermediates for one target, the way
    `meters.meter_paths` computes them (no draws): what a port checks exactly
    before comparing its paths within Monte-Carlo bounds."""
    M = sys.modules["meters"]
    L = sys.modules["limitsim"]
    h = model.history
    readings = h.table("meter_readings")
    now = int(req.now)
    kind = M.WINDOW_OF[tr.target]
    cap = tr.cap if tr.target is Target.METER_SCOPED else None
    c = M._cfg(kind, model.cfg)
    acct = tr.accounts[0]
    step = int(c["step_min"]) * L.MIN
    tz_ms = int(h.tz_offset_min or 0) * L.MIN
    lookback = int(float(c["lookback_days"]) * L.DAY)
    stale = 3 * step if kind == "five_hour" else 3 * L.HOUR
    dur = L.WINDOW[kind]
    own = M._series(readings, acct, kind, cap, now)
    u0 = M.current_level(own, tr.reset_at)
    own_h = L.step_history(own.times, own.cum, own.cycle_util, own.active, now, step, lookback, tz_ms, stale)
    hists = [(own_h, 1.0)]
    falls = [L.find_falls(own.times, own.cycle_util, own.active, own.reset, dur)]
    other_w = float(c.get("other_account_weight", 0.5))
    others = [a for a in (tuple(h.accounts) if getattr(h, "accounts", None) else ()) if a != acct]
    for a in others:
        so = M._series(readings, a, kind, cap, now)
        if len(so) < 2:
            continue
        hists.append((L.step_history(so.times, so.cum, so.cycle_util, so.active, now, step, lookback, tz_ms, stale),
                      other_w))
        falls.append(L.find_falls(so.times, so.cycle_util, so.active, so.reset, dur))
    beh = L.learn_behaviour(hists, c["bands"], float(c["half_life_days"]), float(c["prior_hours"]), step,
                            float(c["rebase_prior"]), float(c["rebase_weeks_prior"]), falls)
    zone_lo = float(c.get("zone_lo", 90))
    park_min = int(float(c.get("park_frac", 0.12)) * dur)
    own_tops = L.cycle_tops(own.times, own.cycle_util, own.active, own.reset, dur, now, zone_lo, park_min)
    tops = [(t, 1.0) for t in own_tops]
    for a in others:
        so = M._series(readings, a, kind, cap, now)
        tops += [(t, other_w) for t in L.cycle_tops(so.times, so.cycle_util, so.active, so.reset, dur, now,
                                                    zone_lo, park_min)]
    ce = L.learn_ceilings(tops, now, float(c.get("ceil_half_life_days", 28.0)), zone_lo,
                          float(c.get("ceil_prior_w100", 0.5)), float(c.get("leak_prior", 0.005)),
                          float(c.get("leak_prior_hours", 48.0)),
                          {int(k): float(v) for k, v in dict(c.get("prior_park", {})).items()},
                          float(c.get("late_h", 0.0)), float(c.get("leak_late_prior", 0.0)),
                          float(c.get("leak_late_prior_hours", 0.0)))
    hs, borrowed = own_h, False
    if len(own_h.burn) < int(c["min_hist_steps"]) or own_h.burn.sum() <= 0:
        best = max(hists[1:], key=lambda x: x[0].burn.sum(), default=None)
        if best is not None and best[0].burn.sum() > 0 and (len(own_h.burn) < 2 or own_h.burn.sum() <= 0):
            hs, borrowed = best[0], True
    stay = M.stay_hours(own, tr.reset_at, u0, now)
    free = (own_h.level < min(float(c["park_from"]), 100.0))
    surv = lambda hrs: L.zero_burn_survival(own_h, hrs, step, float(c["half_life_days"]), free)
    lv, pr = L.ceiling_posterior(ce, u0, stay, surv)
    return {"u0": u0, "n_steps": len(own_h.burn), "burn_sum": float(own_h.burn.sum()),
            "covered": int(own_h.covered.sum()), "level_sum": float(own_h.level.sum()),
            "keep": np.asarray(beh.keep), "rebase_per_step": beh.rebase_per_step, "n_falls": len(falls[0][0]),
            "n_tops": len(own_tops), "n_hists": len(hists), "borrowed": float(borrowed),
            "sim_burn_sum": float(hs.burn.sum()) * (float(c.get("borrow_scale", 0.5)) if borrowed else 1.0), "ceil_hazard": np.asarray(ce.hazard), "leak": ce.leak_per_hour,
            "leak_late": ce.leak_late_per_hour, "stay_h": stay, "idle_h": M.idle_hours(own, now),
            "post_levels": np.asarray(lv, dtype=np.float64), "post_probs": np.asarray(pr)}


# Two-account cases for g2-07-opus-limit: a fixture case's account plus
# another case's account, its readings shifted by whole days onto the first
# one's period (synthetic either way). `history_hours` cuts the primary's own
# readings to its last hours (an account with no past of its own, which
# borrows the other's).
MULTI = [
    {"id": "m00", "primary": "c04", "other": "c16"},
    {"id": "m01", "primary": "c13", "other": "c07"},
    {"id": "m02", "primary": "c02", "other": "c14", "history_hours": 2},
    {"id": "m03", "primary": "c03", "other": "c11"},
    # A per-model weekly cap: weekly readings relabelled as a Fable cap.
    {"id": "m04", "primary": "c05", "other": "c19", "scoped": "Fable"},
]


def multi_cases(doc):
    by = {c["id"]: c for c in doc["cases"]}
    out = []
    for m in MULTI:
        p, o = by[m["primary"]], by[m["other"]]
        now, start = p["request"]["now"], p["inputs"]["history_start"]
        shift = int(round((now - o["request"]["now"]) / 86_400_000)) * 86_400_000
        rd_p = {k: p["inputs"]["readings"][k] for k in ("t_event", "t_known", "util_pct", "resets_at", "state")}
        if "history_hours" in m:
            lo = now - m["history_hours"] * 3_600_000
            keep = [i for i, t in enumerate(rd_p["t_event"]) if t >= lo]
            rd_p = {k: [v[i] for i in keep] for k, v in rd_p.items()}
        r = o["inputs"]["readings"]
        keep = [i for i in range(len(r["t_event"]))
                if r["t_known"][i] + shift <= now and r["t_event"][i] + shift >= start]
        rd_o = {"t_event": [r["t_event"][i] + shift for i in keep], "t_known": [r["t_known"][i] + shift for i in keep],
                "util_pct": [r["util_pct"][i] for i in keep],
                "resets_at": [None if r["resets_at"][i] is None else r["resets_at"][i] + shift for i in keep],
                "state": [r["state"][i] for i in keep]}
        rq = dict(p["request"])
        if "scoped" in m:
            rq.update(target="meter.scoped", key=f"meter.scoped:{rq['account']}:{m['scoped']}")
        out.append({"id": m["id"], "made_from": m, "accounts": [p["inputs"]["account"], o["inputs"]["account"]],
                    "window_kind": "weekly_scoped" if "scoped" in m else p["inputs"]["window_kind"],
                    "scope_model": m.get("scoped"), "history_start": start,
                    "tz_offset_min": p["inputs"]["tz_offset_min"],
                    "readings": {p["inputs"]["account"]: {k: rd_p[k] for k in ("t_event", "t_known", "util_pct", "resets_at", "state")},
                                 o["inputs"]["account"]: rd_o},
                    "request": rq})
    return out


def multi_snapshot(case):
    import pyarrow as pa
    from arena.snapshot.schema import TABLES
    from arena.snapshot.views import SnapshotData, Tier
    cols = {k: [] for k in ("t_event", "t_known", "t_known_src", "account", "window_kind", "scope_model", "util_pct",
                            "resets_at", "state", "source", "origin", "backwards_pp")}
    for acct, rd in case["readings"].items():
        n = len(rd["t_event"])
        cols["t_event"] += rd["t_event"]; cols["t_known"] += rd["t_known"]; cols["util_pct"] += rd["util_pct"]
        cols["resets_at"] += rd["resets_at"]; cols["state"] += rd["state"]
        cols["t_known_src"] += ["observed"] * n; cols["account"] += [acct] * n
        cols["window_kind"] += [case["window_kind"]] * n; cols["source"] += ["oauth"] * n
        cols["scope_model"] += [case.get("scope_model")] * n
        cols["origin"] += ["archive"] * n; cols["backwards_pp"] += [0.0] * n
    n = len(cols["t_event"])
    schema = TABLES["meter_readings"].arrow_schema()
    arrays = [pa.array(cols.get(f.name, [None] * n), type=pa.int64()).cast(f.type) if pa.types.is_timestamp(f.type)
              else pa.array(cols.get(f.name, [None] * n), type=f.type) for f in schema]
    import polars as pl
    tables = {"meter_readings": pl.from_arrow(pa.Table.from_arrays(arrays, schema=schema))}
    return SnapshotData(tables, snapshot_id="fixture-multi", tier=Tier("synthetic", case["history_start"],
                                                                         case["request"]["now"]), manifest={})


def main_multi(cases_path, out_cases, out_model):
    doc = json.loads(Path(cases_path).read_text())
    cases = multi_cases(doc)
    reg = Registry([MODELS_DIR])
    info = reg.load("g2-07-opus-limit")
    rows = []
    for case in cases:
        rq = case["request"]
        small = multi_snapshot(case)
        local = Local(small, tz_offset_min=case["tz_offset_min"])
        target = Target(rq["target"])
        tr = TargetRequest(rq["key"], target, (rq["account"],), np.asarray(rq["grid"], dtype=np.int64), "pct",
                           detq.MC_PATHS, case.get("scope_model"), None, rq["reset_at"])
        req = Request(rq["now"], Scope(tuple(case["accounts"]), "scope_only"), (tr,))
        view = small.view(req.scope, "current_code", case["history_start"])
        model = local.instance(info, view, rq["now"])
        P = np.asarray(model.forecast(req).by_key[rq["key"]].paths, dtype=np.float64)
        d = detq.from_sampled(detq.LEVELS_OUT, np.sort(P, axis=0), g207_detail(model, req, tr))
        rows.append({"case": case["id"], "levels": list(detq.LEVELS_OUT), "quantiles": _arr(d.q),
                     "median": _arr(d.median), "exact": False, "mc_paths": int(d.mc_paths),
                     "mc_bounds": {"lo": _arr(d.lo), "hi": _arr(d.hi)},
                     "detail": detail_json(d.detail), "logs": list(local.logs)})
        print(f"multi {case['id']} {rq['key']} accounts={case['accounts']} detail={rows[-1]['detail']}", file=sys.stderr)
    Path(out_cases).write_text(json.dumps({"format": FORMAT, "note": "two-account cases built from cases.json by "
                                           "sim-generator.py (MULTI)", "cases": cases}, separators=(",", ":")) + "\n")
    Path(out_model).write_text(json.dumps({"format": FORMAT, "model": "g2-07-opus-limit",
                                           "cases_file": Path(out_cases).name, "outputs": rows},
                                          separators=(",", ":")) + "\n")


def main():
    if sys.argv[1] == "--multi":
        return main_multi(*sys.argv[2:5])
    model_name, cases_path, out_path = sys.argv[1:4]
    only = set(sys.argv[4:])
    doc = json.loads(Path(cases_path).read_text())
    reg = Registry([MODELS_DIR])
    info = reg.load(model_name)
    rows = []
    for case in doc["cases"]:
        if only and case["id"] not in only:
            continue
        inp, rq = case["inputs"], case["request"]
        target = Target(rq["target"])
        if str(target) not in info.targets:
            continue
        small = snapshot_from_case(case)
        local = Local(small, tz_offset_min=inp["tz_offset_min"])
        acct = rq["account"]
        grid = np.asarray(rq["grid"], dtype=np.int64)
        tr = TargetRequest(rq["key"], target, (acct,), grid, "pct", detq.MC_PATHS, None, None, rq["reset_at"])
        req = Request(rq["now"], Scope((acct,), "scope_only"), (tr,))
        view = small.view(req.scope, "current_code", inp["history_start"])
        if "turns" in inp:
            with fixture_pricing():
                model = local.instance(info, view, rq["now"])
                fc = model.forecast(req)
        else:
            model = local.instance(info, view, rq["now"])
            fc = model.forecast(req)
        P = np.asarray(fc.by_key[rq["key"]].paths, dtype=np.float64)
        det = dict(getattr(model, "last_diag", {}) or {})
        if model_name == "g2-07-opus-limit":
            det = g207_detail(model, req, tr)
        d = detq.from_sampled(detq.LEVELS_OUT, np.sort(P, axis=0), det)
        rows.append({"case": case["id"], "levels": list(detq.LEVELS_OUT), "quantiles": _arr(d.q),
                     "median": _arr(d.median), "exact": False, "mc_paths": int(d.mc_paths),
                     "mc_bounds": {"lo": _arr(d.lo), "hi": _arr(d.hi)},
                     "detail": detail_json(d.detail), "logs": list(local.logs)})
        print(f"{model_name} {case['id']} {rq['key']} paths={P.shape} logs={local.logs[-1:] if local.logs else ''}",
              file=sys.stderr)
    out = {"format": FORMAT, "spec": "docs/port-spec.md#parity", "model": model_name,
           "snapshot": doc.get("snapshot"), "seed": doc.get("seed"), "cases_file": Path(cases_path).name,
           "generator": "sim-builder/gen_sim_fixtures.py (Local harness, MC_PATHS paths, detq.from_sampled)",
           "outputs": rows}
    Path(out_path).write_text(json.dumps(out, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
