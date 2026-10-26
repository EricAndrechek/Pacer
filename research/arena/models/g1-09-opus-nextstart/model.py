"""cycle.next_start as an analog ensemble over the account's own idle gaps.

An idle five-hour window ends with the account's next turn. From the
account's own turns (known by now) we rebuild its five-hour cycles (a cycle
starts at the first turn after the previous one reset, and resets 5 h later)
and take every past moment t' on a 10-minute lattice where the account was
idle in that sense. Each analog carries what happened next: the time from t'
to the next turn, or "none" if that was more than the horizon away.

The analogs are weighted by how much they look like now:
- idle so far (t' minus the last turn before it), on a log scale;
- the local hour of the day (circular) and weekday vs weekend;
- whether another account of the user was busy in the hour before, and in
  the day before (when the view shows other accounts: a user working on
  another account all day rarely comes back to this one);
- recency (a half-life in days), so a user who has stopped using an account
  sees that quickly.

When the account has been idle for hours while another account was busy in
the last day, a share `never_mix_away` of the samples is "no start": the
user is working elsewhere (visible tier, multi-account days: CRPS 1.13 ->
0.91; 1.28 -> 1.29 on the mostly single-account set).

The forecast is a weighted draw of analog outcomes, jittered a little on a
log scale (a smoothed empirical distribution), blended with a weak prior
when there are few effective analogs. NaN = no start before the horizon.
"""
from __future__ import annotations

import math

import numpy as np
import polars as pl

from arena.types import Forecast, Target, TargetForecast

HOUR_MS = 3_600_000
DAY_MS = 24 * HOUR_MS
MIN_MS = 60_000
WINDOW_MS = 5 * HOUR_MS
SYNTHETIC = "<synthetic>"


