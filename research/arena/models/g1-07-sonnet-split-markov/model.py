"""split.accounts: one account's share of its group's hourly spend.

Accounts of one person are used one at a time, in runs of hours: the share is
almost always 0 or 1 with occasional mixed hours around a hand-over. So each
path is a two-state chain over "who is the dominant account" (state 1 = this
account), flipped with per-hour hazards estimated from the group's own hourly
history (shrunk toward a prior), started at the dominant account of the most
recent active hour. Mixed hours are drawn from the empirical pool of mixed
shares. Hours in which the group spends nothing are not scored; the chain just
carries on through them.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from kit import spend as S

HOUR = 3_600_000


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
        out = {}
        group = tuple(request.scope.accounts)
        for tr in request.targets:
            if tr.target is Target.SPLIT:
                out[tr.key] = self._one(request.now, tr, group)
        return Forecast(out)

    def _hourly(self, accounts, hours):
        ends = self.history.now - HOUR * np.arange(hours - 1, -1, -1, dtype=np.int64)
        cols = []
        for a in accounts:
            _, v = S.hourly_series(self.history, (a,), hours)
            cols.append(v)
        return np.stack(cols, axis=0)                     # [A, H]

    def _one(self, now, tr, group):
        cfg = self.cfg
        acct = tr.accounts[0]
        grid = np.asarray(tr.grid, dtype=np.int64)
        K = len(grid)
        P = tr.n_paths
        rng = self.rng
        group = tuple(dict.fromkeys(group)) if group else (acct,)
        if acct not in group:
            group = group + (acct,)
        # history window: from the first turn of any group account
        first = None
        for a in group:
            led = S._ledger(self.history, a)
            if len(led.t):
                first = int(led.t[0]) if first is None else min(first, int(led.t[0]))
        if first is None:
            return TargetForecast(np.full((P, K), 1.0 / len(group)))
        hours = int(min(max((now - first) // HOUR + 1, 24), 24 * 120))
        V = self._hourly(group, hours)                    # [A, H]; last col = hour ending now
        ia = group.index(acct)
        tot = V.sum(axis=0)
        active = tot > 0
        if not active.any():
            return TargetForecast(np.full((P, K), 1.0 / len(group)))
        share = np.where(active, V[ia] / np.maximum(tot, 1e-12), np.nan)
        # restrict the estimation of flips to the era in which >= 2 accounts have been seen
        seen = np.cumsum((V > 0), axis=1) > 0              # [A, H] account seen yet
        multi = seen.sum(axis=0) >= 2
        dom = np.where(active, (share >= 0.5).astype(int), -1)      # 1 = this account dominant
        # forward-fill the dominant state through inactive hours
        filled = dom.copy()
        last = -1
        for j in range(hours):
            if filled[j] == -1:
                filled[j] = last
            else:
                last = filled[j]
        # most recent active hour's state; where there was none, 0.5 (unknown)
        cur = filled[-1]
        if cur == -1:
            cur = 1 if rng.random() < 0.5 else 0
        # flip counts from the multi-account era
        ph, pn = float(cfg.get("prior_hazard", 0.03)), float(cfg.get("prior_hours", 48.0))
        flips = {0: 0.0, 1: 0.0}
        expo = {0: 0.0, 1: 0.0}
        for j in range(1, hours):
            if not multi[j] or filled[j - 1] == -1 or filled[j] == -1:
                continue
            s0 = filled[j - 1]
            expo[s0] += 1.0
            if filled[j] != s0:
                flips[s0] += 1.0
        lam = {s: (flips[s] + ph * pn) / (expo[s] + pn) for s in (0, 1)}
        # mixed-hour pool
        mixed = share[active & (share > 0.02) & (share < 0.98)]
        mix_p = float(cfg.get("mix_prior", 0.15))
        n_act = int(active.sum())
        mix_rate = (len(mixed) + mix_p * 10) / (n_act + 10)
        # chain
        state = np.full(P, cur, dtype=int)
        out = np.zeros((P, K))
        # grid is hourly from now; step through hours
        lead_h = np.rint((grid - now) / HOUR).astype(int)
        h_max = int(lead_h.max())
        traj = np.zeros((P, h_max + 1), dtype=int)
        for h in range(1, h_max + 1):
            u = rng.random(P)
            flip_p = np.where(state == 1, lam[1], lam[0])
            state = np.where(u < flip_p, 1 - state, state)
            traj[:, h] = state
        vals = traj[:, np.clip(lead_h, 0, h_max)].astype(float)           # [P, K]
        if len(mixed) >= 3:
            m = rng.random((P, K)) < mix_rate
            draw = rng.choice(mixed, size=(P, K))
        else:
            m = rng.random((P, K)) < mix_rate
            draw = rng.uniform(0.15, 0.85, size=(P, K))
        vals = np.where(m, draw, vals)
        return TargetForecast(np.clip(vals, 0.0, 1.0))
