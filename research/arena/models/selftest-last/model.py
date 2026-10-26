"""Self-test naive model (`arena selftest`): the last value known at `now`,
held flat.

- Meters: the latest known reading of the requested cycle (its own reset
  within half a window of the requested one), else 0.
- Spend and tokens: what the group's turns known at `now` add up to over the
  hour ending at `now` (spend priced with the rates known at `now`).

Kept trivial so its scores can be computed by hand (`arena selftest`, known
answers)."""
from __future__ import annotations

import numpy as np
import polars as pl

from arena.pricing import price_turns
from arena.snapshot.cycles import window_ms
from arena.types import Forecast, Target, TargetForecast

HOUR_MS = 3_600_000
WINDOW = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}


def cycle_readings(history, tr) -> pl.DataFrame:
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
            if tr.target in WINDOW:
                r = cycle_readings(self.history, tr)
                v = float(r["util_pct"][-1]) if r.height else 0.0
            elif tr.target in (Target.SPEND_HOURLY, Target.TOKENS_HOURLY):
                v = self._last_hour(request.now, tr)
            else:
                continue
            out[tr.key] = TargetForecast.point(np.full(len(tr.grid), v))
        return Forecast(out)

    def _last_hour(self, now, tr) -> float:
        t = self.history.table("turns").filter(
            pl.col("account").is_in(list(tr.accounts))
            & (pl.col("t_event").dt.epoch("ms") > now - HOUR_MS) & (pl.col("t_event").dt.epoch("ms") <= now))
        if tr.target is Target.SPEND_HOURLY:
            t = price_turns(t, self.history.table("prices"), as_of=now)
            return float(t["cost_usd"].sum() or 0.0)
        if tr.family is not None:
            t = t.filter(pl.col("model_family") == tr.family)
        cols = ["input", "output", "cache_read", "cache_write_5m", "cache_write_1h"]
        return float(t.select(pl.sum_horizontal([pl.col(c).fill_null(0) for c in cols])).to_series().sum() or 0.0)
