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
    falls = L.find_falls(own.times, own.cycle_util, own.active, own.reset, dur)
    beh = L.learn_behaviour([(own_h, 1.0)], c["bands"], float(c["half_life_days"]), float(c["prior_hours"]), step,
                            float(c["rebase_prior"]), float(c["rebase_weeks_prior"]), [falls])
    zone_lo = float(c.get("zone_lo", 90))
    park_min = int(float(c.get("park_frac", 0.12)) * dur)
    tops = L.cycle_tops(own.times, own.cycle_util, own.active, own.reset, dur, now, zone_lo, park_min)
    ce = L.learn_ceilings([(t, 1.0) for t in tops], now, float(c.get("ceil_half_life_days", 28.0)), zone_lo,
                          float(c.get("ceil_prior_w100", 0.5)), float(c.get("leak_prior", 0.005)),
                          float(c.get("leak_prior_hours", 48.0)),
                          {int(k): float(v) for k, v in dict(c.get("prior_park", {})).items()},
                          float(c.get("late_h", 0.0)), float(c.get("leak_late_prior", 0.0)),
                          float(c.get("leak_late_prior_hours", 0.0)))
    stay = M.stay_hours(own, tr.reset_at, u0, now)
    free = (own_h.level < min(float(c["park_from"]), 100.0))
    surv = lambda hrs: L.zero_burn_survival(own_h, hrs, step, float(c["half_life_days"]), free)
    lv, pr = L.ceiling_posterior(ce, u0, stay, surv)
    return {"u0": u0, "n_steps": len(own_h.burn), "burn_sum": float(own_h.burn.sum()),
            "covered": int(own_h.covered.sum()), "level_sum": float(own_h.level.sum()),
            "keep": np.asarray(beh.keep), "rebase_per_step": beh.rebase_per_step, "n_falls": len(falls[0]),
            "n_tops": len(tops), "ceil_hazard": np.asarray(ce.hazard), "leak": ce.leak_per_hour,
            "leak_late": ce.leak_late_per_hour, "stay_h": stay, "idle_h": M.idle_hours(own, now),
            "post_levels": np.asarray(lv, dtype=np.float64), "post_probs": np.asarray(pr)}


def main():
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
