"""Direct diagnostic harness: run a model in-process on sampled five-hour episodes
(the arena's own sampler, visible tier) at a few checkpoints each, score with the
arena's own scorer, and print aggregates plus the worst cases.

usage: python work/diag.py MODEL [--n 40] [--seed 0] [--cps 4] [--cfg k=v ...] [--verbose]
"""
from __future__ import annotations

import argparse
import importlib.util
import sys
import tempfile
import time
import tomllib
from pathlib import Path

import numpy as np

sys.path.insert(0, ".")
from arena.episodes import SamplerConfig, TierIndex, build_request, sample_episodes, specs_at  # noqa: E402
from arena.runner import build_truth  # noqa: E402
from arena.scoring.checkpoint import score_checkpoint  # noqa: E402
from arena.snapshot.views import EpisodeView, EventsView, HistoryView, SnapshotData  # noqa: E402
from arena.types import Truth  # noqa: E402


class Ctx:
    def __init__(self, cfg, seed):
        self.config = cfg
        self.seed = seed
        self.rng = np.random.default_rng(seed)
        self.scratch = Path(tempfile.mkdtemp(prefix="diag-scratch-"))
        self.children = ()
        self.logs = []

    def log(self, m):
        self.logs.append(m)

    def model(self, name):
        raise RuntimeError("no children in diag")


