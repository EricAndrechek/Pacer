"""A test child for the calibration layer: a sensible median (the latest
reading, rising at the cycle's pace so far) with a far too wide spread."""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, TargetForecast
from kit import baselines as B


class Model:
    def __init__(self, ctx):
        self.cfg, self.rng = ctx.config, ctx.rng

    def fit(self, history):
        self.h = history

    def update(self, events):
        self.h = self.h.extend(events)

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target not in B.WINDOW_OF:
                continue
            med = B.meter_linear(self.h, tr).paths[0]
            z = np.sort(self.rng.normal(0.0, float(self.cfg.get("spread", 25.0)), size=tr.n_paths))
            self.rng.shuffle(z)
            # One offset per path (comonotone), so every path is parallel to the median.
            out[tr.key] = TargetForecast(np.clip(np.rint(med[None, :] + z[:, None]), 0.0, 100.0))
        return Forecast(out)
