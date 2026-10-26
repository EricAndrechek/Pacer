"""Analog bootstrap of a meter's own point increments.

A meter is the running total of usage inside its window, so what it does next
is (a) where it is now plus (b) what usage adds before the reset. (b) is
modelled with the meter's own past: C(t), the cumulative points earned over
the whole history (resets cancelled: a new cycle's first reading counts what
it shows, later ones count only rises). For a forecast, pick historical
moments whose local time of day, weekday and recent pace look like now's and
copy what C did after them, scaled by the ratio of recent levels. Short
horizons (five-hour windows) are one block; weekly ones chain 24 h blocks
(see hourly.forecast_paths).
"""
from __future__ import annotations

import numpy as np

from kit import spend as S
import hourly as H
from levelfeat import MeterLevel

HOUR = 3_600_000
DAY = 24 * HOUR
MIN = 60_000


class PointSeries:
    """C(t): cumulative meter points; a step function over the readings."""

    def __init__(self, history, account, kind, cap, dur):
        r = S.meter_series(history, account, kind, cap)
        t, p, reset, act = r["t"], r["p"], r["reset"], r["active"]
        n = len(t)
        self.t = t
        if n == 0:
            self.cum = np.zeros(0)
            return
        d = np.zeros(n)
        same = np.zeros(n, dtype=bool)
        same[1:] = act[1:] & act[:-1] & (np.abs(reset[1:] - reset[:-1]) < dur / 2)
        d = np.zeros(n)
        run = p[0] if n else 0.0                     # running high of the current cycle
        for i in range(1, n):
            if same[i]:
                if p[i] > run:
                    d[i] = p[i] - run
                    run = p[i]
            else:
                run = p[i] if act[i] else 0.0
                d[i] = p[i] if act[i] else 0.0
        self.cum = np.cumsum(d)

    def __call__(self, t):
        t = np.asarray(t, dtype=np.int64)
        if len(self.t) == 0:
            return np.zeros(t.shape)
        i = np.searchsorted(self.t, t, side="right") - 1
        return np.where(i >= 0, self.cum[np.maximum(i, 0)], 0.0)

    @property
    def t0(self):
        return int(self.t[0]) if len(self.t) else None


