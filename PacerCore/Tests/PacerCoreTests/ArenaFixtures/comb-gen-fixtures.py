"""Reference outputs for the Swift ports of g1-08-opus-fm and g2-06-opus-fmgate2
(meter targets only), on the port fixtures' SYNTHETIC spend cases
(cases-spend.json: readings + pseudo-turns, rebuilt with
arena.cli_portfix.snapshot_from_case, exactly what the Swift test feeds).

Run from research/arena (with a private ARENA_HOME; nothing is read from a snapshot):

    uv run --extra fm python -I <this> .../ArenaFixtures/cases-spend.json OUT s00,s01,...,s11
    NOPRIOR=1 uv run --extra fm python -I <this> .../cases-spend.json OUT s00,...,s11 g1-08-opus-fm
    SCOPED=1 uv run --extra fm python -I <this> .../cases-spend.json OUT s03,s09,s11

-> comb-g1-08-opus-fm.json, comb-g2-06-opus-fmgate2.json, comb-g1-08-opus-fm-noprior.json,
   comb-scoped.json (the scoped variant relabels weekly cases as the cap "Fable").

Per case, per model:
- det: the model with its two random steps pinned (a tied PIT reads the
  middle of its tie, u = 0.5; no rationing) and a STABLE sort in
  fmcal.wquantile (numpy's default argsort is not stable, so tied PITs with
  different weights are ordered arbitrarily): exact given the network.
  g1-08: the calibrated meter quantiles (`out`, [G][200], recovered by
  sorting the 200 stratified paths per grid time) at selected level indices;
  the calibration maps; the cut records' inputs. g2-06 (weekly: gate off):
  shrink + rint of the same det paths.
- mc: the model as is, 4000 paths, quantiles at LEVELS_OUT by read_sorted
  and MC bounds (detq.from_sampled's), not a strict bound here: the
  calibration's own randomness is shared by all 4000 paths.
- gate pieces (g2-06): u0, idle time, block, the resume weights.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import numpy as np

import kit.fm.backends as KB

_orig_get = KB.get_backend
_bcache: dict = {}
_stats = {"rows": 0, "hits": 0, "net_s": 0.0}


class CachingBackend:
    """The real backend, memoized per context row (the det and mc runs and
    both models see identical contexts)."""

    def __init__(self, be):
        self.be = be

    def quantiles(self, context, horizon, past_cov=None, known_cov=None):
        ctx = np.asarray(context)
        keys = [(int(horizon), ctx[b].tobytes()) for b in range(ctx.shape[0])]
        miss = [b for b in range(ctx.shape[0]) if keys[b] not in _bcache]
        _stats["rows"] += len(keys)
        _stats["hits"] += len(keys) - len(miss)
        if miss:
            t0 = time.time()
            lv, q = self.be.quantiles(ctx[miss], horizon, past_cov, known_cov)
            _stats["net_s"] += time.time() - t0
            for i, b in enumerate(miss):
                _bcache[keys[b]] = (lv, q[i])
        lv = _bcache[keys[0]][0]
        return lv, np.stack([_bcache[k][1] for k in keys])


def get_backend(name, spec, threads=4):
    return CachingBackend(_orig_get(name, spec, threads))


KB.get_backend = get_backend

from arena.cli_portfix import FORMAT, MODELS_DIR, Local, snapshot_from_case  # noqa: E402
from arena.episodes import target_key  # noqa: E402
from arena.registry import Registry  # noqa: E402
from arena.types import Request, Scope, Target, TargetRequest  # noqa: E402
from kit import detq  # noqa: E402
from kit.calib import read_sorted  # noqa: E402

COLS = [0, 9, 19, 49, 99, 100, 149, 179, 189, 199]     # ALPHA indices dumped
MC_PATHS = 4000
import os
NOPRIOR = os.environ.get("NOPRIOR") == "1"


def r6(x):
    a = np.asarray(x, dtype=np.float64)
    if a.ndim == 0:
        v = float(a)
        return None if not np.isfinite(v) else round(v, 6)
    return [r6(v) for v in a]


class Half:
    def random(self, *a, **k):
        return 0.5


def stable_wquantile(x, w, q):
    o = np.argsort(x, kind="stable")
    x, w = x[o], w[o]
    c = np.cumsum(w)
    c = (c - 0.5 * w) / c[-1]
    return np.interp(q, c, x)


CAPTURE = {"cal": [], "bt": []}


def patch_det(on: bool):
    fm = sys.modules["fmcal"]
    if not hasattr(fm, "_orig_wq"):
        fm._orig_wq = fm.wquantile
        fm._orig_records = fm.SelfBacktest.records
        fm._orig_cal_init = fm.Calibration.__init__
        fm._orig_refresh = fm.SelfBacktest.refresh

        def cal_init(self, *a, **k):
            fm._orig_cal_init(self, *a, **k)
            CAPTURE["cal"].append(self)
        fm.Calibration.__init__ = cal_init

        def refresh(self, *a, **k):
            fm._orig_refresh(self, *a, **k)
            CAPTURE["bt"].append(self)
        fm.SelfBacktest.refresh = refresh
    if on:
        fm.wquantile = stable_wquantile
        fm.SelfBacktest.records = lambda self, s, now, rng: fm._orig_records(self, s, now, Half())
    else:
        fm.wquantile = fm._orig_wq
        fm.SelfBacktest.records = fm._orig_records


def request(case, n_paths):
    rq = case["request"]
    acct = rq["account"]
    target = Target(rq["target"])
    grid = np.asarray(rq["grid"], dtype=np.int64)
    key = target_key(target, (acct,))
    return key, Request(rq["now"], Scope((acct,), "scope_only"),
                        (TargetRequest(key, target, (acct,), grid, "pct", n_paths, None, None, rq["reset_at"]),))


def meter_part(model):
    return model.meters if hasattr(model, "meters") else model.fm.meters


def run_case(info, case, mode):
    small = snapshot_from_case(case)
    inp = case["inputs"]
    local = Local(small, tz_offset_min=inp["tz_offset_min"])
    n = 200 if mode == "det" else MC_PATHS
    key, req = request(case, n)
    view = small.view(req.scope, "current_code", inp["history_start"])
    CAPTURE["cal"].clear()
    CAPTURE["bt"].clear()
    model = local.instance(info, view, case["request"]["now"])
    mf = meter_part(model)
    if NOPRIOR:
        mf.cfg.pop("prior", None)
    if mode == "det":
        patch_det(True)
        mf.cfg["ration"] = False
    else:
        patch_det(False)
    try:
        fc = model.forecast(req)
    finally:
        patch_det(False)
    P = np.sort(np.asarray(fc.by_key[key].paths, dtype=np.float64), axis=0)       # [n, G]
    return model, P, list(CAPTURE["cal"]), list(CAPTURE["bt"]), local.logs


def det_detail(model, P, cals, bts, case, full=True):
    d = {"cols": COLS, "out_cols": r6(P[COLS, :])}
    if not full:
        return d
    mf = meter_part(model)
    if cals:
        cal = cals[-1]
        d["cal_n"] = r6(cal.n)
        d["cal_maps"] = r6(cal.maps[:, COLS])
        d["leads"] = r6(cal.leads)
    if bts:
        bt = bts[-1]
        live = [(c, v) for c, v in bt.cuts.items() if v is not None]
        d["n_cand"] = len(bt.cuts)
        d["n_cuts"] = len(live)
        d["cut_times"] = [int(c) for c, _ in live]
        rows = sorted({0, 1, 2, min(12, bt.H), bt.H})
        d["cut_rows"] = rows
        d["cuts"] = [{"c": int(c), "c_last": r6(v[0]), "used_c": r6(v[1]), "reset_c": int(v[2]),
                      "phase": r6(v[3]), "act": r6(v[4]), "bq": r6(v[6][rows, :].astype(np.float64))}
                     for c, v in live[:4]]
        li, pits, lev, ph, age, acts = bt.records(_series(model, case), case["request"]["now"], Half())
        d["n_records"] = int(len(li))
        d["records"] = {"li": li.tolist(), "pit": r6(pits)}
    return d


def _series(model, case):
    from kit.fm.series import meter_series
    inp = case["inputs"]
    return meter_series(model.history.table("meter_readings"), inp["account"], inp["window_kind"],
                        None, case["request"]["now"])


def gate_detail(model, case):
    import gate as G
    from kit import baselines as B
    from kit import spend as S
    rq = case["request"]
    _, req = request(case, 200)
    tr = req.targets[0]
    now = int(rq["now"])
    h = model.history
    acct = tr.accounts[0]
    wk = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day"}[tr.target]
    cfg = dict(model.cfg.get("gate", {}).get(wk, {}))
    m = B.meter_now(h, tr)
    book = G.TurnBook(h)
    T = book.times(acct, None)
    T = T[T <= now]
    d = G.idle_ms(T, now)
    blk = G.blocked_until(h, acct, now)
    out = {"u0": r6(m.util[-1]) if len(m.util) else None, "n_turns": int(len(T)),
           "idle_ms": None if not np.isfinite(d) else float(d), "blocked_until": int(blk),
           "tz_ms": int(S.tz_offset_ms(h, acct))}
    if len(T) >= 20 and np.isfinite(d):
        g0, gap = T[:-1], np.diff(T).astype(np.float64)
        keep = gap > d
        out["n_kept"] = int(keep.sum())
        if keep.sum() >= int(cfg.get("min_gaps", 8)):
            s = g0[keep].astype(np.float64)
            resid = gap[keep] - d
            at = s + d
            age_d = (now - at) / G.DAY
            w = np.exp(-np.maximum(age_d, 0) / float(cfg.get("recency_days", 30)))
            hd = np.abs(G.local_hour(at, S.tz_offset_ms(h, acct)) - G.local_hour(now, S.tz_offset_ms(h, acct)))
            hd = np.minimum(hd, 24 - hd)
            w = w * np.exp(-0.5 * (hd / float(cfg.get("bw_hour", 2.5))) ** 2)
            out["resid"] = r6(resid)
            out["p"] = [float(x) for x in (w / w.sum())]
    return out


def gate_unit():
    """gate_paths on small synthetic inputs, both modes."""
    import gate as G
    rng = np.random.default_rng(7)
    grid = np.array([30_000, 60_000, 120_000, 300_000, 600_000, 900_000, 1_800_000, 3_600_000], dtype=np.int64) + 10_000_000
    now = 10_000_000
    base = np.maximum.accumulate(20.0 + np.cumsum(rng.uniform(0, 6, (6, len(grid))), axis=1), axis=1)
    base = np.minimum(base, 100.0)
    tau = np.array([0.0, 45_000.0, 400_000.0, 2_000_000.0, np.inf, 5_000_000.0])
    return {"now": now, "grid": grid.tolist(), "u0": 21.5, "base": base.tolist(), "tau": [None if not np.isfinite(t) else t for t in tau],
            "shift": G.gate_paths(base, grid, now, 21.5, tau, "shift").tolist(),
            "cut": G.gate_paths(base, grid, now, 21.5, tau, "cut").tolist()}


def main():
    cases_path, out_dir, ids = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3].split(",")
    names = sys.argv[4].split(",") if len(sys.argv) > 4 else ["g1-08-opus-fm", "g2-06-opus-fmgate2"]
    doc = json.loads(cases_path.read_text())
    cases = {c["id"]: c for c in doc["cases"]}
    reg = Registry([MODELS_DIR])
    infos = [reg.load(n) for n in names]
    results = {i.name: [] for i in infos}
    for cid in ids:
        case = cases[cid]
        for info in infos:
            t0 = time.time()
            row = {"case": cid}
            model, P, cals, bts, logs = run_case(info, case, "det")
            if NOPRIOR:
                cal = cals[-1] if cals else None
                row.update(levels=[], quantiles=[], median=[], exact=True, mc_paths=0,
                           detail={"det": {"cols": COLS, "out_cols": r6(P[COLS, :]),
                                           "cal_n": r6(cal.n) if cal is not None else None,
                                           "cal_maps": r6(cal.maps[:, COLS]) if cal is not None else None}})
                results[info.name].append(row)
                print(f"{info.name} {cid}: noprior det {time.time() - t0:.1f}s", file=sys.stderr, flush=True)
                continue
            dd = det_detail(model, P, cals, bts, case, full=info.name.startswith("g1-08"))
            if info.name.startswith("g2-06"):
                dd["gate"] = gate_detail(model, case)
            t1 = time.time()
            model, S, _, _, logs2 = run_case(info, case, "mc")
            lv = np.asarray(detq.LEVELS_OUT)
            sh = detq.mc_shift(lv, S.shape[0])
            q = read_sorted(S, lv)
            row.update(levels=list(detq.LEVELS_OUT), quantiles=r6(q), median=r6(np.median(S, axis=0)),
                       exact=False, mc_paths=int(S.shape[0]),
                       mc_bounds={"lo": r6(read_sorted(S, np.clip(lv - sh, 0, 1))),
                                  "hi": r6(read_sorted(S, np.clip(lv + sh, 0, 1)))},
                       detail={"det": dd, "n_logs": len(logs) + len(logs2),
                               "seconds": {"det": round(t1 - t0, 1), "mc": round(time.time() - t1, 1)}})
            results[info.name].append(row)
            print(f"{info.name} {cid}: det {t1 - t0:.1f}s mc {time.time() - t1:.1f}s cache {_stats}", file=sys.stderr,
                  flush=True)
    for info in infos:
        body = {"format": FORMAT, "spec": "docs/port-spec.md#parity", "model": info.name,
                "snapshot": "port-fixtures (cases-spend.json, synthetic)", "seed": 42,
                "note": "made by gen_comb_fixtures.py (see the Swift test's header); det = tie u 0.5, no ration, "
                        "stable wquantile", "outputs": results[info.name]}
        if info.name.startswith("g2-06") and not NOPRIOR:
            body["gate_unit"] = gate_unit()
        name = "comb-" + info.name + ("-noprior" if NOPRIOR else "") + ".json"
        (out_dir / name).write_text(json.dumps(body, separators=(",", ":")) + "\n")
        print(f"wrote {out_dir / name} ({(out_dir / name).stat().st_size} bytes)", file=sys.stderr)




# ---------------------------------------------------------------------------
# Scoped variant: a weekly case relabelled as the scoped cap "Fable", its
# pseudo-turns split between families by a rule the Swift test repeats:
# family "fable" when (t_event // 1000) % 3 == 0, else "opus".
# ---------------------------------------------------------------------------

def scoped_snapshot(case):
    import polars as pl
    small = snapshot_from_case(case)
    t = small.tables
    r = t["meter_readings"].with_columns(pl.lit("weekly_scoped").alias("window_kind"), pl.lit("Fable").alias("scope_model"))
    tu = t["turns"]
    fam = pl.when((pl.col("t_event").dt.epoch("ms") // 1000) % 3 == 0).then(pl.lit("fable")).otherwise(pl.lit("opus"))
    tu = tu.with_columns(fam.alias("model_family")).with_columns(("fixture-" + pl.col("model_family")).alias("model"))
    from arena.snapshot.views import SnapshotData
    return SnapshotData({"meter_readings": r.cast(t["meter_readings"].schema), "turns": tu.cast(t["turns"].schema)},
                        snapshot_id=small.snapshot_id, tier=small.tier, manifest={})


def scoped_request(case, n_paths):
    rq = case["request"]
    acct = rq["account"]
    key = target_key(Target.METER_SCOPED, (acct,), "Fable")
    grid = np.asarray(rq["grid"], dtype=np.int64)
    return key, Request(rq["now"], Scope((acct,), "scope_only"),
                        (TargetRequest(key, Target.METER_SCOPED, (acct,), grid, "pct", n_paths, "Fable", None,
                                       rq["reset_at"]),))


def main_scoped():
    cases_path, out_dir, ids = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3].split(",")
    doc = json.loads(cases_path.read_text())
    cases = {c["id"]: c for c in doc["cases"]}
    reg = Registry([MODELS_DIR])
    infos = [reg.load(n) for n in ["g1-08-opus-fm", "g2-06-opus-fmgate2"]]
    rows = []
    for cid in ids:
        case = cases[cid]
        inp = case["inputs"]
        small = scoped_snapshot(case)
        for info in infos:
            out = {"case": cid, "model": info.name}
            for mode in ("det", "mc"):
                local = Local(small, tz_offset_min=inp["tz_offset_min"])
                n = 200 if mode == "det" else MC_PATHS
                key, req = scoped_request(case, n)
                view = small.view(req.scope, "current_code", inp["history_start"])
                model = local.instance(info, view, case["request"]["now"])
                mf = meter_part(model)
                patch_det(mode == "det")
                if mode == "det":
                    mf.cfg["ration"] = False
                try:
                    fc = model.forecast(req)
                finally:
                    patch_det(False)
                P = np.sort(np.asarray(fc.by_key[key].paths, dtype=np.float64), axis=0)
                if mode == "det":
                    out["det_out_cols"] = r6(P[COLS, :])
                    if info.name.startswith("g2-06"):
                        import gate as G
                        from kit import baselines as B
                        from kit import spend as S
                        tr = req.targets[0]
                        now = int(case["request"]["now"])
                        h = model.history
                        cfg = dict(model.cfg["gate"]["weekly_scoped"])
                        m = B.meter_now(h, tr)
                        book = G.TurnBook(h)
                        T = book.times(tr.accounts[0], G.cap_family("Fable"))
                        T = T[T <= now]
                        d = G.idle_ms(T, now)
                        g = {"u0": r6(m.util[-1]) if len(m.util) else None, "n_turns": int(len(T)),
                             "idle_ms": None if not np.isfinite(d) else float(d),
                             "blocked_until": int(G.blocked_until(h, tr.accounts[0], now))}
                        if len(T) >= 20 and np.isfinite(d):
                            gap = np.diff(T).astype(np.float64)
                            g["n_kept"] = int((gap > d).sum())
                        out["gate"] = g
                else:
                    lv = np.asarray(detq.LEVELS_OUT)
                    sh = detq.mc_shift(lv, P.shape[0])
                    out.update(levels=list(detq.LEVELS_OUT), quantiles=r6(read_sorted(P, lv)),
                               mc_bounds={"lo": r6(read_sorted(P, np.clip(lv - sh, 0, 1))),
                                          "hi": r6(read_sorted(P, np.clip(lv + sh, 0, 1)))})
            rows.append(out)
            print(f"scoped {info.name} {cid} done, cache {_stats}", file=sys.stderr, flush=True)
    body = {"format": FORMAT, "note": "gen_comb_fixtures.py SCOPED=1: weekly cases relabelled as the scoped cap Fable; "
                                      "turn family fable when (t_event // 1000) % 3 == 0 else opus",
            "outputs": rows}
    (out_dir / "comb-scoped.json").write_text(json.dumps(body, separators=(",", ":")) + "\n")
    print(f"wrote {(out_dir / 'comb-scoped.json').stat().st_size} bytes", file=sys.stderr)


if os.environ.get("SCOPED") == "1":
    main_scoped()
    sys.exit(0)


if __name__ == "__main__":
    main()
