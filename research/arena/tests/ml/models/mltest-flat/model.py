"""A test child for the combiners: the cycle's latest known reading plus
`offset`, flat to the reset, with a small spread. With offset 0 it is a
fair baseline; below the latest reading (mltest-low) it can only be worse,
since a meter never falls within a cycle."""
from __future__ import annotations

import numpy as np
import polars as pl

from arena.types import Forecast, Target, TargetForecast

WINDOW = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}


class Model:
    def __init__(self, ctx):
        self.cfg, self.rng = ctx.config, ctx.rng

    def fit(self, history):
        self.h = history

    def update(self, events):
        self.h = self.h.extend(events)

    def forecast(self, request):
        r = self.h.table("meter_readings")
        out = {}
        for tr in request.targets:
            if tr.target not in WINDOW:
                continue
            m = r.filter((pl.col("account") == tr.accounts[0]) & (pl.col("window_kind") == WINDOW[tr.target])
                         & (pl.col("state") == "active"))
            if tr.cap is not None:
                m = m.filter(pl.col("scope_model") == tr.cap)
            if tr.reset_at is not None:
                m = m.filter((pl.col("resets_at").dt.epoch("ms") - tr.reset_at).abs() < 60_000)
            last = float(m.sort("t_event")["util_pct"][-1]) if m.height else 0.0
            c = min(last + float(self.cfg.get("offset", 0.0)), 100.0)
            noise = self.rng.normal(0.0, float(self.cfg.get("spread", 1.0)), size=(tr.n_paths, 1))
            out[tr.key] = TargetForecast(np.clip(np.full((tr.n_paths, len(tr.grid)), c) + noise, 0.0, 100.0))
        return Forecast(out)