class _Src:
    """The slice of HourlyAnalog's interface the chained engine needs."""

    def __init__(self, C, now, tz, rng):
        self.C, self.now, self.rng = C, int(now), rng
        self.t0 = C.t0 if C.t0 is not None else int(now)
        self.tz = tz

    def vals(self, t0, t1):
        return self.C(t1) - self.C(t0)

    def hourly(self, ends, n):
        ends = np.asarray(ends, dtype=np.int64)
        e = ends[:, None] - HOUR * np.arange(n - 1, -1, -1, dtype=np.int64)[None, :]
        return self.vals((e - HOUR).ravel(), e.ravel()).reshape(e.shape)

    def weekday(self, t):
        return (((np.asarray(t, dtype=np.int64) + self.tz) // DAY) + 3) % 7

    def tod_h(self, t):
        return ((np.asarray(t, dtype=np.int64) + self.tz) % DAY) / HOUR


def _feat(C, s, s_idle):
    """Log-able pace features at moments s: points over the last 10 min,
    30 min, 2 h, 12 h and hours since the last increment (capped)."""
    f = [C(s) - C(s - 10 * MIN), C(s) - C(s - 30 * MIN), C(s) - C(s - 2 * HOUR), C(s) - C(s - 12 * HOUR)]
    return np.stack(f + [s_idle], axis=1)


def _idle_hours(C, s, cap_h=6.0):
    """Hours since the series last moved before s (capped)."""
    if len(C.t) == 0:
        return np.full(np.shape(s), cap_h)
    d = np.concatenate([[0.0], np.diff(C.cum)])
    mv = np.flatnonzero(d > 0)
    if len(mv) == 0:
        return np.full(np.shape(s), cap_h)
    tm = C.t[mv]
    j = np.searchsorted(tm, s, side="right") - 1
    last = np.where(j >= 0, tm[np.maximum(j, 0)], -(1 << 60))
    return np.minimum((np.asarray(s) - last) / HOUR, cap_h)


def short_paths(C, now, t_anchor, grid, n_paths, tz, cfg, rng, lvl=None, y_now=None, reset=None, lvl7=None):
    """One-block analog increments over (t_anchor, grid]: [P, K] points."""
    cfg = dict(cfg)
    grid = np.asarray(grid, dtype=np.int64)
    off = grid - t_anchor                                   # ms after the anchor
    H_eff = int(off.max())
    step = int(cfg.get("short_step_min", 5)) * MIN
    sig_t = float(cfg.get("sigma_tod_h", 2.0))
    half_life = float(cfg.get("half_life_days", 60.0)) * DAY
    wdw = cfg.get("w_dow", [1.0, 0.6, 0.3])
    gamma = float(cfg.get("level_gamma", 0.5))
    ess_min = float(cfg.get("ess_min", 30))
    sig = np.array(cfg.get("sigma_state", [1.0, 1.0, 1.0, 1.2, 1.5]), dtype=np.float64)
    t0 = C.t0
    if t0 is None:
        return np.zeros((n_paths, len(grid)))
    latest = now - MIN - H_eff
    s = np.arange(t0 + 12 * HOUR, latest + 1, step, dtype=np.int64)
    if len(s) < 50:
        s = np.arange(t0 + HOUR, latest + 1, step, dtype=np.int64)
    if len(s) < 20:
        return None
    tod = lambda t: ((np.asarray(t, dtype=np.int64) + tz) % DAY) / HOUR
    wd = lambda t: (((np.asarray(t, dtype=np.int64) + tz) // DAY) + 3) % 7
    dtod = (tod(s) - tod(np.array([t_anchor]))[0] + 12) % 24 - 12
    d = np.abs(wd(s) - wd(np.array([t_anchor]))[0])
    d = np.minimum(d, 7 - d)
    same_class = (wd(s) < 5) == (wd(np.array([t_anchor]))[0] < 5)
    w_dow = np.where(d == 0, wdw[0], np.where(same_class, wdw[1], wdw[2]))
    a_static = (-0.5 * (dtod / sig_t) ** 2 + np.log(w_dow)
                - np.maximum(now - s, 0) / half_life * np.log(2.0))
    fs = np.log1p(_feat(C, s, _idle_hours(C, s)))
    fn = np.log1p(_feat(C, np.array([t_anchor]), _idle_hours(C, np.array([t_anchor]))))
    a_state = -0.5 * (((fs - fn) / sig[None, :]) ** 2).sum(axis=1)
    sl, st = float(cfg.get("sigma_level", 0.0)), float(cfg.get("sigma_ttr", 0.0))
    if lvl is not None and y_now is not None and (sl > 0 or st > 0):
        ls, ttrs = lvl.at(s)
        ok = np.isfinite(ls)
        if sl > 0:
            a_state = a_state - 0.5 * np.where(ok, ((ls - y_now) / sl) ** 2, 1.0)
        if st > 0 and reset is not None:
            okt = np.isfinite(ttrs)
            d = (np.log1p(np.where(okt, ttrs, 0.0) / HOUR) - np.log1p(max(reset - t_anchor, 0) / HOUR)) / st
            a_state = a_state - 0.5 * np.where(okt, d ** 2, 4.0)
    s7 = float(cfg.get("sigma_u7", 0.0))
    if lvl7 is not None and lvl7.ok and s7 > 0:
        # the weekly cap throttles everything: match the weekly meter's fullness (and the time it still has to run)
        l7n, t7n = lvl7.at(np.array([t_anchor]))
        if np.isfinite(l7n[0]):
            l7s, t7s = lvl7.at(s)
            a_state = a_state - 0.5 * np.where(np.isfinite(l7s), ((l7s - l7n[0]) / s7) ** 2, 1.0)
            st7 = float(cfg.get("sigma_u7_ttr", 0.0))
            if st7 > 0 and np.isfinite(t7n[0]):
                ok7 = np.isfinite(t7s)
                d7 = (np.log1p(np.where(ok7, t7s, 0.0) / HOUR) - np.log1p(t7n[0] / HOUR)) / st7
                a_state = a_state - 0.5 * np.where(ok7, d7 ** 2, 2.0)
    lam = float(H._temper(a_state[None, :], a_static[None, :], ess_min)[0])
    lw = lam * a_state + a_static
    w = np.exp(lw - lw.max())
    w /= w.sum()
    idx = rng.choice(len(s), size=n_paths, p=w)
    ss = s[idx]
    inc = C(ss[:, None] + off[None, :]) - C(ss)[:, None]       # [P, K]
    # recent-level ratio (last 7 days of points per hour): now vs at the analog
    rho = _level_ratio(C, t0, np.array([t_anchor]), ss, gamma, cfg)
    inc = inc * rho[:, None]
    gs = float(cfg.get("rate_gamma", 0.0))
    if gs > 0:
        span = int(float(cfg.get("rate_span_min", 30)) * MIN)
        pn = (C(np.array([t_anchor])) - C(np.array([t_anchor - span])))[0] / (span / HOUR)
        ps = (C(ss) - C(ss - span)) / (span / HOUR)
        kk = float(cfg.get("rate_prior", 1.0))
        inc = inc * np.clip(((pn + kk) / (ps + kk)) ** gs, float(cfg.get("rate_lo", 0.25)), float(cfg.get("rate_hi", 4.0)))[:, None]
    pi0 = float(cfg.get("pi_zero", 0.0))
    if pi0 > 0:
        z = rng.random(n_paths) < pi0
        inc[z] = 0.0
    return inc


def _pace(C, t0, t, span=7 * DAY):
    """Points per hour over the last `span`, over what history there is
    (returns pace, hours of history used)."""
    t = np.asarray(t, dtype=np.int64)
    lo = np.maximum(t - span, t0)
    hrs = np.maximum((t - lo) / HOUR, 1e-9)
    return (C(t) - C(lo)) / hrs, hrs


def _level_ratio(C, t0, t_now, t_s, gamma, cfg):
    """Ratio of the recent pace now to the pace at each analog start, shrunk
    toward 1 when either has under a day of history behind it."""
    pn, hn = _pace(C, t0, t_now)
    ps, hs = _pace(C, t0, t_s)
    k = float(cfg.get("pace_prior_pts_per_h", 0.3))
    full = 24.0
    wn = np.minimum(hn / full, 1.0)
    ws = np.minimum(hs / full, 1.0)
    w = (wn * ws)
    lo, hi = float(cfg.get("rho_min", 0.4)), float(cfg.get("rho_max", 2.5))
    r = ((pn + k) / (ps + k)) ** gamma
    r = np.where(np.isfinite(r), r, 1.0)
    return np.clip(w * r + (1 - w), lo, hi)


def long_paths(C, now, tz, grid, n_paths, cfg, rng, lvl=None):
    """Chained 24 h-block analogs, hourly resolution -> [P, K] points at the grid.
    `lvl` (a MeterLevel of the same meter) adds the cycle's own level and time to
    reset as analog features: what is left to earn depends on how full the meter is."""
    src = _Src(C, now, tz, rng)
    if lvl is not None and lvl.ok:
        src.level, src.k_level = lvl, 1.0
    n_h = int(np.ceil((int(grid[-1]) - now) / HOUR))
    inc_h = H.forecast_paths(src, now + HOUR * np.arange(1, n_h + 1, dtype=np.int64), n_paths, cfg)
    cum = np.concatenate([np.zeros((n_paths, 1)), np.cumsum(inc_h, axis=1)], axis=1)   # at now + k h, k = 0..n_h
    x = (np.asarray(grid, dtype=np.float64) - now) / HOUR
    k = np.clip(np.floor(x).astype(int), 0, n_h - 1)
    frac = np.clip(x - k, 0.0, 1.0)
    return cum[:, k] * (1 - frac) + cum[:, k + 1] * frac
