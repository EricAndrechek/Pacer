"""cycle.next_start: when does an idle five-hour window start again?

The window starts with the account's next turn. Take every past moment on a
fine grid whose local time of day is close to now's, whose weekday class is the
same and whose idle stretch so far (time since the last turn) is similar; the
time from each of them to the next turn is a sample of the wait. Draws of those
waits, beyond the horizon -> NaN ("no start before the horizon").

Self-calibration: behaviour drifts (an account goes quiet for weeks), so the
model backtests itself on idle moments of the last weeks of its own history and
shifts the odds of "no start before the horizon" by the log-odds offset that
scored best there (shrunk toward 0 when the evidence is thin).
"""
from __future__ import annotations

import numpy as np
import polars as pl

from arena.types import Forecast, Target, TargetForecast

HOUR = 3_600_000
DAY = 24 * HOUR


class Model:
    def __init__(self, ctx):
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.history = None
        self._cal = {}

    def fit(self, history):
        self.history = history
        self._cal = {}

    def update(self, events):
        self.history = self.history.extend(events)

    def _turn_times(self, accounts):
        t = self.history.table("turns")
        if accounts:
            t = t.filter(pl.col("account").is_in(list(accounts)))
        if not t.height:
            return np.zeros(0, np.int64)
        return np.sort(t["t_event"].dt.epoch("ms").to_numpy().astype(np.int64))

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target is Target.CYCLE_NEXT_START:
                out[tr.key] = self._one(request.now, tr)
        return Forecast(out)

    # ------------------------------------------------------------------
    def _candidates(self, te, now, horizon, tz):
        """(wait_ms, weight, beyond_horizon) over past moments, as seen from `now`."""
        cfg = self.cfg
        step = int(cfg.get("step_min", 10)) * 60_000
        sig_t = float(cfg.get("sigma_tod_h", 1.25))
        sig_i = float(cfg.get("sigma_idle", 1.2))
        wdw = cfg.get("w_dow", [1.0, 0.25, 0.03])
        hl = float(cfg.get("half_life_days", 45.0)) * DAY
        t0 = int(te[0])
        last_i = np.searchsorted(te, now, side="right") - 1
        idle_now = (now - int(te[last_i])) if last_i >= 0 else 0
        s = np.arange(t0 + DAY, now - 1, step, dtype=np.int64)
        s = s[s + horizon <= now]                       # waits fully observed
        if len(s) < 50:
            s = np.arange(t0 + HOUR, now - 1, step, dtype=np.int64)
            s = s[s + min(horizon, 6 * HOUR) <= now]
        if len(s) == 0:
            return None
        i_prev = np.searchsorted(te, s, side="right") - 1
        idle = np.where(i_prev >= 0, s - te[np.maximum(i_prev, 0)], 0)
        i_next = np.searchsorted(te, s, side="right")
        wait = np.where(i_next < len(te), te[np.minimum(i_next, len(te) - 1)] - s, 10 * horizon).astype(np.float64)
        local = lambda t: ((t + tz) % DAY) / HOUR
        dtod = (local(s) - local(np.array([now]))[0] + 12) % 24 - 12
        wd = lambda t: (((t + tz) // DAY) + 3) % 7
        d = np.abs(wd(s) - wd(np.array([now]))[0])
        d = np.minimum(d, 7 - d)
        same_class = (wd(s) < 5) == (wd(np.array([now]))[0] < 5)
        w_d = np.where(d == 0, wdw[0], np.where(same_class, wdw[1], wdw[2]))
        w_i = np.exp(-0.5 * ((np.log1p(idle / HOUR) - np.log1p(idle_now / HOUR)) / sig_i) ** 2)
        w = np.exp(-0.5 * (dtod / sig_t) ** 2) * w_i * w_d * 0.5 ** ((now - s) / hl)
        if w.sum() <= 1e-12:
            w = np.ones_like(w)
        return wait, w / w.sum(), wait > horizon

    @staticmethod
    def _crps(values, weights, y):
        o = np.argsort(values)
        v, w = values[o], weights[o]
        F = np.cumsum(w)
        e_xy = float((w * np.abs(v - y)).sum())
        e_xx = 2.0 * float((w * v * (2 * F - w - 1.0)).sum())       # E|X - X'|
        return e_xy - 0.5 * e_xx

    def _calibrate(self, te, now, horizon, tz):
        """Log-odds offset of the "none before horizon" mass, from backtests on the last weeks."""
        cfg = self.cfg
        key = (int(now // (6 * HOUR)), len(te))
        if key in self._cal:
            return self._cal[key]
        b = 0.0
        look = float(cfg.get("calib_days", 28.0)) * DAY
        n_cases = int(cfg.get("calib_cases", 60))
        if len(te) > 200 and float(cfg.get("calib_shrink", 0.7)) > 0:
            lo = max(int(te[0]) + 3 * DAY, now - int(look))
            hi = now - horizon - HOUR
            if hi > lo:
                rng = np.random.default_rng(int(now // HOUR) % (2 ** 31))
                ms_ = np.sort(rng.integers(lo, hi, size=n_cases * 6))
                cases = []
                for m in ms_:
                    j = np.searchsorted(te, m, side="right") - 1
                    if j < 0 or m - te[j] < int(5.5 * HOUR):
                        continue
                    nxt = te[j + 1] if j + 1 < len(te) else None
                    actual = horizon if (nxt is None or nxt - m > horizon) else (nxt - m)
                    cases.append((int(m), actual / HOUR))
                    if len(cases) >= n_cases:
                        break
                grid = np.array([-1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0, 3.0])
                if len(cases) >= 12:
                    score = np.zeros(len(grid))
                    used = 0
                    for m, y in cases:
                        cd = self._candidates(te, m, horizon, tz)
                        if cd is None:
                            continue
                        wait, w, none = cd
                        v = np.minimum(wait, horizon) / HOUR
                        for gi, g in enumerate(grid):
                            ww = w * np.where(none, np.exp(g), 1.0)
                            ww = ww / ww.sum()
                            score[gi] += self._crps(v, ww, y)
                        used += 1
                    if used >= 12:
                        k = int(np.argmin(score))
                        gain = (score[2] - score[k]) / max(score[2], 1e-9)       # vs no shift
                        if gain > 0.02:
                            b = float(grid[k]) * float(cfg.get("calib_shrink", 0.7))
        self._cal[key] = b
        return b

    def _one(self, now, tr):
        cfg = self.cfg
        horizon = int(tr.grid[-1]) - now
        te = self._turn_times(tr.accounts)
        n = tr.n_paths
        if len(te) < 20:
            return TargetForecast(np.full((n, 1), np.nan))
        tz = (self.history.tz_offset_min or 0) * 60_000
        cd = self._candidates(te, now, horizon, tz)
        if cd is None:
            return TargetForecast(np.full((n, 1), np.nan))
        wait, w, none = cd
        b = self._calibrate(te, now, horizon, tz)
        if b != 0.0:
            w = w * np.where(none, np.exp(b), 1.0)
            w = w / w.sum()
        idx = self.rng.choice(len(wait), size=n, p=w)
        W = wait[idx]
        res = np.where(W <= horizon, now + W, np.nan)
        return TargetForecast(res[:, None])
