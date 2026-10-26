"""spend.hourly and tokens.hourly as an analog ensemble of the group's own past.

Hourly spend is bursty: most hours are near zero or busy, and a busy spell
runs for hours. A pretrained forecaster smooths that; an analog ensemble
keeps it. From the group's own hourly series (kit.spend: priced as of now;
tokens optionally of one family), every past hour t' is described by:

- the last hour, the last 3 hours and the last day (log scale),
- the local hour of the day (circular) and weekday vs weekend,
- how long ago it was (a half-life in days),

and carries what followed: the series over the next H hours. The forecast
draws whole future trajectories from analogs in proportion to how much their
state looks like now's: so paths keep the real burstiness, the diurnal shape
and the persistence of busy spells, and the spread is the past's own.

A trajectory runs past `now` for analogs closer than H to it; those hours are
read one or more whole days earlier (the same hour of the day). With little
history (under two days) it is the last day's mean, flat.
"""
from __future__ import annotations

import math

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from kit import spend

HOUR_MS = 3_600_000
DAY_MS = 24 * HOUR_MS
MIN_MS = 60_000
HOURLY = (Target.SPEND_HOURLY, Target.TOKENS_HOURLY)


class Model:
    def __init__(self, ctx):
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target in HOURLY:
                out[tr.key] = self.hourly(int(request.now), tr)
        return Forecast(out)

    def _start(self) -> int:
        s = getattr(self.history, "start", None)
        if s is not None:
            return int(s)
        t = self.history.table("turns")
        if not t.height:
            return self.history.now
        import polars as pl
        return int(t.select(pl.col("t_event").dt.epoch("ms").min()).item())

    def hourly(self, now: int, tr) -> TargetForecast:
        cfg = self.cfg
        n = int(tr.n_paths)
        what = "spend" if tr.target is Target.SPEND_HOURLY else "tokens"
        fam = tr.family
        lead = np.rint((np.asarray(tr.grid, np.int64) - now) / HOUR_MS).astype(np.int64)   # 1, 2, ...
        H = int(lead.max())
        span_h = int(min(float(cfg.get("lookback_days", 90)) * 24, max(1, (now - self._start()) // HOUR_MS)))
        if span_h < 48:
            _, v = spend.hourly_series(self.history, tr.accounts, max(span_h, 1), what, fam)
            return TargetForecast.point(np.full(len(lead), float(v.mean()) if len(v) else 0.0), n)
        _, v = spend.hourly_series(self.history, tr.accounts, span_h, what, fam)
        v = np.maximum(v, 0.0)
        N = len(v)
        cs = np.concatenate(([0.0], np.cumsum(v)))

        def back(k, i):          # sum of the k hours ending at hour index i (inclusive)
            lo = np.maximum(i - k + 1, 0)
            return cs[i + 1] - cs[lo]

        scale = max(float(np.mean(v[v > 0])) if (v > 0).any() else 1.0, 1e-9)
        f = lambda x: np.log1p(x / scale)                                  # noqa: E731
        idx_now = N - 1
        s_now = np.array([f(back(1, idx_now)), f(back(3, idx_now) / 3), f(back(24, idx_now) / 24)])
        # Candidate analog hours: at least a day of past behind them, and at
        # least `min_ahead_h` hours of their future known.
        min_ahead = int(cfg.get("min_ahead_h", 24))
        cand = np.arange(24, N - min_ahead)
        if len(cand) < 24:
            return TargetForecast.point(np.full(len(lead), float(v[-24:].mean())), n)
        S = np.stack([f(back(1, cand)), f(back(3, cand) / 3), f(back(24, cand) / 24)], axis=1)
        bw = np.asarray(cfg.get("bandwidths", [0.6, 0.5, 0.4]), np.float64)
        d2 = (((S - s_now[None, :]) / bw[None, :]) ** 2).sum(axis=1)
        w = np.exp(-0.5 * d2)
        tz = (self.history.tz_offset_min or 0) * MIN_MS
        t_cand = now - (idx_now - cand) * HOUR_MS
        hp = ((t_cand + tz) % DAY_MS) / HOUR_MS
        hn = ((now + tz) % DAY_MS) / HOUR_MS
        w *= np.exp(float(cfg.get("kappa_hour", 2.0)) * (np.cos(2 * np.pi * (hp - hn) / 24.0) - 1.0))
        wd_p = (((t_cand + tz) // DAY_MS) + 3) % 7 >= 5
        wd_n = (((now + tz) // DAY_MS) + 3) % 7 >= 5
        w *= np.where(wd_p == wd_n, 1.0, float(cfg.get("weekend_mismatch", 0.5)))
        w *= 0.5 ** ((idx_now - cand) / (float(cfg.get("half_life_days", 21.0)) * 24))
        if not np.isfinite(w).all() or w.sum() <= 0:
            w = np.ones(len(cand))
        pick = cand[self.rng.choice(len(cand), size=n, p=w / w.sum())]
        # Future hour j of analog i is hour index pick + j; past now, wrap back
        # by whole days (same hour of day).
        J = pick[:, None] + lead[None, :]
        over = J > idx_now
        J = np.where(over, J - 24 * np.ceil((J - idx_now) / 24).astype(np.int64), J)
        J = np.clip(J, 0, idx_now)
        paths = v[J]
        jit = float(cfg.get("jitter", 0.1))
        if jit > 0:
            paths = paths * np.exp(self.rng.normal(0, jit, size=paths.shape))
        return TargetForecast(paths)
