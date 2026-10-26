"""Self-test child (`arena selftest`): logs the moment and the latest t_known
of everything it was fitted on and asked, then forecasts 0. A parent probe
asks it for later moments and other scopes; the runner must answer for the
parent's own moment and view whatever the request claims."""
from __future__ import annotations

import json

import numpy as np
import polars as pl

from arena.types import Forecast, TargetForecast


def max_known(history) -> int | None:
    best = None
    for name in history.tables:
        df = history.table(name)
        if df.height:
            v = df.select(pl.col("t_known").dt.epoch("ms").max()).item()
            if v is not None and (best is None or v > best):
                best = int(v)
    return best


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.history = None

    def fit(self, history):
        self.history = history
        self.ctx.log("SPY " + json.dumps({"event": "fit", "now": history.now, "max_known": max_known(history),
                                          "accounts": list(history.accounts)}))

    def forecast(self, request):
        self.ctx.log("SPY " + json.dumps({"event": "forecast", "now": request.now,
                                          "history_now": self.history.now if self.history else None,
                                          "scope": list(request.scope.accounts)}))
        return Forecast({tr.key: TargetForecast.point(np.zeros(len(tr.grid))) for tr in request.targets})
