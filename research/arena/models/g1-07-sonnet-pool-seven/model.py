"""Linear pool (mixture) of meter forecasts: the analog-bootstrap model and the
spend-decay models. A mixture of ensembles is a mixture of their sample paths,
so each child contributes a share of the final paths in proportion to its
weight (evenly spaced picks from its own paths, which keeps the quantile
structure of sorted ensembles); ranges, hit chance and time to limit are then
read off the pooled paths like any other forecast.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast

KIND = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "scoped"}


class Model:
    def __init__(self, ctx):
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.children = {name: ctx.model(name) for name in ctx.children}
        self.weights = {k: dict(v) for k, v in self.cfg.get("weights", {}).items()}

    def fit(self, history):
        pass

    def update(self, events):
        pass

    def forecast(self, request):
        got = {}
        for name, ch in self.children.items():
            try:
                got[name] = ch.forecast(request).by_key
            except Exception as e:                       # a child that cannot answer must not sink the pool
                got[name] = {}
        out = {}
        for tr in request.targets:
            w = self.weights.get(KIND.get(tr.target, ""), {})
            parts = [(n, got[n][tr.key].paths, float(w.get(n, 0.0))) for n in self.children
                     if tr.key in got.get(n, {}) and w.get(n, 0.0) > 0]
            if not parts:
                continue
            tot = sum(p[2] for p in parts)
            P = tr.n_paths
            picks, acc = [], 0
            for i, (n, paths, wi) in enumerate(parts):
                m = P - acc if i == len(parts) - 1 else int(round(P * wi / tot))
                acc += m
                if m <= 0:
                    continue
                idx = np.unique(np.linspace(0, paths.shape[0] - 1, m).round().astype(int)) if paths.shape[0] > m else np.arange(paths.shape[0])
                if len(idx) < m:                         # fewer paths than asked: repeat evenly
                    idx = np.resize(np.arange(paths.shape[0]), m)
                picks.append(paths[idx])
            paths = np.concatenate(picks, axis=0)
            w = float(self.cfg.get("widen", {}).get(KIND.get(tr.target, ""), 0.0))
            if w != 0.0:
                # stretch (w > 0) or squeeze (w < 0) the ensemble about its pointwise median, never below
                # the lowest current value any path starts from
                med = np.median(paths, axis=0, keepdims=True)
                floor = float(np.min(paths[:, 0]))
                paths = np.maximum(med + (paths - med) * (1.0 + w), floor)
            paths = np.maximum.accumulate(np.clip(paths, 0.0, 100.0), axis=1)
            out[tr.key] = TargetForecast(paths)
        return Forecast(out)
