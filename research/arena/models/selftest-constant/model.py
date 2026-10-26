"""Self-test baseline (`arena selftest`): one constant for every grid time of
every target (`config.value`), and `cycle.next_start` never starts. Every leak
probe that finds nothing forecasts exactly this, so a probe that scores
differently from it on the same cells saw something."""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast


class Model:
    def __init__(self, ctx):
        self.value = float(ctx.config.get("value", 0.0))

    def fit(self, history):
        pass

    def update(self, events):
        pass

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target is Target.CYCLE_NEXT_START:
                out[tr.key] = TargetForecast(np.full((1, len(tr.grid)), np.nan))
            else:
                out[tr.key] = TargetForecast.point(np.full(len(tr.grid), self.value))
        return Forecast(out)
