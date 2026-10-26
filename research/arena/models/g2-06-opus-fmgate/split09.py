"""split.accounts as a two-state switching process with honest spread.

A user with several accounts mostly works on one at a time, so an account's
hourly share of the group's spend sits near 1 (it is the one in use) or near
0 (another is), with a few mixed hours around a switch. A flat recent share
(the naive model) is a point between the two and pays for it on every hour.

From the group's own hourly spend (recency weighted, the last `lookback_h`
hours):
- each hour with spend is "mine" (share >= 0.5) or "theirs";
- per state, a leaving rate per clock hour, by maximum likelihood over
  consecutive active hours (the gap between them counts as exposure),
  shrunk toward a prior rate;
- per state, the empirical shares of its hours (what a "mine" hour looks
  like: mostly 1, sometimes a mixed 0.7).

The state now is the account most recently activated (account_events, when
the view has them and the activation is newer than the last active hour),
else the last active hour's. Paths are the chain simulated hour by hour from
that state, each hour's share drawn from its state's pool: so near-term hours
are confident and later ones relax toward the long-run mix.

A share `recent_mix` of the paths is instead the group's recent share, flat
(the naive rule: the last day's share, else the last week's): with frequent
switches the chain alone was over-confident in the state it started from
(visible tier, multi-account days: CRPS 0.378 alone, 0.285 naive, 0.277 with
40 % of the paths flat at the recent share; 0.171 -> 0.180 on the other set).
"""
from __future__ import annotations

import math

import numpy as np
import polars as pl

from arena.types import Forecast, Target, TargetForecast
from kit import spend

HOUR_MS = 3_600_000


class Model:
    def __init__(self, ctx):
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        group = tuple(request.scope.accounts)
        out = {}
        for tr in request.targets:
            if tr.target is Target.SPLIT:
                out[tr.key] = self.split(int(request.now), tr, group)
        return Forecast(out)

    # ------------------------------------------------------------------
    def split(self, now: int, tr, group) -> TargetForecast:
        cfg = self.cfg
        acct = tr.accounts[0]
        n = int(tr.n_paths)
        G = len(tr.grid)
        L = int(cfg.get("lookback_h", 24 * 21))
        hl = float(cfg.get("half_life_h", 24 * 7))
        _, mine = spend.hourly_series(self.history, (acct,), L)
        tot = np.zeros(L)
        for a in group:
            tot += spend.hourly_series(self.history, (a,), L)[1]
        act = tot > float(cfg.get("min_spend", 1e-6))
        if not act.any():
            return TargetForecast.point(np.full(G, 1.0 / max(len(group), 1)), n)
        share = np.where(act, mine / np.where(act, tot, 1.0), np.nan)
        hours = np.arange(L)
        w_rec = 0.5 ** ((L - 1 - hours) / hl)
        ia = np.flatnonzero(act)
        x = share[ia]
        d = x >= 0.5
        wa = w_rec[ia]

        # Leaving rates per state (clock hours), MLE with a prior.
        prior_rate = float(cfg.get("prior_rate", 1.0 / 24))
        prior_w = float(cfg.get("prior_weight", 2.0))
        rates = {}
        for s in (True, False):
            if len(ia) >= 2:
                m = d[:-1] == s
                gaps = np.diff(ia)[m].astype(np.float64)
                sw = (d[1:] != d[:-1])[m]
                ww = np.sqrt(wa[:-1] * wa[1:])[m]
            else:
                gaps = sw = ww = np.zeros(0)
            rates[s] = self._mle_rate(gaps, sw.astype(bool), ww, prior_rate, prior_w)

        # Share pools per state.
        pools = {}
        for s, default in ((True, 1.0), (False, 0.0)):
            m = d == s
            if m.sum() >= 1:
                pools[s] = (x[m], wa[m] / wa[m].sum())
            else:
                pools[s] = (np.array([default]), np.array([1.0]))

        state = bool(d[-1])
        last_active_end = now - (L - 1 - int(ia[-1])) * HOUR_MS
        act_acct, act_t = self._activation(now, group)
        if act_acct is not None and act_t is not None and act_t >= last_active_end - HOUR_MS:
            state = act_acct == acct
        # Hours since the last active hour: the chain has had that long to move
        # (the activation, when newer, pins the state now).
        lead = np.rint((np.asarray(tr.grid, np.int64) - now) / HOUR_MS).astype(np.int64)
        paths = np.empty((n, G))
        st = np.full(n, state)
        prev = 0
        for j in range(G):
            dt = max(int(lead[j]) - prev, 1)
            prev = int(lead[j])
            p_leave = np.where(st, 1 - math.exp(-rates[True] * dt), 1 - math.exp(-rates[False] * dt))
            flip = self.rng.random(n) < p_leave
            st = np.where(flip, ~st, st)
            v = np.empty(n)
            for s in (True, False):
                m = st == s
                if m.any():
                    xs, ps = pools[s]
                    v[m] = xs[self.rng.choice(len(xs), size=int(m.sum()), p=ps)]
            paths[:, j] = v
        k = int(round(float(cfg.get("recent_mix", 0.0)) * n))
        if k > 0:
            recent = self._recent_share(acct, group)
            rows = self.rng.choice(n, size=k, replace=False)
            paths[rows] = recent
        return TargetForecast(np.clip(paths, 0.0, 1.0))

    def _recent_share(self, acct, group, hours=(24, 168)) -> float:
        for h in hours:
            tot = sum(float(spend.hourly_series(self.history, (a,), h)[1].sum()) for a in group)
            if tot > 0:
                return float(spend.hourly_series(self.history, (acct,), h)[1].sum()) / tot
        return 1.0 / max(len(group), 1)

    @staticmethod
    def _mle_rate(gaps, sw, w, prior_rate, prior_w) -> float:
        """Rate λ maximizing Σ w [sw·log(1-e^{-λg}) - (1-sw)·λg] plus a
        prior worth `prior_w` observations of one-hour gaps at prior_rate."""
        grid = np.exp(np.linspace(math.log(1e-3), math.log(2.0), 200))
        p0 = 1 - math.exp(-prior_rate)
        ll = prior_w * (p0 * np.log1p(-np.exp(-grid)) - (1 - p0) * grid)
        if len(gaps):
            G = gaps[None, :] * grid[:, None]
            ll = ll + (w[None, :] * np.where(sw[None, :], np.log(-np.expm1(-G) + 1e-12), -G)).sum(axis=1)
        return float(grid[int(np.argmax(ll))])

    def _activation(self, now, group):
        """The account most recently activated (and when), if the view holds
        account_events."""
        if "account_events" not in self.history.tables:
            return None, None
        ev = self.history.table("account_events")
        if not ev.height:
            return None, None
        ev = ev.filter((pl.col("kind") == "activation") & pl.col("account").is_in(list(group)))
        if not ev.height:
            return None, None
        ev = ev.with_columns(pl.col("t_event").dt.epoch("ms").alias("_t")).filter(pl.col("_t") <= now)
        if not ev.height:
            return None, None
        row = ev.sort("_t").tail(1)
        return str(row["account"][0]), int(row["_t"][0])
