"""Linear pool of the burst-process model and a pretrained forecaster.

The two make different mistakes: the burst model knows whether the user is
working and how long spells last, the pretrained forecaster extrapolates the
recent slope of the cumulative burn with a well-shaped band. Pooling their
sample paths (a mixture of ensembles is a mixture of their paths) gives a
forecast whose CRPS is usually below both. Within the first `head_min`
minutes every path is pinned to the burst model's path (its integer start is
the better next-reading guess).
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast


class Model:
    def __init__(self, ctx):
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.log = ctx.log
        self.children = {n: ctx.model(n) for n in ctx.children}
        self.weights = {k: float(v) for k, v in self.cfg.get("weights", {}).items()}

    def fit(self, history):
        pass

    def update(self, events):
        pass

    def forecast(self, request):
        got = {}
        for name, ch in self.children.items():
            try:
                got[name] = ch.forecast(request).by_key
            except Exception as ex:
                self.log(f"child {name} failed: {type(ex).__name__}: {ex}")
                got[name] = {}
        out = {}
        head = float(self.cfg.get("head_min", 3)) * 60_000
        for tr in request.targets:
            if tr.target is not Target.METER_5H:
                continue
            parts = [(n, got[n][tr.key].paths, self.weights.get(n, 0.0)) for n in self.children
                     if tr.key in got.get(n, {}) and self.weights.get(n, 0.0) > 0]
            if not parts:
                continue
            tot = sum(p[2] for p in parts)
            P = int(tr.n_paths)
            picks, acc = [], 0
            for i, (n, paths, w) in enumerate(parts):
                m = P - acc if i == len(parts) - 1 else int(round(P * w / tot))
                acc += m
                if m <= 0:
                    continue
                k = paths.shape[0]
                idx = np.unique(np.linspace(0, k - 1, m).round().astype(int)) if k > m else np.arange(k)
                if len(idx) < m:
                    idx = np.resize(np.arange(k), m)
                picks.append(paths[idx])
            paths = np.concatenate(picks, axis=0)
            # the dense head follows the burst model: its start is the next reading's best guess
            base = got.get("g2-08-fable-burst", {}).get(tr.key)
            if base is not None and base.paths.shape[0] >= 1:
                lead = (np.asarray(tr.grid, dtype=np.float64) - request.now)
                hm = lead <= head
                if hm.any():
                    b = base.paths
                    bidx = np.resize(np.arange(b.shape[0]), paths.shape[0])
                    paths[:, hm] = b[bidx][:, hm]
            paths = np.maximum.accumulate(np.clip(paths, 0.0, 100.0), axis=1)
            out[tr.key] = TargetForecast(paths)
        return Forecast(out)
