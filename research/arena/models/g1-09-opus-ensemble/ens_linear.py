"""The simplest model that follows the contract, kept deliberately naive so
it reads in a minute.

Meters: fit y = m·t + b through the last few readings of the current cycle
and extend the line to every grid time, never below the latest reading or
above 100. The spread of paths comes from how far the readings sat from the
line. Spend: the average hourly API-equivalent dollars of the last day, flat,
with the turns priced at the rates known at `now` (`arena.pricing`).
"""
from __future__ import annotations

import numpy as np
import polars as pl

from arena.pricing import price_turns
from arena.types import Forecast, Target, TargetForecast

HOUR_MS = 3_600_000
WINDOW_FOR = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}


class Model:
    def __init__(self, ctx):
        self.cfg = ctx.config
        self.rng = ctx.rng
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        # Keep it simple: re-read everything known so far. A real model would
        # fold `events` into its own state instead.
        self.history = self.history.extend(events)

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target in WINDOW_FOR:
                out[tr.key] = self._meter(tr)
            elif tr.target is Target.SPEND_HOURLY:
                out[tr.key] = self._spend(request.now, tr)
        return Forecast(out)

    def _meter(self, tr):
        r = self.history.table("meter_readings").filter(
            (pl.col("account") == tr.accounts[0])
            & (pl.col("window_kind") == WINDOW_FOR[tr.target])
            & (pl.col("state") == "active")
        )
        if tr.cap is not None:
            r = r.filter(pl.col("scope_model") == tr.cap)
        if tr.reset_at is not None:
            # Readings of this cycle: their reset is within a minute of the
            # requested one (resets jitter by milliseconds; never match ==).
            r = r.filter((pl.col("resets_at").dt.epoch("ms") - tr.reset_at).abs() < 60_000)
        r = r.sort("t_event").tail(int(self.cfg.get("recent_readings", 12)))
        grid = tr.grid.astype(np.float64)
        if r.height == 0:
            return TargetForecast.point(np.zeros(len(grid)), tr.n_paths)
        t = r["t_event"].dt.epoch("ms").to_numpy().astype(np.float64)
        y = r["util_pct"].to_numpy()
        if r.height >= 2 and np.ptp(t) > 0:
            m, b = np.polyfit(t, y, 1)
            m = max(m, 0.0)                        # a meter doesn't fall within a cycle
            resid = float(np.std(y - (m * t + b))) if r.height > 2 else 1.0
        else:
            m, b, resid = 0.0, y[-1], 1.0
        center = np.clip(m * grid + b, y[-1], 100.0)
        noise = self.rng.normal(0.0, max(resid, 0.5), size=(tr.n_paths, 1))
        return TargetForecast(np.clip(center[None, :] + noise, y[-1], 100.0))

    def _spend(self, now, tr):
        lookback = int(self.cfg.get("spend_lookback_h", 24)) * HOUR_MS
        # Priced with the rates known at `now` (a turn with no known rate is
        # null, never 0, and simply doesn't count here).
        turns = self.history.table("turns").filter(
            pl.col("account").is_in(list(tr.accounts))
            & (pl.col("t_event").dt.epoch("ms") > now - lookback)
        )
        turns = price_turns(turns, self.history.table("prices"), as_of=self.history.now)
        per_hour = float(turns["cost_usd"].sum() or 0.0) / (lookback / HOUR_MS)
        return TargetForecast.point(np.full(len(tr.grid), per_hour), tr.n_paths)