def cycles_from_turns(t: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Five-hour cycle (start, reset) pairs rebuilt from sorted turn times."""
    starts, resets = [], []
    i, n = 0, len(t)
    while i < n:
        s = int(t[i])
        r = s - s % (10 * MIN_MS) + WINDOW_MS
        starts.append(s)
        resets.append(r)
        i = int(np.searchsorted(t, r, side="left"))
    return np.asarray(starts, np.int64), np.asarray(resets, np.int64)


class Model:
    def __init__(self, ctx):
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.history = None
        self._turns = None

    def fit(self, history):
        self.history = history
        self._turns = None

    def update(self, events):
        self.history = self.history.extend(events)
        self._turns = None

    def _turn_times(self):
        if self._turns is None:
            t = self.history.table("turns")
            out = {}
            if t.height:
                t = t.filter(pl.col("model") != SYNTHETIC).select(
                    "account", pl.col("t_event").dt.epoch("ms").alias("te"))
                for (a,), g in t.group_by(["account"]):
                    out[str(a)] = np.sort(g["te"].to_numpy().astype(np.int64))
            self._turns = out
        return self._turns

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target is Target.CYCLE_NEXT_START:
                out[tr.key] = self.next_start(int(request.now), tr)
        return Forecast(out)

    # ------------------------------------------------------------------
    def next_start(self, now: int, tr) -> TargetForecast:
        n = int(tr.n_paths)
        horizon_end = int(tr.grid[-1])
        H = horizon_end - now
        acct = tr.accounts[0]
        turns = self._turn_times()
        t = turns.get(acct, np.zeros(0, np.int64))
        t = t[t <= now]
        others = [v[v <= now] for a, v in turns.items() if a != acct]
        others = np.sort(np.concatenate(others)) if others else np.zeros(0, np.int64)
        tz = (self.history.tz_offset_min or 0) * MIN_MS

        samples = self._analogs(now, H, t, others, tz, n)
        paths = np.where(np.isnan(samples), np.nan, now + samples)
        paths = np.where(paths > horizon_end, np.nan, paths)
        return TargetForecast(paths[:, None].astype(np.float64))

    def _analogs(self, now, H, t, others, tz, n) -> np.ndarray:
        cfg = self.cfg
        step = int(cfg.get("lattice_min", 10)) * MIN_MS
        lookback = float(cfg.get("lookback_days", 120)) * DAY_MS
        half_life = float(cfg.get("half_life_days", 14.0)) * DAY_MS
        bw_e = float(cfg.get("bw_log_idle", 0.6))
        kappa = float(cfg.get("kappa_hour", 2.0))
        prior_n = float(cfg.get("prior_n", 3.0))
        jitter = float(cfg.get("jitter", 0.15))

        last = int(t[-1]) if len(t) else None
        e_now = (now - last) if last is not None else 30 * DAY_MS
        busy_now = self._busy(others, np.array([now]))[0] if len(others) else False
        away_h = float(cfg.get("away_window_h", 24.0))
        away_now = self._busy(others, np.array([now]), away_h)[0] if len(others) else False

        if len(t) >= 2:
            lo = max(int(t[0]), int(now - lookback))
            hi = now - H                              # outcomes fully known by now
            if hi > lo:
                tp = np.arange(lo, hi, step, dtype=np.int64)
                starts, resets = cycles_from_turns(t)
                # the cycle holding the last turn before t' must have reset
                j = np.searchsorted(t, tp, side="right") - 1
                ok = j >= 0
                tp, j = tp[ok], j[ok]
                last_p = t[j]
                c = np.searchsorted(starts, last_p, side="right") - 1
                idle = tp >= resets[c]
                tp, last_p, j = tp[idle], last_p[idle], j[idle]
                nxt = np.where(j + 1 < len(t), t[np.minimum(j + 1, len(t) - 1)], np.iinfo(np.int64).max)
                r = (nxt - tp).astype(np.float64)
                r[r > H] = np.nan
                e_p = (tp - last_p).astype(np.float64)
                w = np.exp(-0.5 * ((np.log1p(e_p / (30 * MIN_MS)) - math.log1p(e_now / (30 * MIN_MS))) / bw_e) ** 2)
                hp = ((tp + tz) % DAY_MS) / HOUR_MS
                hn = ((now + tz) % DAY_MS) / HOUR_MS
                w *= np.exp(kappa * (np.cos(2 * np.pi * (hp - hn) / 24.0) - 1.0))
                wd_p = (((tp + tz) // DAY_MS) + 3) % 7 >= 5     # epoch day 0 was a Thursday
                wd_n = (((now + tz) // DAY_MS) + 3) % 7 >= 5
                w *= np.where(wd_p == wd_n, 1.0, float(cfg.get("weekend_mismatch", 0.5)))
                if len(others):
                    b = self._busy(others, tp)
                    w *= np.where(b == busy_now, 1.0, float(cfg.get("busy_mismatch", 0.4)))
                    b24 = self._busy(others, tp, away_h)
                    w *= np.where(b24 == away_now, 1.0, float(cfg.get("away_mismatch", 1.0)))
                w *= 0.5 ** ((now - tp) / half_life)
            else:
                r, w = np.zeros(0), np.zeros(0)
        else:
            r, w = np.zeros(0), np.zeros(0)

        # Effective analog count; a weak prior fills in when it is small.
        # Analogs on a 10-minute lattice are strongly correlated: count them
        # per hour of lattice.
        per = HOUR_MS / step
        n_eff = (w.sum() ** 2 / max((w ** 2).sum(), 1e-300)) / per if len(w) else 0.0
        p_prior = prior_n / (prior_n + n_eff)
        k_prior = self.rng.binomial(n, p_prior)
        k_an = n - k_prior
        out = np.empty(n)
        if k_an > 0 and w.sum() > 0:
            idx = self.rng.choice(len(r), size=k_an, p=w / w.sum())
            s = r[idx]
            fin = np.isfinite(s)
            s[fin] = np.minimum(s[fin] * np.exp(self.rng.normal(0, jitter, fin.sum())), H)
            out[:k_an] = s
        else:
            k_prior = n
        if k_prior > 0:
            out[n - k_prior:] = self._prior(e_now, H, k_prior)
        self.rng.shuffle(out)
        # Working elsewhere: idle here for a while and another account busy in
        # the last day. Then "no start before the horizon" is likelier than
        # this account's own past says (it was mostly a single-account past).
        q = float(cfg.get("never_mix", 0.0))
        if len(others) and e_now > float(cfg.get("away_idle_h", 6.0)) * HOUR_MS and \
                self._busy(others, np.array([now]), 24.0)[0]:
            q += float(cfg.get("never_mix_away", 0.0))
        if q > 0:
            out = np.where(self.rng.random(n) < min(q, 0.95), np.nan, out)
        return out

    def _prior(self, e_now, H, k) -> np.ndarray:
        """A weak prior: the longer the idle, the likelier no start at all;
        otherwise a start log-uniform over the horizon."""
        p_none = min(0.9, 0.25 + 0.15 * math.log1p(e_now / DAY_MS) * 3)
        none = self.rng.random(k) < p_none
        H = max(float(H), 2 * MIN_MS)
        s = np.exp(self.rng.uniform(math.log(min(5 * MIN_MS, H / 2)), math.log(H), k))
        return np.where(none, np.nan, s)

    @staticmethod
    def _busy(others: np.ndarray, at: np.ndarray, hours: float = 1.0) -> np.ndarray:
        """Did another account have a turn in the `hours` before each time?"""
        i = np.searchsorted(others, at, side="right")
        j = np.searchsorted(others, at - int(hours * HOUR_MS), side="right")
        return (i - j) > 0
