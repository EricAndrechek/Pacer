"""g2-07-opus-limit: meters forecast for the limit call.

Every meter (five-hour, seven-day, scoped cap) is simulated to its reset by
`limitsim`: the account's own burn, resampled in time-of-day-aligned blocks,
with the account's learned behaviour near 100 (rationing, parking below the
limit) and a learned re-base hazard. The chance of hitting the limit, the
time to it and the value at reset all come from those same paths.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast

import meters as M


class Model:
    def __init__(self, ctx):
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.log = ctx.log
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        h = self.history
        readings = h.table("meter_readings")
        tz_min = h.tz_offset_min or 0
        accounts = tuple(h.accounts) if getattr(h, "accounts", None) else ()
        out = {}
        for tr in request.targets:
            if tr.target not in M.WINDOW_OF:
                continue
            try:
                out[tr.key] = TargetForecast(M.meter_paths(readings, int(request.now), tr, tz_min, accounts,
                                                           self.rng, self.cfg))
            except Exception as ex:  # never fail the whole request
                self.log(f"{tr.key}: flat fallback after {type(ex).__name__}: {ex}")
                out[tr.key] = TargetForecast(M.flat_paths(readings, int(request.now), tr))
        return Forecast(out)
