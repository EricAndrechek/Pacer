"""Reference outputs for the Swift ensemble ports (builder G), from the
arena's port-fixture cases (synthetic snapshot only; inputs read back from
the committed cases*.json). Run from research/arena, one process, with
Timestral-123M in the Hugging Face cache:

    uv run --extra fm python findings/2026-10-port/ens-fixtures/ens_fixtures.py \
        --cases-dir ../../PacerCore/Tests/PacerCoreTests/ArenaFixtures \
        --stub findings/2026-10-port/ens-fixtures/stubmodel \
        --out ../../PacerCore/Tests/PacerCoreTests/ArenaFixtures

Writes:
- ens-g1-05-stub.json: g1-05-opus-ens-meter-big (its real config and code)
  over six deterministic stub children named as its real ones: the fitted
  cells and the final paths' quantiles. Deterministic given the children.
- ens-g2-05.json: g2-05-sonnet-final: b and the flat share per case; the
  layer's output on the deterministic child samples (Timestral quantiles at
  the sample levels, the decay's exact quantiles) at LEVELS_OUT; and the
  Python's own Monte-Carlo output (informational).
- ens-g2-05-layer.json: the layer on rounded deterministic inputs (exact).
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import replace
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path.cwd()))
from arena.cli_portfix import Local, MODELS_DIR, fixture_pricing, snapshot_from_case, _arr  # noqa: E402
from arena.registry import ModelInfo, Registry  # noqa: E402
from arena.types import Request, Scope, Target, TargetRequest, TargetForecast  # noqa: E402

LEVELS = [0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95]


def setup(io, spend):
    inp, rq = io["inputs"], io["request"]
    small = snapshot_from_case(io)
    local = Local(small, tz_offset_min=inp["tz_offset_min"])
    target = Target(rq["target"])
    acct = rq["account"]
    tr = TargetRequest(rq["key"], target, (acct,), np.asarray(rq["grid"], dtype=np.int64), "pct", 200, None, None,
                       rq["reset_at"])
    req = Request(rq["now"], Scope((acct,), "scope_only"), (tr,))
    view = small.view(req.scope, "current_code", inp["history_start"])
    return local, req, tr, view


def g105(a, cases):
    reg = Registry([MODELS_DIR])
    info = reg.load("g1-05-opus-ens-meter-big")
    stub = Path(a.stub).resolve()
    kids = {}
    for i, name in enumerate(info.children):
        kids[name] = ModelInfo(name=name, path=stub, hash=f"stub{i:02d}" + "0" * 56, targets=info.targets, deps=(),
                               config={"stub": i}, meta={}, children={})
    info = replace(info, children=kids)
    rows = []
    for cid in a.g105_cases.split(","):
        io = cases[cid]
        local, req, tr, view = setup(io, False)
        model = local.instance(info, view, req.now)
        fc = model.forecast(req)
        tf = fc.by_key[tr.key]
        P = np.asarray(tf.paths, dtype=np.float64)
        q = np.quantile(P, LEVELS, axis=0)
        cells = []
        for (kind, ch, b), c in model._cells.items():
            cells.append({"kind": kind, "children": list(ch), "band": int(b), "w": [float(x) for x in c.w],
                          "scale": float(c.scale), "rise": float(c.rise), "n": int(c.n)})
        groups = [{"origin": int(g.origin), "key": g.key, "n_y": int(len(g.y)), "children": sorted(g.entries)}
                  for g in model.ledger.groups.values()]
        rows.append({"case": cid, "levels": LEVELS, "quantiles": _arr(q, 9), "p_hit_limit": float(tf.extras["p_hit_limit"]),
                     "n_paths": int(P.shape[0]), "cells": cells, "groups": groups,
                     "paths_head": _arr(P[::20], 9)})
        print(f"g1-05 {cid}: {len(cells)} cells, {len(groups)} groups", file=sys.stderr)
    return {"format": "pacer-arena-ens-fixture/1", "model": "g1-05-opus-ens-meter-big",
            "children": "stub (ens-g stubmodel: meter now + A_i * shape_i(f) * (p + 0.5) / n * 2)",
            "outputs": rows}


def g205(a, cases, spend_cases):
    from kit import detq
    reg = Registry([MODELS_DIR])
    info = reg.load("g2-05-sonnet-final")
    rows, layer_rows = [], []
    for cid in a.g205_cases.split(","):
        spend = cid.startswith("s")
        io = (spend_cases if spend else cases)[cid]
        local, req, tr, view = setup(io, spend)
        ctxm = fixture_pricing() if spend else None
        if ctxm:
            ctxm.__enter__()
        try:
            model = local.instance(info, view, req.now)
            mod = sys.modules[type(model).__module__]
            wk = mod.WINDOW_FOR[tr.target]
            s = mod.meter_series(model.history.table("meter_readings"), tr.accounts[0], wk, None, req.now)
            b = s.used_now(tr.reset_at)
            pi_L = mod.flat_share(s, req.now, int(tr.reset_at), model.cfg)
            # The deterministic child samples, as the Swift port builds them.
            n = tr.n_paths
            if wk == "five_hour":
                fmq = detq.timestral_quantiles(model.fm, req, (np.arange(n) + 0.5) / n)[tr.key].q
                X = fmq
            else:
                c = n // 2
                lv = (np.arange(c) + 0.5) / c
                fmq = detq.timestral_quantiles(model.fm, req, lv)[tr.key].q
                dq = detq.spend_decay_quantiles(model.decay, req, lv)[tr.key].q
                X = np.sort(np.vstack([fmq, dq]), axis=0)
            Q = np.asarray(model._layer(tr, TargetForecast(X), req.now).paths, dtype=np.float64)
            q_det = np.quantile(Q, LEVELS, axis=0)
            # The layer on rounded inputs: exact parity for the layer alone.
            Xr = np.round(X, 6)
            Qr = np.asarray(model._layer(tr, TargetForecast(Xr), req.now).paths, dtype=np.float64)
            # The Python's own Monte-Carlo answer.
            P_mc = np.asarray(model.forecast(req).by_key[tr.key].paths, dtype=np.float64)
            q_mc = np.quantile(P_mc, LEVELS, axis=0)
            # And with many paths: what the Monte-Carlo answer converges to.
            big = replace(req, targets=(replace(tr, n_paths=a.mc_n),))
            P_big = np.asarray(model.forecast(big).by_key[tr.key].paths, dtype=np.float64)
            q_big = np.quantile(P_big, LEVELS, axis=0)
        finally:
            if ctxm:
                ctxm.__exit__(None, None, None)
        rows.append({"case": cid, "spend": spend, "b": b, "flat_share": None if pi_L is None else _arr(pi_L, 12),
                     "levels": LEVELS, "quantiles": _arr(q_det, 9), "mc_quantiles": _arr(q_mc, 6),
                     "mc_big_n": a.mc_n, "mc_big_quantiles": _arr(q_big, 6)})
        if cid in a.layer_cases.split(","):
            layer_rows.append({"case": cid, "spend": spend, "b": b, "x": _arr(Xr, 6), "q": _arr(Qr, 9)})
        print(f"g2-05 {cid}: b={b} flat_share={'none' if pi_L is None else np.round(pi_L, 3).tolist()}",
              file=sys.stderr)
    return ({"format": "pacer-arena-ens-fixture/1", "model": "g2-05-sonnet-final", "outputs": rows},
            {"format": "pacer-arena-ens-fixture/1", "model": "g2-05-sonnet-final", "outputs": layer_rows})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases-dir", required=True)
    ap.add_argument("--stub", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--g105-cases", default="c00,c01,c02,c03")
    ap.add_argument("--g205-cases", default="c00,c02,c04,s01,s03")
    ap.add_argument("--layer-cases", default="c02,s01")
    ap.add_argument("--only", default="g105,g205")
    ap.add_argument("--mc-n", type=int, default=4000)
    a = ap.parse_args()
    cd = Path(a.cases_dir)
    cases = {c["id"]: c for c in json.loads((cd / "cases.json").read_text())["cases"]}
    spend_cases = {c["id"]: c for c in json.loads((cd / "cases-spend.json").read_text())["cases"]}
    out = Path(a.out)
    if "g105" in a.only:
        doc = g105(a, cases)
        (out / "ens-g1-05-stub.json").write_text(json.dumps(doc, separators=(",", ":")) + "\n")
    if "g205" in a.only:
        doc, layer = g205(a, cases, spend_cases)
        (out / "ens-g2-05.json").write_text(json.dumps(doc, separators=(",", ":")) + "\n")
        (out / "ens-g2-05-layer.json").write_text(json.dumps(layer, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
