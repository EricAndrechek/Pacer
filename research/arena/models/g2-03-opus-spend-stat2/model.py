"""Stat model v2: convex spread + surprise paths for heavy tails.

Key changes from stat v1:
- Convex spread: tails stretch more than center (no kink)
- Surprise paths: 15% of paths with 2x deviation for tail coverage
- Higher cap (10x max_seen)
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from kit import spend
from kit.fm.paths import extend_tails, to_paths

HOUR_MS = 3_600_000
DAY_MS = 24 * HOUR_MS


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
        out = {}
        for tr in request.targets:
            if tr.target is Target.SPEND_HOURLY:
                out[tr.key] = self._hourly(int(request.now), tr, "spend")
            elif tr.target is Target.TOKENS_HOURLY:
                out[tr.key] = self._hourly(int(request.now), tr, "tokens")
        return Forecast(out)

    def _hourly(self, now: int, tr, what: str) -> TargetForecast:
        T = int(self.cfg.get("context_hours", 672))
        ends, series = spend.hourly_series(
            self.history, tr.accounts, T, what, tr.family
        )
        series = np.maximum(series, 0.0)
        n = len(series)
        n_paths = tr.n_paths

        steps = np.maximum(
            1, np.round((np.asarray(tr.grid, dtype=np.int64) - now) / HOUR_MS)
        ).astype(int)
        n_grid = len(tr.grid)

        if n < 48:
            avg = float(series.mean()) if n > 0 else 0.0
            return TargetForecast.point(np.full(n_grid, avg), n_paths)

        tz_ms = int((self.history.tz_offset_min or 0) * 60_000)

        hour_of_day = ((ends + tz_ms) // HOUR_MS).astype(int) % 24
        day_of_week = (((ends + tz_ms) // DAY_MS) + 3).astype(int) % 7

        recent_6h = series[-min(6, n):]

        halflife_h = float(self.cfg.get("recency_halflife_h", 168))
        recency = np.exp(-np.arange(n - 1, -1, -1, dtype=np.float64)
                         * np.log(2) / halflife_h)

        kappa_hour = float(self.cfg.get("kappa_hour", 2.0))
        kappa_dow = float(self.cfg.get("kappa_dow", 1.5))

        inner_levels = np.array([0.025, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30,
                                 0.35, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65,
                                 0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 0.975])
        quantiles = np.zeros((n_grid, len(inner_levels)))

        sort_idx = np.argsort(series)
        sorted_series = series[sort_idx]

        for i, step in enumerate(steps):
            target_time = now + int(step) * HOUR_MS
            target_hod = int(((target_time + tz_ms) // HOUR_MS) % 24)
            target_dow = int((((target_time + tz_ms) // DAY_MS) + 3) % 7)

            hod_sim = np.exp(kappa_hour * (
                np.cos(2 * np.pi * (hour_of_day - target_hod) / 24.0) - 1.0))
            dow_sim = np.exp(kappa_dow * (
                np.cos(2 * np.pi * (day_of_week - target_dow) / 7.0) - 1.0))

            w = recency * hod_sim * dow_sim
            w_sum = w.sum()
            if w_sum <= 0:
                w = np.ones(n) / n
            else:
                w = w / w_sum

            sw = w[sort_idx]
            cw = np.cumsum(sw)
            cw = cw / cw[-1]
            eq = np.interp(inner_levels, cw, sorted_series)

            if step <= 6:
                recent_pos = recent_6h[recent_6h > 0]
                if len(recent_pos) > 0:
                    r_med = float(np.median(recent_pos))
                    q_med_idx = len(inner_levels) // 2
                    q_med = eq[q_med_idx]
                    blend = max(0, 1.0 - step / 6.0) * 0.25
                    shift = blend * (r_med - q_med)
                    eq = np.maximum(eq + shift, 0.0)

            lead_blur = 1.0 + 0.03 * min(step, 72)
            if lead_blur > 1.01:
                med_val = eq[len(inner_levels) // 2]
                eq = med_val + lead_blur * (eq - med_val)
                eq = np.maximum(eq, 0.0)

            quantiles[i] = eq

        quantiles = np.sort(quantiles, axis=1)

        lv_ext, q_ext = extend_tails(inner_levels, quantiles, lo=0.005,
                                      hi=0.995)
        q_ext = np.maximum(q_ext, 0.0)

        max_seen = float(np.max(series)) if n > 0 else 100.0
        cap = max_seen * 10.0
        q_ext = np.minimum(q_ext, cap)

        rho = self._estimate_rho(series)

        surprise_frac = float(self.cfg.get("surprise_frac", 0.15))
        n_surprise = int(round(n_paths * surprise_frac))

        paths = to_paths(lv_ext, q_ext, n_paths, "ar1", rho=rho, rng=self.rng)
        paths = np.maximum(paths, 0.0)

        if n_surprise > 0:
            surprise_factor = float(self.cfg.get("surprise_factor", 2.0))
            medians = q_ext[:, q_ext.shape[1] // 2]
            surprise_idx = self.rng.choice(n_paths, size=n_surprise,
                                            replace=False)
            for idx in surprise_idx:
                dev = paths[idx] - medians
                paths[idx] = np.maximum(medians + surprise_factor * dev, 0.0)

        self.rng.shuffle(paths)
        return TargetForecast(paths)

    def _estimate_rho(self, series: np.ndarray) -> float:
        n = len(series)
        if n < 50:
            return float(self.cfg.get("rho", 0.85))
        recent = series[-min(336, n):]
        m = recent.mean()
        if m < 1e-9:
            return float(self.cfg.get("rho", 0.85))
        centered = recent - m
        var = float(np.mean(centered ** 2))
        if var < 1e-12:
            return float(self.cfg.get("rho", 0.85))
        cov1 = float(np.mean(centered[:-1] * centered[1:]))
        rho_est = np.clip(cov1 / var, 0.0, 0.95)
        return float(np.clip(0.5 * rho_est + 0.5 * 0.85, 0.5, 0.95))
