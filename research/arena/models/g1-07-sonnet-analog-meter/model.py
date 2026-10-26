"""Meters by analog bootstrap of the meter's own point increments (meter.py)."""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from kit import baselines as B
from arena.snapshot.cycles import window_ms

import meter as M
from kit import spend as S
from levelfeat import MeterLevel

WINDOW_OF = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}


class Model:
    def __init__(self, ctx):
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.history = None
        self._cache = {}
        self._scale_cache = {}
        self._rate_cache = {}

    def fit(self, history):
        self.history = history
        self._cache = {}
        self._scale_cache = {}
        self._rate_cache = {}

    def update(self, events):
        self.history = self.history.extend(events)
        self._cache = {}

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target in WINDOW_OF:
                out[tr.key] = self._meter(request.now, tr)
        return Forecast(out)

    # ------------------------------------------------------------------
    @staticmethod
    def _ens_crps(x, y):
        """CRPS of an ensemble x [M, T] against y [T], mean over T (fair estimator not needed here)."""
        xs = np.sort(x, axis=0)
        M_ = xs.shape[0]
        e_xy = np.abs(xs - y[None, :]).mean(axis=0)
        w = (2.0 * np.arange(1, M_ + 1) - M_ - 1.0)[:, None]
        e_xx = 2.0 * (w * xs).sum(axis=0) / (M_ * M_)
        return float((e_xy - 0.5 * e_xx).mean())

    def _scale(self, acct, kind, cap, now, C, tz, cfg_k, long_):
        """Multiplier for the analog increments from backtests on the last weeks of this meter's own history.

        The regime drifts (users cap out, go quiet); if the analog pasts have been over-forecasting what the
        meter then actually did, shrink them, and stretch them in the opposite case. Shrunk toward 1."""
        ck = (acct, kind, cap, int(now // (6 * 3600_000)))
        if ck in self._scale_cache:
            return self._scale_cache[ck]
        m_star = 1.0
        try:
            look_d = float(self.cfg.get("calib_days_long" if long_ else "calib_days", 28 if long_ else 14))
            K = int(self.cfg.get("calib_cases_long" if long_ else "calib_cases", 8 if long_ else 30))
            shrink = float(self.cfg.get("calib_shrink_long", 0.0) if long_ else self.cfg.get("calib_shrink", 0.7))
            if shrink > 0:
                cycles = [c for c in S.past_cycles(self.history, acct, kind, cap)
                          if c.reset <= now - 3600_000 and c.reset >= now - look_d * 86400_000 and len(c.t) >= 8]
                if cycles:
                    rng = np.random.default_rng(int(now // 3600_000) % (2 ** 31))
                    grid_m = np.array([0.0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5])
                    tot = np.zeros(len(grid_m))
                    used = 0
                    for _ in range(K):
                        c = cycles[int(rng.integers(0, len(cycles)))]
                        i = int(rng.integers(0, len(c.t) - 3))
                        t_i = int(c.t[i]); now_b = t_i + 1000; y0 = float(c.util[i])
                        if c.reset - now_b < 10 * 60_000:
                            continue
                        if kind == "five_hour":
                            grid = np.concatenate([now_b + np.array([60_000, 180_000]), np.arange(now_b + 300_000, c.reset, 300_000), [c.reset]]).astype(np.int64)
                            inc = M.short_paths(C, now_b, t_i, grid, 100, tz, cfg_k, rng)
                        else:
                            grid = np.concatenate([now_b + np.array([300_000]), np.arange(now_b + 1_800_000, c.reset, 3_600_000), [c.reset]]).astype(np.int64)
                            inc = M.long_paths(C, now_b, tz, grid, 60, cfg_k, rng)
                        if inc is None:
                            continue
                        m_ = c.t > now_b
                        if not m_.any():
                            continue
                        tt, uu = c.t[m_], c.util[m_]
                        for gi, g in enumerate(grid_m):
                            p = np.clip(y0 + np.maximum(inc * g, 0.0), y0, 100.0)
                            at = np.stack([np.interp(tt, grid, row) for row in p])
                            tot[gi] += self._ens_crps(at, uu)
                        used += 1
                    if used >= (5 if long_ else 12):
                        k = int(np.argmin(tot))
                        k1 = int(np.where(grid_m == 1.0)[0][0])
                        gain = (tot[k1] - tot[k]) / max(tot[k1], 1e-9)
                        if gain > float(self.cfg.get("calib_gain", 0.03)):
                            m_star = 1.0 + shrink * (float(grid_m[k]) - 1.0)
        except Exception:
            m_star = 1.0
        self._scale_cache[ck] = m_star
        return m_star

    def _live_added(self, acct, kind, cap, now, t_last):
        """Meter points implied by the spend since the latest reading (the app's live meter): the fitted
        points-per-dollar of each model family times what each spent after the reading."""
        try:
            ck = (acct, kind, cap, int(now // (6 * 3600_000)))
            if ck not in self._rate_cache:
                d = S.fit_details(self.history, acct, kind, cap)
                self._rate_cache[ck] = None if d is None else np.asarray(d.rates, dtype=np.float64)
            rates = self._rate_cache[ck]
            if rates is None:
                return 0.0
            sp = S.spent_between(self.history, acct, np.array([t_last]), np.array([now]))[0]
            return float(min(max(np.dot(rates, sp), 0.0), 50.0))
        except Exception:
            return 0.0

    def _meter(self, now, tr):
        kind = WINDOW_OF[tr.target]
        cap = tr.cap if tr.target is Target.METER_SCOPED else None
        acct = tr.accounts[0]
        mn = B.meter_now(self.history, tr)
        y0, t_last = mn.latest, mn.latest_t
        t_anchor = min(t_last, now)
        added = self._live_added(acct, kind, cap, now, t_last) if (now - t_last) > 20_000 else 0.0
        if added > 0:
            y0 = min(100.0, y0 + added)           # the reading plus what was spent since it
            t_anchor = now
        dur = window_ms(kind)
        key = (acct, kind, cap)
        if key not in self._cache:
            self._cache[key] = M.PointSeries(self.history, acct, kind, cap, dur)
        C = self._cache[key]
        tz = (self.history.tz_offset_min or 0) * 60_000
        grid = np.asarray(tr.grid, dtype=np.int64)
        P = tr.n_paths
        cfg = self.cfg
        if kind == "five_hour":
            lv = MeterLevel(self.history, (acct,), 'five_hour', None, max_age_h=2.0)
            inc = M.short_paths(C, now, t_anchor, grid, P, tz, cfg.get("five", cfg), self.rng,
                                lvl=lv, y_now=y0, reset=int(tr.reset_at) if tr.reset_at is not None else mn.reset,
                                lvl7=MeterLevel(self.history, (acct,), 'seven_day', None, max_age_h=36.0))
        else:
            lv = MeterLevel(self.history, (acct,), kind, cap, max_age_h=36.0)
            inc = M.long_paths(C, now, tz, grid, P, cfg.get("long", cfg), self.rng, lvl=lv)
        if inc is None:
            inc = np.zeros((P, len(grid)))
        else:
            cfg_k = cfg.get("five", cfg) if kind == "five_hour" else cfg.get("long", cfg)
            inc = inc * self._scale(acct, kind, cap, now, C, tz, cfg_k, kind != "five_hour")
        paths = np.clip(y0 + np.maximum(inc, 0.0), y0, 100.0)
        paths = np.maximum.accumulate(paths, axis=1)
        return TargetForecast(paths)
