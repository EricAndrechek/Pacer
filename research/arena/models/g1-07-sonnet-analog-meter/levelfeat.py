"""Meter level as an analog feature.

Usage is shaped by the caps: spend collapses when the weekly meter is nearly
full (here 18 % of hours active at 90-99 %, 5 % at 100 %, against 45-60 %
below 90 %) and resumes after the reset. `MeterLevel` reads a meter's
utilisation (and time to its reset) at any past moment, averaged over a
group's accounts; `rate` converts a group's usage in its own unit (USD,
tokens, points) into points of that meter so a simulated path can carry the
level forward.
"""
from __future__ import annotations

import numpy as np

from arena.snapshot.cycles import window_ms
from kit import spend as S

HOUR = 3_600_000
DAY = 24 * HOUR


class MeterLevel:
    def __init__(self, history, accounts, kind="seven_day", scope_model=None, max_age_h=36.0):
        self.dur = window_ms(kind)
        self.max_age = int(max_age_h * HOUR)
        self.series = []
        for a in accounts:
            r = S.meter_series(history, a, kind, scope_model)
            if len(r["t"]):
                self.series.append(r)
        self.ok = len(self.series) > 0

    def at(self, t):
        """(level, ttr_ms): mean utilisation over accounts at times t (NaN where no account has
        a reading yet) and the earliest reset still ahead (NaN when none)."""
        t = np.atleast_1d(np.asarray(t, dtype=np.int64))
        lev = np.full((len(self.series), len(t)), np.nan)
        ttr = np.full((len(self.series), len(t)), np.nan)
        for k, r in enumerate(self.series):
            i = np.searchsorted(r["t"], t, side="right") - 1
            have = i >= 0
            j = np.maximum(i, 0)
            act = r["active"][j] & (r["reset"][j] > t)
            fresh = (t - r["t"][j]) <= self.max_age
            val = np.where(act & fresh, r["p"][j], np.where(have, 0.0, np.nan))
            lev[k] = val
            ttr[k] = np.where(act & fresh, r["reset"][j] - t, np.nan)
        with np.errstate(all="ignore"):
            level = np.nanmean(lev, axis=0)
            ttr_min = np.nanmin(np.where(np.isnan(ttr), np.inf, ttr), axis=0)
        ttr_min = np.where(np.isinf(ttr_min), np.nan, ttr_min)
        return level, ttr_min

    def rate(self, value_between, now, days=28):
        """Points of this meter (mean over accounts) per unit of the group's usage, from the last `days`:
        value_between(t0, t1) must give the usage over each (t0, t1]."""
        t0 = now - days * DAY
        tot_pts = 0.0
        for r in self.series:
            t, p, reset, act = r["t"], r["p"], r["reset"], r["active"]
            m = t >= t0
            if m.sum() < 2:
                continue
            tt, pp, rr, aa = t[m], p[m], reset[m], act[m]
            same = aa[1:] & aa[:-1] & (np.abs(rr[1:] - rr[:-1]) < self.dur / 2)
            d = np.where(same, np.maximum(np.diff(pp), 0.0), np.where(aa[1:], pp[1:], 0.0))
            tot_pts += float(d.sum())
        tot_pts /= max(len(self.series), 1)
        use = float(value_between(np.array([t0]), np.array([now]))[0])
        if use <= 0 or tot_pts <= 0:
            return None
        return tot_pts / use
