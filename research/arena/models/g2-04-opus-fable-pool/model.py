"""Pool several meter forecasts and put the result back on the lattice the
server actually reports.

Two ideas:

1. **Path pooling.** Each child's paths are sampled in fixed shares into one
   ensemble. Mixing differently-built ensembles lowers CRPS when their errors
   are not the same, and it hedges: the burst simulator is strong when the
   capped family is idle, the decay models when a burst is under way.

2. **Randomized rounding to whole points.** A meter reading is a whole
   number, so the truth lives on the integer lattice while every continuous
   forecast spreads mass between the lattice points and pays CRPS for it.
   Each path gets one uniform carry `U` for the whole path and is replaced by
   `floor(value + U)`. That keeps every marginal's mean, keeps a path
   monotone (one `U` per path, not per point), and strictly lowers the
   ensemble CRPS against lattice-valued truth: a forecast sitting at 33.4
   becomes 60 % at 33 and 40 % at 34, which is what the reading will be.
   `carry_from_readings` instead draws `U` inside the bracket the cycle's own
   readings and the spend between them imply, which is tighter than [0, 1)
   when the conversion is known.

Everything is read off the pooled, rounded paths, so the ranges, the chance
of hitting the limit and the time to it stay consistent with each other.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, TargetForecast
from kit import baselines as B
from kit import spend

HOUR_MS = 3_600_000
FAMILIES = list(spend.FAMILIES)


def _cap_family(scope_model):
    if not scope_model:
        return None
    s = str(scope_model).strip().lower()
    for f in FAMILIES[:-1]:
        if f in s:
            return f
    return None


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.rng = ctx.rng
        c = ctx.config
        self.shares = {str(k): dict(v) for k, v in c.get("shares", {}).items()}
        self.round = bool(c.get("round_to_points", True))
        self.carry_from_readings = bool(c.get("carry_from_readings", True))
        self.children = list(ctx.children)
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        got = {}
        for ch in self.children:
            try:
                got[ch] = self.ctx.model(ch).forecast(request)
            except Exception as e:                        # noqa: BLE001
                self.ctx.log(f"child {ch} failed: {type(e).__name__}: {str(e)[:160]}")
        out = {}
        for tr in request.targets:
            if tr.target not in B.WINDOW_OF:
                continue
            tf = self._pool(tr, got)
            if tf is not None:
                out[tr.key] = tf
        return Forecast(out)

    # ------------------------------------------------------------------
    def _pool(self, tr, got):
        shares = dict(self.shares.get(str(tr.target), {}))
        if not shares:
            shares = {c: 1.0 for c in self.children}
        avail = {c: np.asarray(got[c].by_key[tr.key].paths, dtype=np.float64)
                 for c in shares
                 if c in got and tr.key in got[c].by_key and shares[c] > 0}
        if not avail:
            avail = {c: np.asarray(got[c].by_key[tr.key].paths, dtype=np.float64)
                     for c in got if tr.key in got[c].by_key}
            shares = {c: 1.0 for c in avail}
        if not avail:
            return None
        n = tr.n_paths
        tot = sum(shares[c] for c in avail)
        counts = {c: int(round(n * shares[c] / tot)) for c in avail}
        first = next(iter(counts))
        counts[first] += n - sum(counts.values())
        parts = []
        for c, p in avail.items():
            k = counts[c]
            if k <= 0:
                continue
            idx = (self.rng.choice(p.shape[0], size=k, replace=False) if p.shape[0] >= k
                   else self.rng.integers(0, p.shape[0], size=k))
            parts.append(p[idx])
        paths = np.concatenate(parts, axis=0)

        m = B.meter_now(self.history, tr)
        base = float(m.latest)
        if self.round and abs(base - round(base)) < 1e-9:
            lo, hi = self._bracket(tr, m) if self.carry_from_readings else (0.0, 1.0)
            u = lo + self.rng.random(paths.shape[0]) * max(hi - lo, 0.0)
            paths = np.floor(paths + u[:, None])
        paths = np.maximum.accumulate(np.clip(paths, base, 100.0), axis=1)

        tf = TargetForecast(paths)
        grid = tr.grid.astype(np.float64)
        reset = tr.reset_at if tr.reset_at is not None else grid[-1]
        before = grid <= reset
        reached = paths >= 99.5
        tf.extras["p_hit_limit"] = float(reached[:, before].any(axis=1).mean()) if before.any() else 0.0
        first_i = np.where(reached.any(axis=1), reached.argmax(axis=1), -1)
        tf.extras["time_to_limit"] = np.where(first_i >= 0, grid[np.maximum(first_i, 0)], np.nan)
        return tf

    def _bracket(self, tr, m):
        """Where inside its whole point the meter sat at the last reading, from
        this cycle's readings and the converted spend between them."""
        h = self.history
        fam = _cap_family(m.scope_model)
        d = spend.fit_details(h, tr.accounts[0], m.window_kind, m.scope_model)
        if d is None or len(m.util) == 0:
            return 0.0, 1.0
        k = float(d.rates[FAMILIES.index(fam)]) if fam else float(np.mean(d.rates))
        if not np.isfinite(k) or k <= 0:
            k = float(d.pooled)
        if k <= 0:
            return 0.0, 1.0
        t, u = m.t, m.util
        keep = t >= t[-1] - 6 * HOUR_MS
        t, u = t[keep], u[keep]
        lo, hi = float(u[0]), float(u[0]) + 1.0
        for i in range(1, len(t)):
            moved = None
            if t[i] - t[i - 1] <= HOUR_MS and u[i] >= u[i - 1]:
                s = spend.spent_between(h, tr.accounts[0], int(t[i - 1]), int(t[i]))[0]
                moved = k * float(s[FAMILIES.index(fam)] if fam else s.sum())
            p = float(u[i])
            if moved is not None and lo + moved < p + 1 and hi + moved > p:
                lo, hi = max(lo + moved, p), min(hi + moved, p + 1)
            else:
                lo, hi = p, p + 1.0
        last = float(u[-1])
        lo = min(max(lo - last, 0.0), 1.0 - 1e-6)
        hi = min(max(hi - last, lo + 1e-6), 1.0 - 1e-6)
        return lo, hi
