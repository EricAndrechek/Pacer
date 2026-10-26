"""A pretrained forecaster as an hourly spend and tokens model
(`models/fm-*-spend`).

For each `spend.hourly` or `tokens.hourly` target (any group of accounts; a
token target may name one model family):

1. the group's hourly series over the last `context_hours`, aligned to `now`
   (`kit.fm.series.TurnFrame`: spend priced at the rates known at now);
2. optional covariates, for backends that take them (`covariates`):
   - `calendar` (known over the horizon): hour of day and day of week, as
     sin/cos in the user's local time;
   - `meter` (past only): the 5-hour and 7-day meters at each hour's end
     (the highest of the group's accounts);
   - `sessions` (past only): distinct sessions with a turn in the hour;
   - `prompts` (past only): prompts in the hour, in the group's sessions;
3. optional extra variates forecast jointly with the target
   (`multivariate`): `accounts` adds each visible account's own series of
   the same kind, `families` adds each model family's;
4. the forecaster's quantiles to the horizon, clipped at 0 and at
   `cap_factor` times the context's largest hour, tails extended,
   turned into paths by a Gaussian copula with AR(1) correlation `rho` per
   hour (hourly spend is autocorrelated, not comonotone).

A `spend.hourly` target that names a `family` (the structural models ask for
these) is that family's spend alone.

`model.toml` `[config]`:

    backend, weights, threads              # as for kit.fm.meter_model
    context_hours = 336
    covariates = ["calendar", "meter", "sessions", "prompts"]
    multivariate = "none"                  # or "accounts", "families"
    max_variates = 5
    rho = 0.8
    transform = "none"                     # or "log1p"
    cap_factor = 1.5                       # quantiles at most 1.5x the context's largest hour (0: no cap)
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from kit.fm.backends import get_backend
from kit.fm.paths import extend_tails, fix_crossing, to_paths
from kit.fm.series import HOUR_MS, PriceCache, TurnFrame, calendar, meter_level_hourly, prompts_per_hour

HOURLY = (Target.SPEND_HOURLY, Target.TOKENS_HOURLY)


class SpendModel:
    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.history = None
        self._backend = None
        self._prices = PriceCache()

    @property
    def backend(self):
        if self._backend is None:
            self._backend = get_backend(self.cfg["backend"], self.cfg["weights"], int(self.cfg.get("threads", 4)))
        return self._backend

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    # ------------------------------------------------------------------
    def forecast(self, request):
        jobs = [tr for tr in request.targets if tr.target in HOURLY]
        if not jobs:
            return Forecast({})
        now = int(request.now)
        T = int(self.cfg.get("context_hours", 336))
        mode = self.cfg.get("multivariate", "none") if self.backend.multivariate else "none"
        accounts = None if mode == "accounts" else sorted({a for tr in jobs for a in tr.accounts})
        tf = TurnFrame(self.history, T, accounts, self._prices)
        steps = {tr.key: self._steps(now, tr) for tr in jobs}
        H = max(int(s.max()) for s in steps.values())
        cov_names = list(self.cfg.get("covariates", [])) if self.backend.covariates else []
        out = {}
        memo: dict = {}
        if mode == "none":
            raw = np.stack([self._target(tf, tr)[None, :] for tr in jobs])                 # [B, 1, T]
            past, known = self._covariates(tf, jobs, now, T, H, cov_names, memo)
            levels, q = self.backend.quantiles(self._fwd(raw), H, past, known)
            for b, tr in enumerate(jobs):
                out[tr.key] = self._paths(levels, self._inv(q[b, 0]), steps[tr.key], tr, raw[b, 0])
        else:
            for tr in jobs:
                raw = self._variates(tf, tr, mode)[None]                                     # [1, V, T]
                past, known = self._covariates(tf, [tr], now, T, H, cov_names, memo)
                levels, q = self.backend.quantiles(self._fwd(raw), H, past, known)
                out[tr.key] = self._paths(levels, self._inv(q[0, 0]), steps[tr.key], tr, raw[0, 0])
        return Forecast(out)

    # Hourly spend is intermittent: a quantile head reads a few spikes among
    # hundreds of idle hours as a fat top tail (a q99 of $50 an hour on a
    # series that never made $20), and the paths' mean follows the tail.
    # Every quantile is capped at `cap_factor` times the context's largest
    # hour. `transform = "log1p"` (the forecaster sees log1p(y); quantiles map
    # back exactly, being order-preserving) was worse on the visible tier of
    # both snapshots, and explodes without the cap: off by default.
    def _fwd(self, y):
        return np.log1p(np.maximum(y, 0.0)) if self.cfg.get("transform", "none") == "log1p" else y

    def _inv(self, q):
        return np.expm1(np.minimum(q, 700.0)) if self.cfg.get("transform", "none") == "log1p" else q

    # ------------------------------------------------------------------
    @staticmethod
    def _steps(now: int, tr) -> np.ndarray:
        """Grid times as hours after now (whole hours on the arena's grid)."""
        return np.maximum(1, np.round((np.asarray(tr.grid, dtype=np.int64) - now) / HOUR_MS)).astype(int)

    @staticmethod
    def _what(tr) -> str:
        return "spend" if tr.target is Target.SPEND_HOURLY else "tokens"

    def _target(self, tf: TurnFrame, tr) -> np.ndarray:
        return tf.hourly(tr.accounts, self._what(tr), tr.family)

    def _variates(self, tf: TurnFrame, tr, mode: str) -> np.ndarray:
        """[V, T]: the target first, then companions of the same kind."""
        what = self._what(tr)
        rows = [tf.hourly(tr.accounts, what, tr.family)]
        cap = int(self.cfg.get("max_variates", 5))
        if mode == "accounts":
            accts = sorted(set(self.history.accounts) | set(tr.accounts))
            if len(tr.accounts) > 1 or accts != list(tr.accounts):
                for a in accts:
                    if len(rows) >= cap:
                        break
                    rows.append(tf.hourly((a,), what, tr.family))
        elif mode == "families":
            for fam in tf.families(tr.accounts):
                if len(rows) >= cap:
                    break
                if fam != tr.family:
                    rows.append(tf.hourly(tr.accounts, what, fam))
        return np.stack(rows)

    def _covariates(self, tf: TurnFrame, jobs, now: int, T: int, H: int, names, memo: dict | None = None):
        if not names:
            return None, None
        past_rows, known = [], None
        if "calendar" in names:
            ends = now + HOUR_MS * np.arange(-(T - 1), H + 1, dtype=np.int64)
            cal = calendar(ends, tf.tz_offset_min)                                           # [4, T + H]
            known = np.repeat(cal[None], len(jobs), axis=0)
        by_group: dict[tuple, np.ndarray] = {} if memo is None else memo   # a request's targets share a group
        for tr in jobs:
            g = tuple(tr.accounts)
            if g not in by_group:
                rows = []
                if "meter" in names:
                    for wk in ("five_hour", "seven_day"):
                        rows.append(meter_level_hourly(self.history, g, wk, now, T))
                if "sessions" in names:
                    rows.append(tf.sessions_per_hour(g, T))
                if "prompts" in names:
                    rows.append(prompts_per_hour(self.history, tf.session_set(g), now, T))
                by_group[g] = np.stack(rows) if rows else np.zeros((0, T))
            past_rows.append(by_group[g])
        past = np.stack(past_rows) if past_rows and past_rows[0].shape[0] else None
        return past, known

    def _paths(self, levels, q, steps: np.ndarray, tr, context=None) -> TargetForecast:
        q = fix_crossing(np.maximum(q[steps - 1], 0.0))                                      # [len(grid), Q]
        lv, q = extend_tails(levels, q)
        q = np.maximum(q, 0.0)
        cap = float(self.cfg.get("cap_factor", 1.5))
        if cap > 0 and context is not None and np.isfinite(context).any():
            q = np.minimum(q, cap * float(np.nanmax(context)))
        paths = to_paths(lv, q, tr.n_paths, "ar1", rho=float(self.cfg.get("rho", 0.8)), rng=self.rng)
        return TargetForecast(np.maximum(paths, 0.0))
