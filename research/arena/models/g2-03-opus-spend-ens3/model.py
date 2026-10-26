"""3-way ensemble of stat + analog + FM for spend.hourly and tokens.hourly.

Blends paths from:
- stat model (best marginal CRPS)
- analog model (best temporal coherence)
- FM-timestral (good variogram, smooth paths)
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
        self.fm = ctx.model("fm-timestral-28m-spend")
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        fc_stat = self.stat.forecast(request)
        fc_analog = self.analog.forecast(request)
        fc_fm = self.fm.forecast(request)

        w_s = float(self.cfg.get("stat_weight", 0.4))
        w_a = float(self.cfg.get("analog_weight", 0.4))
        w_f = float(self.cfg.get("fm_weight", 0.2))
        total = w_s + w_a + w_f

        out = {}
        for tr in request.targets:
            if tr.target not in HOURLY:
                continue
            key = tr.key
            n = tr.n_paths

            sources = []
            weights = []
            for fc, w in [(fc_stat, w_s), (fc_analog, w_a), (fc_fm, w_f)]:
                tf = fc.by_key.get(key)
                if tf is not None:
                    sources.append(tf.paths)
                    weights.append(w)

            if not sources:
                continue

            wtot = sum(weights)
            counts = []
            for i, w in enumerate(weights):
                if i < len(weights) - 1:
                    counts.append(int(round(n * w / wtot)))
                else:
                    counts.append(n - sum(counts))

            parts = []
            for src, cnt in zip(sources, counts):
                if cnt > 0:
                    idx = self.rng.choice(src.shape[0], size=cnt, replace=True)
                    parts.append(src[idx])

            if not parts:
                continue
            paths = np.concatenate(parts, axis=0)
            self.rng.shuffle(paths)
            out[key] = TargetForecast(np.maximum(paths[:n], 0.0))

        return Forecast(out)
