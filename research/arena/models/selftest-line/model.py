"""Self-test straight line (`arena selftest`): least squares through every
known reading of the requested cycle (time = t_event), extended to every grid
time, clipped to [0, 100]; flat at the last reading with fewer than two.

On a world whose meters rise linearly it is exact, which makes it a check of
time alignment end to end: the runner's grid, the as-of history and the
scorer's truth must all agree on when a reading happened for it to score 0."""
from __future__ import annotations

import numpy as np
import polars as pl

from arena.snapshot.cycles import window_ms
from arena.types import Forecast, Target, TargetForecast

WINDOW = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}


def cycle_readings(history, tr) -> pl.DataFrame:
    """The requested cycle's known readings (same rule as selftest-last; a
    model folder is hashed alone, so it is restated, not imported)."""
    kind = WINDOW[tr.target]
    r = history.table("meter_readings").filter(
        (pl.col("account") == tr.accounts[0]) & (pl.col("window_kind") == kind) & (pl.col("state") == "active"))
    if tr.cap is not None:
        r = r.filter(pl.col("scope_model") == tr.cap)
    if tr.reset_at is not None:
        r = r.filter((pl.col("resets_at").dt.epoch("ms") - tr.reset_at).abs() < window_ms(kind) / 2)
    return r.sort(["t_event", "t_known"])


class Model:
    def __init__(self, ctx):
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target not in WINDOW:
                continue
            r = cycle_readings(self.history, tr)
            g = tr.grid.astype(np.float64)
            if r.height == 0:
                v = np.zeros(len(g))
            elif r.height == 1:
                v = np.full(len(g), float(r["util_pct"][0]))
            else:
                t = r["t_event"].dt.epoch("ms").to_numpy().astype(np.float64)
                y = r["util_pct"].to_numpy().astype(np.float64)
                t0 = t[-1]                              # centred: well conditioned at epoch-ms scale
                m, b = np.polyfit(t - t0, y, 1)
                v = m * (g - t0) + b
            out[tr.key] = TargetForecast.point(np.clip(v, 0.0, 100.0))
        return Forecast(out)
