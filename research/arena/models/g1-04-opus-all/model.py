"""Comprehensive ML model covering all 7 targets.

Meters: LightGBM quantile regression (based on ml-gbm-quantile approach) with
  per-level spread scaling calibrated out-of-fold.
Spend/Tokens: LightGBM quantile regression with lag features and AR(1) paths.
Split: Recent share baseline.
Cycle.next_start: Persistence baseline.
"""
from __future__ import annotations

import math

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from kit import spend
from kit.ml.meter_model import ANCHORS, WINDOW_OF, LearnedMeterModel
from kit.ml.paths import rise_paths

HOUR_MS = 3_600_000
WEEK_H = 168
SCALES = np.linspace(0.5, 8.0, 76)


def pinball(y, q, a):
    d = y - q
    return float(np.mean(np.maximum(a * d, (a - 1) * d)))


# =============================================================================
# Spend/Tokens helpers
# =============================================================================

def weekly_profile(series):
    n = len(series)
    weeks = n // WEEK_H
    if weeks < 1:
        if n >= 24:
            return np.tile(series[-(n // 24 * 24):].reshape(-1, 24).mean(axis=0), 7)
        return np.full(WEEK_H, series.mean() if n > 0 else 0.0)
    return series[-(weeks * WEEK_H):].reshape(weeks, WEEK_H).mean(axis=0)


def spend_features(series, ends, tz_min, profile, lead_h, now_idx):
    n = now_idx
    v = np.zeros(28)
    if n > 0 and len(ends) > 0:
        target_end = ends[min(now_idx - 1, len(ends) - 1)] + lead_h * HOUR_MS
        tz_ms = int(round(tz_min * 60_000)) if math.isfinite(tz_min) else 0
        local_h = ((target_end + tz_ms) // HOUR_MS) % 24
        local_dow = ((target_end + tz_ms) // (24 * HOUR_MS)) % 7
    else:
        local_h, local_dow = 0, 0
    v[0] = math.sin(2 * math.pi * local_h / 24)
    v[1] = math.cos(2 * math.pi * local_h / 24)
    v[2] = math.sin(2 * math.pi * local_dow / 7)
    v[3] = math.cos(2 * math.pi * local_dow / 7)
    for i, lag in enumerate([1, 2, 3, 6, 12, 24, 48, 168]):
        v[4 + i] = series[max(0, n - lag)] if n > lag else 0.0
    for i, w in enumerate([6, 24, 168]):
        window = series[max(0, n - w):n]
        if len(window) > 0:
            v[12 + i] = window.mean()
            v[15 + i] = window.max()
            if i >= 1 and len(window) > 1:
                v[18 + i - 1] = window.std()
    v[20] = float(lead_h)
    for i, w in enumerate([6, 24]):
        window = series[max(0, n - w):n]
        v[21 + i] = float((window > 0).sum()) / max(len(window), 1) if len(window) else 0.0
    v[23] = float(series[max(0, n - 24):n].sum()) if n > 0 else 0.0
    how = int((local_dow * 24 + local_h) % WEEK_H)
    v[24] = profile[how]
    recent = float(series[max(0, n - 6):n].mean()) if n > 0 else 0.0
    v[25] = recent / (profile[how] + 1e-6) if profile[how] > 0 else recent
    v[26] = float(series[max(0, n - 1):n].sum() > 0) if n > 0 else 0.0
    v[27] = float(np.log1p(series[max(0, n - 24):n].sum())) if n > 0 else 0.0
    return v


def spend_training(series, ends, tz_min, profile, max_rows=3000):
    n = len(series)
    if n < 48:
        return np.zeros((0, 28)), np.zeros(0)
    leads = [1, 2, 4, 8, 16, 24]
    start = max(WEEK_H, n - max_rows // len(leads))
    Xs, ys = [], []
    for t in range(start, n):
        for lead in leads:
            if t + lead >= n:
                continue
            Xs.append(spend_features(series, ends, tz_min, profile, lead, t))
            ys.append(series[t + lead])
    return (np.array(Xs), np.array(ys)) if Xs else (np.zeros((0, 28)), np.zeros(0))


def extend_tails(levels, q, lo_mult=0.5, hi_mult=2.0):
    lo = np.maximum(q[0] - lo_mult * (q[1] - q[0]), 0.0)
    hi = q[-1] + hi_mult * (q[-1] - q[-2])
    return np.concatenate(([0.0], levels, [1.0])), np.vstack([lo, q, np.maximum(hi, q[-1])])


def ar1_paths(levels, q, n_paths, rho, rng):
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


# =============================================================================
# Main model
# =============================================================================

class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.history = None
        self._meter = _MeterPart(ctx)
        self._spend_cache: dict = {}

    def fit(self, history):
        self.history = history
        self._meter.fit(history)
        self._spend_cache = {}

    def update(self, events):
        self.history = self.history.extend(events)
        self._meter.update(events)
        self._spend_cache = {}

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target in WINDOW_OF:
                out[tr.key] = self._meter.forecast_one(request.now, tr)
            elif tr.target in (Target.SPEND_HOURLY, Target.TOKENS_HOURLY):
                out[tr.key] = self._hourly(request.now, tr)
            elif tr.target is Target.SPLIT:
                out[tr.key] = self._split(tr)
            elif tr.target is Target.CYCLE_NEXT_START:
                out[tr.key] = self._next_start(tr)
        return Forecast(out)

    def _hourly(self, now, tr):
        what = "spend" if tr.target is Target.SPEND_HOURLY else "tokens"
        ctx_key = "spend_context_hours" if what == "spend" else "tokens_context_hours"
        T = int(self.cfg.get(ctx_key, self.cfg.get("context_hours", 336)))
        ends, series = spend.hourly_series(self.history, tr.accounts, T, what, tr.family)
        tz_min = float(self.history.tz_offset_min or 0)
        profile = weekly_profile(series)
        key = (what, tuple(tr.accounts), tr.family)
        state = self._train_spend(key, series, ends, tz_min, profile)
        steps = np.maximum(1, np.round(
            (np.asarray(tr.grid, dtype=np.int64) - now) / HOUR_MS)).astype(int)
        n_grid = len(tr.grid)

        if state is None:
            return self._profile_fallback(series, ends, tz_min, profile, steps, n_grid, tr.n_paths)

        levels, boosters = state["levels"], state["boosters"]
        n = len(series)
        quantiles = np.zeros((len(levels), n_grid))
        for i, step in enumerate(steps):
            feat = spend_features(series, ends, tz_min, profile, int(step), n)[None, :]
            for j, b in enumerate(boosters):
                quantiles[j, i] = b.predict(feat)[0]

        quantiles = np.sort(np.maximum(quantiles, 0.0), axis=0)
        sm_key = "spend_spread_mult" if what == "spend" else "tokens_spread_mult"
        mult = float(self.cfg.get(sm_key, self.cfg.get("spread_mult", 1.8)))
        if mult != 1.0:
            med = quantiles[len(levels) // 2]
            for j in range(len(levels)):
                quantiles[j] = np.maximum(med + mult * (quantiles[j] - med), 0.0)
            quantiles = np.sort(quantiles, axis=0)
        cap_key = "spend_cap_factor" if what == "spend" else "tokens_cap_factor"
        cap = float(self.cfg.get(cap_key, self.cfg.get("cap_factor", 3.0)))
        if cap > 0 and len(series) > 0:
            quantiles = np.minimum(quantiles, cap * max(float(np.max(series)), 1.0))

        lo_m = float(self.cfg.get("tail_lo_mult", 0.5))
        hi_m = float(self.cfg.get("tail_hi_mult", 2.0))
        lv, q = extend_tails(levels, quantiles, lo_m, hi_m)
        paths = ar1_paths(lv, q, tr.n_paths, float(self.cfg.get("rho", 0.6)), self.rng)
        return TargetForecast(np.maximum(paths, 0.0))

    def _train_spend(self, key, series, ends, tz_min, profile):
        if key in self._spend_cache:
            return self._spend_cache[key]
        X, y = spend_training(series, ends, tz_min, profile,
                              int(self.cfg.get("train_hours", 3000)))
        if len(X) < 50:
            self._spend_cache[key] = None
            return None
        import lightgbm as lgb
        levels = np.asarray(self.cfg.get("spend_levels",
            [0.02, 0.05, 0.1, 0.2, 0.35, 0.5, 0.65, 0.8, 0.9, 0.95, 0.98]))
        kw = dict(
            n_estimators=int(self.cfg.get("spend_n_estimators", 120)),
            learning_rate=0.04, num_leaves=int(self.cfg.get("spend_num_leaves", 10)),
            min_child_samples=int(self.cfg.get("spend_min_child_samples", 25)),
            subsample=0.8, subsample_freq=1, colsample_bytree=0.8,
            reg_lambda=1.0, n_jobs=1, max_bin=63, verbose=-1,
        )
        boosters = [lgb.LGBMRegressor(objective="quantile", alpha=float(a), **kw).fit(X, y) for a in levels]
        result = {"levels": levels, "boosters": boosters}
        self._spend_cache[key] = result
        return result

    def _profile_fallback(self, series, ends, tz_min, profile, steps, n_grid, n_paths):
        n = len(series)
        weeks = max(1, n // WEEK_H)
        if n >= 2 * WEEK_H:
            used = series[-(weeks * WEEK_H):]
            week_paths = used.reshape(weeks, WEEK_H)
            tz_ms = int(round(tz_min * 60_000)) if math.isfinite(tz_min) else 0
            base_hour = (ends[-1] + tz_ms) // HOUR_MS if len(ends) > 0 else 0
            result = np.zeros((weeks, n_grid))
            for i, step in enumerate(steps):
                result[:, i] = week_paths[:, int((base_hour + step) % WEEK_H)]
            if weeks < n_paths:
                result = result[self.rng.integers(0, weeks, size=n_paths)]
            return TargetForecast(np.maximum(result[:n_paths], 0.0))
        return TargetForecast.point(np.full(n_grid, max(float(profile.mean()), 0.0)), n_paths)

    def _split(self, tr):
        from kit.baselines import split_recent
        return split_recent(self.history, tr, tuple(self.history.accounts))

    def _next_start(self, tr):
        from kit.baselines import next_start_never
        return next_start_never(self.history, tr)


# =============================================================================
# Meter sub-model
# =============================================================================

class _MeterPart(LearnedMeterModel):
    name = "g1-04-opus-all-meter"

    def _params(self, kind):
        weekly = kind != "five_hour"
        c = self.cfg
        if weekly:
            return dict(
                n_estimators=int(c.get("weekly_n_estimators", 120)),
                learning_rate=float(c.get("learning_rate", 0.04)),
                num_leaves=int(c.get("weekly_num_leaves", 5)),
                min_child_samples=int(c.get("weekly_min_child_samples", 10)),
                subsample=0.7, subsample_freq=1, colsample_bytree=0.6,
                reg_lambda=3.0, reg_alpha=0.5,
                n_jobs=1, max_bin=63, force_col_wise=True, verbose=-1,
                random_state=int(self.ctx.seed % (2 ** 31)),
            )
        return dict(
            n_estimators=int(c.get("n_estimators", 180)),
            learning_rate=float(c.get("learning_rate", 0.04)),
            num_leaves=int(c.get("num_leaves", 12)),
            min_child_samples=int(c.get("min_child_samples", 15)),
            subsample=0.8, subsample_freq=1, colsample_bytree=0.8,
            reg_lambda=1.5,
            n_jobs=1, max_bin=63, force_col_wise=True, verbose=-1,
            random_state=int(self.ctx.seed % (2 ** 31)),
        )

    def _fit_quantile(self, X, y, levels, kw):
        import lightgbm as lgb
        return [lgb.LGBMRegressor(objective="quantile", alpha=float(a), **kw).fit(X, y) for a in levels]

    def train(self, ts, kind):
        X, y, r = ts.stacked()
        kw = self._params(kind)
        levels = np.asarray(self.cfg.get("meter_levels",
            [0.03, 0.1, 0.25, 0.5, 0.75, 0.9, 0.97]), dtype=np.float64)

        prior = np.asarray(self.cfg.get("default_scale",
            [1.2, 1.2, 1.1, 1.0, 1.3, 1.7, 2.0]), dtype=np.float64)
        if len(prior) != len(levels):
            prior = np.ones(len(levels))
        n0 = float(self.cfg.get("prior_cycles", 10))
        scale = prior.copy()

        k = int(self.cfg.get("calibrate_folds", 3))
        n_cyc = int(ts.cycle.max()) + 1 if len(ts) else 0

        if k >= 2 and n_cyc >= 3 * k:
            first = np.array([ts.reset[ts.cycle == c].min() for c in range(n_cyc)])
            rank = np.empty(n_cyc, dtype=np.int64)
            rank[np.argsort(first, kind="stable")] = np.arange(n_cyc)
            fold = (rank * k // n_cyc)[ts.cycle[r]]
            oof = np.full((len(levels), len(y)), np.nan)
            for f in range(k):
                tr_m, te_m = fold != f, fold == f
                if tr_m.sum() < 50 or te_m.sum() == 0:
                    continue
                for j, b in enumerate(self._fit_quantile(X[tr_m], y[tr_m], levels, kw)):
                    oof[j, te_m] = b.predict(X[te_m])
            ok = np.isfinite(oof).all(axis=0)
            if ok.sum() >= 50:
                med = oof[list(levels).index(0.5), ok] if 0.5 in levels else np.median(oof[:, ok], axis=0)
                yy = y[ok]
                for j, a in enumerate(levels):
                    if a == 0.5:
                        continue
                    losses = [pinball(yy, med + s * (oof[j, ok] - med), a) for s in SCALES]
                    scale[j] = (n_cyc * SCALES[int(np.argmin(losses))] + n0 * prior[j]) / (n_cyc + n0)

        y_std = float(np.std(y)) if len(y) > 10 else 0.0
        self.ctx.log(f"{self.name} {kind}: {n_cyc} cyc, {len(X)} rows, y_std={y_std:.2f}, "
                     f"scale={' '.join(f'{a:.2g}:{s:.2f}' for a, s in zip(levels, scale))}")
        return {"levels": levels, "boosters": self._fit_quantile(X, y, levels, kw), "scale": scale,
                "y_std": y_std, "kind": kind}

    def predict(self, state, row, lead_X, fracs, grid_fracs, used, n_paths, rng):
        X = np.concatenate([np.repeat(row[None, :], len(fracs), axis=0), lead_X], axis=1)
        q = np.stack([b.predict(X) for b in state["boosters"]])
        lv = state["levels"]
        med_idx = list(lv).index(0.5) if 0.5 in lv else len(lv) // 2
        med = q[med_idx]
        q = med[None, :] + state["scale"][:, None] * (q - med[None, :])

        y_std = state.get("y_std", 0.0)
        kind = state.get("kind", "five_hour")
        if kind == "seven_day":
            min_spread_frac = float(self.cfg.get("min_spread_7d", 3.0))
        elif kind != "five_hour":
            min_spread_frac = float(self.cfg.get("min_spread_scoped", 1.0))
        else:
            min_spread_frac = 0.0
        if y_std > 0 and min_spread_frac > 0:
            for j in range(len(fracs)):
                f = max(fracs[j], 0.01)
                min_half = min_spread_frac * y_std * np.sqrt(f)
                for i, a in enumerate(lv):
                    if a < 0.5:
                        q[i, j] = min(q[i, j], med[j] - min_half * (0.5 - a) / 0.5)
                    elif a > 0.5:
                        q[i, j] = max(q[i, j], med[j] + min_half * (a - 0.5) / 0.5)

        return rise_paths(lv, q, fracs, grid_fracs, used, n_paths, rng)

    def forecast_one(self, now, tr):
        kind = WINDOW_OF.get(tr.target)
        if kind is None:
            return TargetForecast.point(np.full(len(tr.grid), 0.0))
        return self._meter(now, tr, kind)
