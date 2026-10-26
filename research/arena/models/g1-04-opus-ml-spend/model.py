"""LightGBM quantile regression for hourly spend and tokens.

Approach:
1. Build a weekly profile (like naive-diurnal-spend) as the seasonal baseline
2. Compute features: lags, recent activity, ratio to profile, lead
3. GBM predicts quantiles of the actual spend (not residuals)
4. Paths use AR(1) Gaussian copula for temporal correlation

The model trains walk-forward on the history's past hours.
"""
from __future__ import annotations

import math

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from kit import spend

HOUR_MS = 3_600_000
WEEK_H = 168


def weekly_profile(series: np.ndarray) -> np.ndarray:
    """Mean spend per hour-of-week slot from at least one complete week."""
    n = len(series)
    weeks = n // WEEK_H
    if weeks < 1:
        if n >= 24:
            daily = series[-(n // 24 * 24):].reshape(-1, 24).mean(axis=0)
            return np.tile(daily, 7)
        return np.full(WEEK_H, series.mean() if n > 0 else 0.0)
    used = series[-(weeks * WEEK_H):]
    return used.reshape(weeks, WEEK_H).mean(axis=0)


def build_features(series: np.ndarray, ends: np.ndarray, tz_offset_min: float,
                   profile: np.ndarray, lead_h: int, now_idx: int) -> np.ndarray:
    """Build feature vector for forecasting the hour ending at now_idx + lead_h.
    series[:now_idx] is the known data."""
    n = now_idx
    v = np.zeros(28)

    if n > 0 and len(ends) > 0:
        target_end = ends[min(now_idx - 1, len(ends) - 1)] + lead_h * HOUR_MS
        tz_ms = int(round(tz_offset_min * 60_000)) if math.isfinite(tz_offset_min) else 0
        local_h = ((target_end + tz_ms) // HOUR_MS) % 24
        local_dow = ((target_end + tz_ms) // (24 * HOUR_MS)) % 7
    else:
        local_h, local_dow = 0, 0

    v[0] = math.sin(2 * math.pi * local_h / 24)
    v[1] = math.cos(2 * math.pi * local_h / 24)
    v[2] = math.sin(2 * math.pi * local_dow / 7)
    v[3] = math.cos(2 * math.pi * local_dow / 7)

    for i, lag in enumerate([1, 2, 3, 6, 12, 24, 48, 168]):
        idx = n - lag
        v[4 + i] = series[idx] if idx >= 0 else 0.0

    for i, w in enumerate([6, 24, 168]):
        start = max(0, n - w)
        window = series[start:n]
        if len(window) > 0:
            v[12 + i] = window.mean()
            v[15 + i] = window.max()
            if i >= 1 and len(window) > 1:
                v[18 + i - 1] = window.std()

    v[20] = float(lead_h)

    for i, w in enumerate([6, 24]):
        start = max(0, n - w)
        window = series[start:n]
        v[21 + i] = float((window > 0).sum()) / max(len(window), 1) if len(window) else 0.0

    v[23] = float(series[max(0, n - 24):n].sum()) if n > 0 else 0.0

    how = int((local_dow * 24 + local_h) % WEEK_H)
    prof_val = profile[how]
    v[24] = prof_val

    recent_avg = float(series[max(0, n - 6):n].mean()) if n > 0 else 0.0
    v[25] = recent_avg / (prof_val + 1e-6) if prof_val > 0 else recent_avg

    v[26] = float(series[max(0, n - 1):n].sum() > 0) if n > 0 else 0.0
    v[27] = float(np.log1p(series[max(0, n - 24):n].sum())) if n > 0 else 0.0

    return v


def build_training_data(series: np.ndarray, ends: np.ndarray, tz_offset_min: float,
                        profile: np.ndarray, max_rows: int = 3000) -> tuple[np.ndarray, np.ndarray]:
    n = len(series)
    if n < 48:
        return np.zeros((0, 28)), np.zeros(0)

    leads = [1, 2, 4, 8, 16, 24]
    rows_per_lead = max_rows // len(leads)

    rows_X, rows_y = [], []
    start = max(WEEK_H, n - rows_per_lead)

    for t in range(start, n):
        for lead in leads:
            target_idx = t + lead
            if target_idx >= n:
                continue
            feat = build_features(series, ends, tz_offset_min, profile, lead, t)
            rows_X.append(feat)
            rows_y.append(series[target_idx])

    if not rows_X:
        return np.zeros((0, 28)), np.zeros(0)
    return np.array(rows_X), np.array(rows_y)


class Model:
    def __init__(self, ctx):
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.log = ctx.log
        self.history = None
        self._models: dict = {}

    def fit(self, history):
        self.history = history
        self._models = {}

    def update(self, events):
        self.history = self.history.extend(events)
        self._models = {}

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target is Target.SPEND_HOURLY:
                out[tr.key] = self._hourly(request.now, tr, "spend")
            elif tr.target is Target.TOKENS_HOURLY:
                out[tr.key] = self._hourly(request.now, tr, "tokens")
        return Forecast(out)

    def _get_models(self, key, series, ends, tz_min, profile):
        if key in self._models:
            return self._models[key]

        X, y = build_training_data(series, ends, tz_min, profile,
                                   int(self.cfg.get("train_hours", 3000)))
        if len(X) < 50:
            self._models[key] = None
            return None

        import lightgbm as lgb
        levels = np.asarray(self.cfg.get("levels", [0.05, 0.15, 0.3, 0.5, 0.7, 0.85, 0.95]))
        kw = dict(
            n_estimators=int(self.cfg.get("n_estimators", 150)),
            learning_rate=float(self.cfg.get("learning_rate", 0.05)),
            num_leaves=int(self.cfg.get("num_leaves", 15)),
            min_child_samples=int(self.cfg.get("min_child_samples", 20)),
            subsample=0.8, subsample_freq=1, colsample_bytree=0.8,
            reg_lambda=1.0, n_jobs=1, max_bin=63, verbose=-1,
        )
        boosters = [lgb.LGBMRegressor(objective="quantile", alpha=float(a), **kw).fit(X, y) for a in levels]

        self._models[key] = {"levels": levels, "boosters": boosters, "profile": profile}
        self.log(f"ml-spend trained {key}: {len(X)} rows, {len(levels)} levels")
        return self._models[key]

    def _hourly(self, now: int, tr, what: str) -> TargetForecast:
        ctx_key = "spend_context_hours" if what == "spend" else "tokens_context_hours"
        T = int(self.cfg.get(ctx_key, self.cfg.get("context_hours", 336)))
        family = tr.family
        ends, series = spend.hourly_series(self.history, tr.accounts, T, what, family)

        tz_min = 0.0
        if self.history.tz_offset_min is not None:
            tz_min = float(self.history.tz_offset_min)

        profile = weekly_profile(series)
        key = (what, tuple(tr.accounts), family)
        state = self._get_models(key, series, ends, tz_min, profile)

        steps = np.maximum(1, np.round(
            (np.asarray(tr.grid, dtype=np.int64) - now) / HOUR_MS)).astype(int)
        n_grid = len(tr.grid)

        if state is None:
            return self._profile_forecast(series, ends, tz_min, profile, steps, n_grid, tr.n_paths)

        levels = state["levels"]
        boosters = state["boosters"]
        n = len(series)

        quantiles = np.zeros((len(levels), n_grid))
        for i, step in enumerate(steps):
            feat = build_features(series, ends, tz_min, profile, int(step), n)
            X_pred = feat[None, :]
            for j, b in enumerate(boosters):
                quantiles[j, i] = b.predict(X_pred)[0]

        quantiles = np.maximum(quantiles, 0.0)
        quantiles = np.sort(quantiles, axis=0)

        sm_key = "spend_spread_mult" if what == "spend" else "tokens_spread_mult"
        spread_mult = float(self.cfg.get(sm_key, self.cfg.get("spread_mult", 1.5)))
        if spread_mult != 1.0:
            med_idx = len(levels) // 2
            med = quantiles[med_idx]
            for j in range(len(levels)):
                quantiles[j] = np.maximum(med + spread_mult * (quantiles[j] - med), 0.0)
            quantiles = np.sort(quantiles, axis=0)

        cap_key = "spend_cap_factor" if what == "spend" else "tokens_cap_factor"
        cap = float(self.cfg.get(cap_key, self.cfg.get("cap_factor", 3.0)))
        if cap > 0 and len(series) > 0:
            max_val = max(float(np.max(series)), 1.0)
            quantiles = np.minimum(quantiles, cap * max_val)

        lo_m = float(self.cfg.get("tail_lo_mult", 0.5))
        hi_m = float(self.cfg.get("tail_hi_mult", 2.0))
        lv_ext, q_ext = _extend_tails(levels, quantiles, lo_m, hi_m)
        paths = _ar1_paths(lv_ext, q_ext, tr.n_paths,
                           float(self.cfg.get("rho", 0.7)), self.rng)
        return TargetForecast(np.maximum(paths, 0.0))

    def _profile_forecast(self, series, ends, tz_min, profile, steps, n_grid, n_paths):
        """Fallback: use the weekly profile with past-weeks spread."""
        n = len(series)
        weeks = max(1, n // WEEK_H)
        if n >= 2 * WEEK_H:
            used = series[-(weeks * WEEK_H):]
            week_paths = used.reshape(weeks, WEEK_H)
            tz_ms = int(round(tz_min * 60_000)) if math.isfinite(tz_min) else 0
            if len(ends) > 0:
                base_hour = (ends[-1] + tz_ms) // HOUR_MS
            else:
                base_hour = 0
            result = np.zeros((weeks, n_grid))
            for i, step in enumerate(steps):
                how = int((base_hour + step) % WEEK_H)
                result[:, i] = week_paths[:, how]
            if weeks < n_paths:
                idx = self.rng.integers(0, weeks, size=n_paths)
                result = result[idx]
            return TargetForecast(np.maximum(result[:n_paths], 0.0))
        avg = float(profile.mean()) if len(profile) else 0.0
        return TargetForecast.point(np.full(n_grid, max(avg, 0.0)), n_paths)


def _extend_tails(levels: np.ndarray, q: np.ndarray,
                   lo_mult: float = 0.5, hi_mult: float = 2.0) -> tuple[np.ndarray, np.ndarray]:
    lo = np.maximum(q[0] - lo_mult * (q[1] - q[0]), 0.0)
    hi = q[-1] + hi_mult * (q[-1] - q[-2])
    hi = np.maximum(hi, q[-1])
    lv = np.concatenate(([0.0], levels, [1.0]))
    vals = np.vstack([lo, q, hi])
    return lv, vals


def _ar1_paths(levels: np.ndarray, q: np.ndarray, n_paths: int,
               rho: float, rng: np.random.Generator) -> np.ndarray:
    n_grid = q.shape[1]
    z = np.zeros((n_paths, n_grid))
    z[:, 0] = rng.standard_normal(n_paths)
    sq = math.sqrt(max(1 - rho ** 2, 1e-6))
    for t in range(1, n_grid):
        z[:, t] = rho * z[:, t - 1] + sq * rng.standard_normal(n_paths)

    from scipy.stats import norm
    u = norm.cdf(z)

    paths = np.zeros((n_paths, n_grid))
    for t in range(n_grid):
        paths[:, t] = np.interp(u[:, t], levels, q[:, t])
    return paths
