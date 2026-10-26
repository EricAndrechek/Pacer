"""Analog block-bootstrap for spend.hourly and tokens.hourly (see hourly.py)."""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from hourly import HourlyAnalog, LedgerStore, attach_level, forecast_paths


class Model:
    def __init__(self, ctx):
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.history = None
        self.store = LedgerStore()
        self._lvl_cache = {}
        self._scale_cache = {}

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    @staticmethod
    def _ens_crps(x, y):
        xs = np.sort(x, axis=0)
        M_ = xs.shape[0]
        e_xy = np.abs(xs - y[None, :]).mean(axis=0)
        w = (2.0 * np.arange(1, M_ + 1) - M_ - 1.0)[:, None]
        return float((e_xy - 0.5 * 2.0 * (w * xs).sum(axis=0) / (M_ * M_)).mean())

    def _scale(self, tr, what, fam, now):
        """Multiplier for the analog paths from backtests of the last two weeks of this very series:
        if the pasts have been under- (over-) forecasting recent hours, stretch (shrink) them."""
        ck = (tuple(tr.accounts), what, fam, int(now // (6 * 3600_000)))
        if ck in self._scale_cache:
            return self._scale_cache[ck]
        m_star = 1.0
        try:
            shrink = float(self.cfg.get("calib_shrink", 0.7))
            K = int(self.cfg.get("calib_cases", 14))
            if shrink > 0 and K > 0:
                rng = np.random.default_rng(int(now // 3600_000) % (2 ** 31))
                hi = now - 24 * 3600_000 - 1800_000
                lo = now - int(float(self.cfg.get("calib_days", 14)) * 86400_000)
                cfg = dict(self.cfg)
                if hi > lo:
                    grid_m = np.array([0.7, 0.85, 1.0, 1.2, 1.4])
                    tot = np.zeros(len(grid_m))
                    used = 0
                    ledgers = self.store.get(self.history, tr.accounts)
                    for c in rng.integers(lo, hi, size=K):
                        src = HourlyAnalog(self.history, tr.accounts, what, fam, cfg, self.rng, ledgers=ledgers)
                        src.now = int(c)
                        if src.now - src.t0 < 3 * 86400_000:
                            continue
                        attach_level(src, self.history, tr.accounts, cfg, self._lvl_cache)
                        grid = int(c) + 3600_000 * np.arange(1, 25, dtype=np.int64)
                        truth = src.vals(grid - 3600_000, grid)
                        p = np.maximum(forecast_paths(src, grid, 80, cfg), 0.0)
                        for gi, g in enumerate(grid_m):
                            tot[gi] += self._ens_crps(p * g, truth)
                        used += 1
                    if used >= 8:
                        k = int(np.argmin(tot))
                        gain = (tot[2] - tot[k]) / max(tot[2], 1e-12)
                        if gain > float(self.cfg.get("calib_gain", 0.02)):
                            m_star = 1.0 + shrink * (float(grid_m[k]) - 1.0)
        except Exception:
            m_star = 1.0
        self._scale_cache[ck] = m_star
        return m_star

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target not in (Target.SPEND_HOURLY, Target.TOKENS_HOURLY):
                continue
            what = "spend" if tr.target is Target.SPEND_HOURLY else "tokens"
            fam = tr.family if tr.target is Target.TOKENS_HOURLY or tr.family else None
            src = HourlyAnalog(self.history, tr.accounts, what, fam, self.cfg, self.rng,
                               ledgers=self.store.get(self.history, tr.accounts))
            attach_level(src, self.history, tr.accounts, self.cfg, self._lvl_cache)
            paths = forecast_paths(src, tr.grid, tr.n_paths, self.cfg)
            paths = paths * self._scale(tr, what, fam, int(self.history.now))
            out[tr.key] = TargetForecast(np.maximum(paths, 0.0))
        return Forecast(out)
