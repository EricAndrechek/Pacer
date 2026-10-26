"""Ensemble of stat + analog models for spend.hourly and tokens.hourly.

Blends paths from the stat model (better CRPS/marginal calibration) with
paths from the analog model (better temporal coherence/variogram).
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast

HOURLY = (Target.SPEND_HOURLY, Target.TOKENS_HOURLY)


class Model:
    def __init__(self, ctx):
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.stat = ctx.model("g2-03-opus-spend-stat")
        self.analog = ctx.model("g1-09-opus-analog-spend")
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        fc_stat = self.stat.forecast(request)
        fc_analog = self.analog.forecast(request)

        w_stat = float(self.cfg.get("stat_weight", 0.7))

        out = {}
        for tr in request.targets:
            if tr.target not in HOURLY:
                continue
            key = tr.key
            n = tr.n_paths

            s_tf = fc_stat.by_key.get(key)
            a_tf = fc_analog.by_key.get(key)

            if s_tf is None and a_tf is None:
                continue

            s_paths = s_tf.paths if s_tf is not None else None
            a_paths = a_tf.paths if a_tf is not None else None

            if s_paths is None:
                out[key] = TargetForecast(a_paths)
                continue
            if a_paths is None:
                out[key] = TargetForecast(s_paths)
                continue

            n_stat = int(round(n * w_stat))
            n_analog = n - n_stat

            idx_s = self.rng.choice(s_paths.shape[0], size=n_stat,
                                     replace=True)
            idx_a = self.rng.choice(a_paths.shape[0], size=n_analog,
                                     replace=True)

            paths = np.concatenate([s_paths[idx_s], a_paths[idx_a]],
                                   axis=0)
            self.rng.shuffle(paths)
            out[key] = TargetForecast(np.maximum(paths[:n], 0.0))

        return Forecast(out)