def load_model(name, overrides):
    d = Path("models") / name
    cfg = tomllib.loads((d / "model.toml").read_text()).get("config", {})
    for k, v in overrides.items():
        cur = cfg.get(k)
        if isinstance(cur, bool):
            cfg[k] = v.lower() in ("1", "true", "yes")
        elif isinstance(cur, (int, float)) or cur is None:
            try:
                cfg[k] = float(v) if ("." in v or "e" in v) else int(v)
            except ValueError:
                cfg[k] = v
        elif isinstance(cur, list):
            cfg[k] = [float(x) for x in v.split(",")]
        else:
            cfg[k] = v
    sys.path.insert(0, str(d))
    spec = importlib.util.spec_from_file_location(f"m_{name.replace('-', '_')}", d / "model.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.Model, cfg


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--n", type=int, default=40)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--cps", type=int, default=4, help="checkpoints per episode (evenly spaced incl. cutoff)")
    ap.add_argument("--cfg", nargs="*", default=[])
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--since", default="", help="keep only episodes with cutoff on/after this UTC date (YYYY-MM-DD)")
    ap.add_argument("--paths", default="", help="episode ids: print truth vs forecast quantiles at each checkpoint")
    ap.add_argument("--acct", default="", help="keep only episodes of this account")
    ap.add_argument("--eps", default="", help="comma-separated episode ids to print every checkpoint of")
    a = ap.parse_args()
    overrides = dict(kv.split("=", 1) for kv in a.cfg)
    Model, cfg = load_model(a.model, overrides)
    data = SnapshotData.load(None, "visible")
    index = TierIndex(data)
    scfg = SamplerConfig(episodes=a.n, seed=a.seed, targets=("meter.five_hour",), checkpoint_cap=24)
    eps = sample_episodes(index, scfg)
    if a.acct:
        eps = [e for e in eps if e.scope.accounts[0] == a.acct]
    if a.since:
        import datetime as _dt
        t_since = int(_dt.datetime.fromisoformat(a.since + "T00:00:00+00:00").timestamp() * 1000)
        eps = [e for e in eps if e.cutoff >= t_since]
    rows = []
    show_paths = {int(x) for x in a.paths.split(",") if x}
    t_start = time.time()
    for ep in eps:
        view = EpisodeView(data, ep.scope, ep.mode, ep.history_start)
        cps = list(ep.checkpoints)
        if a.cps < len(cps):
            pick = np.unique(np.linspace(0, len(cps) - 1, a.cps).round().astype(int))
            cps = [cps[i] for i in pick]
        ctx = Ctx(dict(cfg), ep.episode_id)
        m = Model(ctx)
        h = HistoryView(view.history(ep.cutoff), ep.cutoff, ep.scope, ep.mode, ep.history_start,
                        tz_offset_min=index.tz_offset_at(ep.cutoff))
        m.fit(h)
        prev = ep.cutoff
        for now in cps:
            if now != prev:
                ev = EventsView(view.events(prev, now), prev, now, tz_offset_min=index.tz_offset_at(now))
                m.update(ev)
                prev = now
            specs = specs_at(ep, now, index, scfg)
            if not specs:
                continue
            req = build_request(ep.scope, now, specs, 200)
            fc = m.forecast(req)
            truth = Truth({s.key: build_truth(index, s, now, tr.grid) for s, tr in zip(specs, req.targets)})
            sc = score_checkpoint(req, fc, truth)
            d = {r.metric: r.value for r in sc if r.lead_s is None}
            d.update({f"crps@{int(r.lead_s)}": r.value for r in sc if r.lead_s is not None and r.metric == "crps"})
            if "crps" not in d:
                continue
            d["ep"] = ep.episode_id
            d["acct"] = ep.scope.accounts[0]
            d["now"] = now
            d["lead_h"] = (specs[0].reset_at - now) / 3.6e6
            d["diag"] = getattr(m, "last_diag", None)
            try:
                from arena.scoring.checkpoint import interpolate_paths as _ip
                tr0 = req.targets[0]; tt = truth.by_key[tr0.key]; p = fc.by_key[tr0.key].paths
                keep = tt.times <= tr0.grid[-1]
                if keep.any():
                    at = _ip(p, tr0.grid, tt.times[keep]); med = np.median(at, axis=0)
                    d["bias"] = float(np.mean(med - tt.values[keep])); d["bias_reset"] = float(med[-1] - tt.values[keep][-1])
            except Exception:
                pass
            if ep.episode_id in show_paths:
                import datetime as dt
                tr0 = req.targets[0]; tt = truth.by_key[tr0.key]; p = fc.by_key[tr0.key].paths
                from arena.scoring.checkpoint import interpolate_paths
                keep = tt.times <= tr0.grid[-1]
                tms, vals = tt.times[keep], tt.values[keep]
                sel = np.unique(np.linspace(0, len(tms) - 1, min(6, len(tms))).round().astype(int))
                at = interpolate_paths(p, tr0.grid, tms[sel])
                q = np.quantile(at, [0.05, 0.25, 0.5, 0.75, 0.95], axis=0)
                print(f"  ep{ep.episode_id} now={dt.datetime.utcfromtimestamp(now/1000):%m-%d %H:%M} lead={(tr0.reset_at-now)/3.6e6:.2f}h diag={getattr(m, 'last_diag', None)}")
                for j, i in enumerate(sel):
                    print(f"     +{(tms[i]-now)/6e4:6.1f} min truth={vals[i]:5.1f}  q05/25/50/75/95 = {q[0,j]:5.1f} {q[1,j]:5.1f} {q[2,j]:5.1f} {q[3,j]:5.1f} {q[4,j]:5.1f}")
            rows.append(d)
        if ctx.logs and a.verbose:
            print("logs:", ctx.logs[:5])
    el = time.time() - t_start
    keys = ["crps", "ae_point", "ae_reset", "next_reading_ae", "cover50", "cover80", "cover95", "brier_hit", "crps_ttl", "energy"]
    print(f"{a.model} n_eps={len(eps)} n_cp={len(rows)} time={el:.1f}s cfg={overrides}")
    print("  " + "  ".join(f"{k}={np.nanmean([r.get(k, np.nan) for r in rows]):.4f}" for k in keys))
    pit = [np.nanmean([r.get(f'pit_b{b}', np.nan) for r in rows]) for b in range(10)]
    print("  pit " + " ".join(f"{p:.3f}" for p in pit))
    for e in (300, 1800, 3600, 7200, 18000):
        v = [r[f"crps@{e}"] for r in rows if f"crps@{e}" in r]
        if v:
            print(f"  crps@<={e:5d}s  {np.mean(v):.4f}  (n={len(v)})")
    # breakdown by initial state and by lead
    def grp(label, sel):
        rs = [r for r in rows if sel(r)]
        if not rs:
            return
        t0 = np.nanmean([r.get("pit_b0", np.nan) for r in rs]); t9 = np.nanmean([r.get("pit_b9", np.nan) for r in rs])
        print(f"  [{label:12s}] n={len(rs):3d} crps={np.mean([r['crps'] for r in rs]):.3f} ae_reset={np.nanmean([r.get('ae_reset', np.nan) for r in rs]):.2f} bias={np.nanmean([r.get('bias', np.nan) for r in rs]):+.2f} bias_reset={np.nanmean([r.get('bias_reset', np.nan) for r in rs]):+.2f} "
              f"c50={np.mean([r['cover50'] for r in rs]):.2f} c80={np.mean([r['cover80'] for r in rs]):.2f} c95={np.mean([r['cover95'] for r in rs]):.2f} pit0={t0:.3f} pit9={t9:.3f}")
    grp("active", lambda r: (r["diag"] or {}).get("act") is True)
    grp("idle", lambda r: (r["diag"] or {}).get("act") is False)
    grp("lead<1h", lambda r: r["lead_h"] < 1)
    grp("lead1-3h", lambda r: 1 <= r["lead_h"] < 3)
    grp("lead>=3h", lambda r: r["lead_h"] >= 3)
    grp("A1", lambda r: r["acct"] == "A1")
    grp("A2", lambda r: r["acct"] == "A2")
    show = {int(x) for x in a.eps.split(",") if x}
    for r in rows:
        if r["ep"] in show:
            import datetime as dt
            print(f"  ep{r['ep']} {r['acct']} now={dt.datetime.utcfromtimestamp(r['now']/1000):%m-%d %H:%M} lead={r['lead_h']:.2f}h "
                  f"crps={r['crps']:.2f} ae_reset={r.get('ae_reset', np.nan):.1f} pit0={r.get('pit_b0', np.nan):.2f} pit9={r.get('pit_b9', np.nan):.2f} diag={r['diag']}")
    if a.verbose:
        worst = sorted(rows, key=lambda r: -r["crps"])[:8]
        for r in worst:
            import datetime as dt
            print(f"  ep{r['ep']} {r['acct']} now={dt.datetime.utcfromtimestamp(r['now']/1000):%m-%d %H:%M} lead={r['lead_h']:.2f}h "
                  f"crps={r['crps']:.2f} ae_reset={r.get('ae_reset', np.nan):.1f} c50={r['cover50']:.2f} diag={r['diag']}")


if __name__ == "__main__":
    main()
