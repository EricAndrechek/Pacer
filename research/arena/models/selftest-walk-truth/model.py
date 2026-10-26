"""Self-test calibration model (`arena selftest`, synthetic snapshots only).

It reads the generating truth (`config.truth_dir`, which only the self-test
sets, like the oracle's channel) and draws meter paths from the SAME law the
simulator used for a reading:

    reading(t) = floor(min(100, sum over increments up to t of
                             delta_clean_i * lognormal(-s^2/2, s)))      (s = meter.noise_sigma)

For a requested cycle it takes that cycle's true clean increments (turns and
unobserved usage, from truth/meter_true.parquet and unobserved.parquet),
re-draws the per-increment observation noise per path, accumulates to each
grid time, floors and clips. Because the actual reading is one draw from this
same law, the ensemble is the correct predictive distribution: PIT flat,
coverage nominal. It is not the oracle — it never sees the realised noise — so
its CRPS is small but not zero. It beats the naive and line baselines because
it follows the true trajectory. Without `truth_dir` it falls back to the last
known reading, flat (so the folder is still runnable)."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import polars as pl

from arena.snapshot.cycles import window_ms
from arena.types import Forecast, Target, TargetForecast

WINDOW = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.rng = ctx.rng
        truth_dir = ctx.config.get("truth_dir", "")
        self.sigma = 0.0
        self.meter_true = None
        self.unobserved = None
        self.server_lag_ms = 0
        if truth_dir:
            td = Path(truth_dir)
            params = json.loads((td / "params.json").read_text())
            self.sigma = float(params["config"]["meter"]["noise_sigma"])
            self.server_lag_ms = int(float(params["config"]["meter"].get("server_lag_s", 0)) * 1000)
            self.meter_true = pl.read_parquet(td / "meter_true.parquet").with_columns(
                pl.col("t").dt.epoch("ms").alias("_t"), pl.col("reset_at").dt.epoch("ms").alias("_reset"))

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target in WINDOW:
                out[tr.key] = self._meter(request.now, tr)
        return Forecast(out)

    def _last_known(self, now, tr) -> float:
        kind = WINDOW[tr.target]
        r = self.history.table("meter_readings").filter(
            (pl.col("account") == tr.accounts[0]) & (pl.col("window_kind") == kind) & (pl.col("state") == "active"))
        if tr.cap is not None:
            r = r.filter(pl.col("scope_model") == tr.cap)
        if tr.reset_at is not None:
            r = r.filter((pl.col("resets_at").dt.epoch("ms") - tr.reset_at).abs() < window_ms(kind) / 2)
        r = r.sort(["t_event", "t_known"])
        return float(r["util_pct"][-1]) if r.height else 0.0

    def _meter(self, now, tr) -> TargetForecast:
        n, g = tr.n_paths, tr.grid.astype(np.int64)
        if self.meter_true is None or tr.reset_at is None:
            return TargetForecast.point(np.full(len(g), self._last_known(now, tr)), n)
        kind = WINDOW[tr.target]
        cyc = self.meter_true.filter(
            (pl.col("account") == tr.accounts[0]) & (pl.col("window_kind") == kind)
            & ((pl.col("_reset") - tr.reset_at).abs() < window_ms(kind) // 2))
        if tr.cap is not None:
            cyc = cyc.filter(pl.col("scope_model") == tr.cap)
        else:
            cyc = cyc.filter(pl.col("scope_model").is_null())
        cyc = cyc.sort("_t")
        if cyc.height == 0:
            return TargetForecast.point(np.full(len(g), self._last_known(now, tr)), n)
        # A reading at poll time p reports util as of p - server_lag, so an
        # increment at t_event lands in readings at p >= t_event + lag.
        t = cyc["_t"].to_numpy().astype(np.int64) + self.server_lag_ms
        dclean = cyc["delta_clean"].to_numpy().astype(np.float64)
        # One lognormal factor per increment per path (the simulator's law).
        s = self.sigma
        noise = self.rng.lognormal(-s * s / 2, s, size=(n, len(dclean))) if s > 0 else np.ones((n, len(dclean)))
        contrib = dclean[None, :] * noise                       # [n, I]
        cumul = np.cumsum(contrib, axis=1)                      # util after each increment
        idx = np.searchsorted(t, g, side="right") - 1           # last increment at or before each grid time
        paths = np.where(idx[None, :] >= 0, cumul[:, np.clip(idx, 0, len(t) - 1)], 0.0)
        return TargetForecast(np.clip(np.floor(paths), 0.0, 100.0))
