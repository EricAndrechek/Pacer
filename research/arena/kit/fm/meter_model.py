"""A pretrained forecaster as a direct meter model (`models/fm-*-meter`).

For each meter target (5-hour, 7-day, a scoped cap) of one account:

1. the meter's cumulative burn (`kit.fm.series.meter_series`: this cycle's
   readings at the end, the previous cycles before them), resampled onto a
   regular grid ending at `now` (`step_min`, `context_steps`; a reading older
   than `stale_min` leaves a NaN gap);
2. the forecaster's quantiles of that series to the reset;
3. burn since now = quantile − latest value, per level non-decreasing and
   never negative; outer tails extended to 1 %/99 % where the head stops at
   10/90 (`kit.fm.paths.extend_tails`);
4. read at the request's grid times, added to the meter now (the latest
   reading of the cycle, as read: a re-based meter can be below an earlier
   reading), clipped to [the meter now, 100];
5. comonotone paths (a path that burns fast early keeps burning fast), or,
   for a sampler (Toto), its own sample paths, each made non-decreasing by
   isotonic regression (a running max would ratchet its noise upward: Toto's
   7-day CRPS went from 11 to 1.7 on synth).

Without a reading of the cycle within `stale_min` of now there is nothing to
continue: the forecast is the meter now, flat.

`model.toml` `[config]`:

    backend = "timestral"                 # kit.fm.backends.BACKENDS
    weights = "org/name@revision"         # the same string as model.toml `weights`
    threads = 4                           # torch threads unless $OMP_NUM_THREADS says otherwise
    stale_min = 120
    paths = "quantiles"                   # or "samples" (Toto)
    n_samples = 100                       # samples mode
    [config.step_min]       five_hour = 5,  seven_day = 15, weekly_scoped = 15
    [config.context_steps]  five_hour = 144, seven_day = 288, weekly_scoped = 288   # Timestral's
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from kit.fm.backends import get_backend
from kit.fm.paths import (
    burn_quantiles, extend_tails, fix_crossing, interp_times, isotonic_paths, monotone_meter, to_paths,
)
from kit.fm.series import MIN_MS, meter_series, regular_grid, resample_last

WINDOW_FOR = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}
DEFAULT_STEP_MIN = {"five_hour": 5, "seven_day": 15, "weekly_scoped": 15}
DEFAULT_CONTEXT = {"five_hour": 288, "seven_day": 672, "weekly_scoped": 672}


class MeterModel:
    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.history = None
        self._backend = None

    @property
    def backend(self):
        if self._backend is None:
            self._backend = get_backend(self.cfg["backend"], self.cfg["weights"], int(self.cfg.get("threads", 4)))
        return self._backend

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        readings = self.history.table("meter_readings")
        out = {}
        for tr in request.targets:
            wk = WINDOW_FOR.get(tr.target)
            if wk is not None:
                out[tr.key] = self.meter(readings, int(request.now), tr, wk)
        return Forecast(out)

    # ------------------------------------------------------------------
    def step_ms(self, wk: str) -> int:
        return int(self.cfg.get("step_min", {}).get(wk, DEFAULT_STEP_MIN[wk])) * MIN_MS

    def context_steps(self, wk: str) -> int:
        return int(self.cfg.get("context_steps", {}).get(wk, DEFAULT_CONTEXT[wk]))

    def meter(self, readings, now: int, tr, wk: str) -> TargetForecast:
        if self.cfg.get("paths", "quantiles") == "samples" and hasattr(self.backend, "samples"):
            return self._meter_samples(readings, now, tr, wk)
        mq = self.meter_quantiles(readings, now, tr, wk)
        if mq.levels is None:
            return TargetForecast.point(mq.q[:, 0], tr.n_paths)
        paths = to_paths(mq.levels, mq.q, tr.n_paths, "comonotone", rng=self.rng)
        return TargetForecast(monotone_meter(paths, mq.used))

    def _inputs(self, readings, now: int, tr, wk: str):
        """(used, ctx_v, step): the meter now, the context the forecaster
        reads (cumulative burn, resampled, NaN = stale), its step."""
        cap = tr.cap if tr.target is Target.METER_SCOPED else None
        s = meter_series(readings, tr.accounts[0], wk, cap, now)
        used = s.used_now(tr.reset_at) if tr.reset_at is not None else None
        if used is None:
            # No reading of this cycle known: the latest active reading, else 0.
            used = float(s.cycle_util[s.active][-1]) if s.active.any() else 0.0
        step = self.step_ms(wk)
        ctx_t = regular_grid(now, step, self.context_steps(wk))
        stale = int(self.cfg.get("stale_min", 120)) * MIN_MS
        return used, resample_last(s.times, s.cum, ctx_t, stale), step

    def meter_quantiles(self, readings, now: int, tr, wk: str) -> "MeterQuantiles":
        """The forecast's quantiles on the request grid, before any path is
        drawn (deterministic given the forecaster's weights): what the paths
        are read from, and what a port reproduces (`kit.detq`)."""
        used, ctx_v, step = self._inputs(readings, now, tr, wk)
        c_last = ctx_v[-1]
        grid = np.asarray(tr.grid, dtype=np.int64)
        if not np.isfinite(c_last) or used >= 100.0:
            return MeterQuantiles(used, None, np.full((len(grid), 1), min(used, 100.0)), ctx_v, step, 0, None, None)
        horizon = max(1, int(math.ceil((int(grid[-1]) - now) / step)))
        t_rel = step * np.arange(0, horizon + 1, dtype=np.float64)
        g_rel = (grid - now).astype(np.float64)
        raw_levels, q = self.backend.quantiles(ctx_v[None, None, :], horizon)
        burn = burn_quantiles(q[0, 0], c_last)                                             # [H, Q]
        levels, burn = extend_tails(raw_levels, burn)
        burn = fix_crossing(np.maximum.accumulate(np.maximum(burn, 0.0), axis=0))
        burn = np.vstack([np.zeros((1, burn.shape[1])), burn])
        meter_q = np.clip(used + interp_times(t_rel, g_rel, burn), used, 100.0)            # [G, Q]
        return MeterQuantiles(used, levels, meter_q, ctx_v, step, horizon, raw_levels, q[0, 0])

    def _meter_samples(self, readings, now: int, tr, wk: str) -> TargetForecast:
        used, ctx_v, step = self._inputs(readings, now, tr, wk)
        c_last = ctx_v[-1]
        grid = np.asarray(tr.grid, dtype=np.int64)
        if not np.isfinite(c_last) or used >= 100.0:
            return TargetForecast.point(np.full(len(grid), min(used, 100.0)), tr.n_paths)
        horizon = max(1, int(math.ceil((int(grid[-1]) - now) / step)))
        t_rel = step * np.arange(0, horizon + 1, dtype=np.float64)
        g_rel = (grid - now).astype(np.float64)
        smp = self.backend.samples(ctx_v[None, None, :], horizon, step_s=step / 1000.0,
                                   n_samples=int(self.cfg.get("n_samples", 100)),
                                   seed=int(self.rng.integers(2 ** 31)))[0, 0]       # [H, S]
        burn = np.vstack([np.zeros((1, smp.shape[1])), smp - c_last])                 # [H + 1, S]
        burn = np.maximum(isotonic_paths(burn.T), 0.0)                                 # [S, H + 1]
        paths = interp_times(t_rel, g_rel, burn.T).T                                   # [S, G]
        return TargetForecast(monotone_meter(used + paths, used))


@dataclass
class MeterQuantiles:
    """`q` [G, Q]: the meter at each grid time at `levels` (None: a flat
    forecast at `used`, one column). `ctx_v`, `step`, `horizon`, `raw_levels`
    and `raw` ([horizon, Q'], the forecaster's own quantiles of the cumulative
    burn) are the intermediates a port checks itself against."""

    used: float
    levels: np.ndarray | None
    q: np.ndarray
    ctx_v: np.ndarray
    step: int
    horizon: int
    raw_levels: np.ndarray | None
    raw: np.ndarray | None
