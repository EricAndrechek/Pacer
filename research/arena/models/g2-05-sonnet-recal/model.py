"""Online calibration layer over one or more meter children.

The children's forecasts are pooled (Vincentization) and then mapped through
    x' = b + a (med - b) + s (x - med)
with b the meter's current level and med the pooled median, clipped to
[b, 100]. (a, s) are picked per window kind to minimise the discounted mean
CRPS of the same map on the resolved past forecasts (the ledger, backtests
plus the episode's own calls), with a penalty pulling them to an offline prior
that fades as scored forecasts accumulate.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, TargetForecast
from kit.ml.combine import Combiner, METER, discount, kind_of
from kit.ml.paths import crps_sorted, sorted_samples

A_GRID = np.array([0.25, 0.35, 0.5, 0.7, 0.85, 1.0, 1.2, 1.5])
S_GRID = np.array([0.3, 0.5, 0.7, 0.85, 1.0, 1.25, 1.6])
Z_GRID = np.array([0.0, 0.1, 0.2, 0.35, 0.5])


def apply_map(x: np.ndarray, b: float, a: float, s: float, z: float = 0.0) -> np.ndarray:
    """x: [m, G] sorted samples along axis 0 -> mapped, still sorted.
    Shift/scale about the median, then a point mass of weight z at the current
    level b (the meter did not move)."""
    med = np.median(x, axis=0, keepdims=True)
    y = np.clip(b + a * (med - b) + s * (x - med), b, 100.0)
    if z > 0.0:
        m = y.shape[0]
        lv = (np.arange(m) + 0.5) / m
        lv_src = np.concatenate(([0.0], lv, [1.0]))
        top = np.minimum(y[-1] + (y[-1] - y[-2]), 100.0)
        src = np.vstack([np.full((1, y.shape[1]), b), y, top[None, :]])
        q = np.clip((lv - z) / (1.0 - z), 0.0, 1.0)
        i1 = np.clip(np.searchsorted(lv_src, q, side="right"), 1, len(lv_src) - 1)
        w = ((q - lv_src[i1 - 1]) / (lv_src[i1] - lv_src[i1 - 1]))[:, None]
        y = (1.0 - w) * src[i1 - 1] + w * src[i1]
    return y


class Model(Combiner):
    rule = "equal"
    default_pool = "quantile"

    def _base(self, g) -> float:
        s = self.data.meter(g.account, METER[g.target], g.cap)
        if s is None:
            return 0.0
        return float(s.level_at(g.origin)[0])

    def _group_x(self, g):
        xs = [g.x(c) for c in self.children if c in g.entries]
        if not xs:
            return None
        return np.mean(xs, axis=0) if len(xs) > 1 else xs[0]

    def fit_map(self, kind: str, now: int):
        prior = (self.cfg.get("prior") or {}).get(kind.split(":")[0], [1.0, 1.0])
        a0, s0 = float(prior[0]), float(prior[1])
        z0 = float(prior[2]) if len(prior) > 2 else 0.0
        groups = [g for g in self.ledger.scored(kind, before=now)
                  if all(c in g.entries for c in self.children)]
        if not groups:
            return a0, s0, z0, 0.0
        d = discount(groups, now, self.half_life(kind))
        if d.sum() <= 1e-9:
            return a0, s0, z0, 0.0
        data = []
        for wg, g in zip(d, groups):
            x = self._group_x(g)
            if x is None or wg <= 0:
                continue
            data.append((wg, x, g.y, self._base(g)))
        if not data:
            return a0, s0, z0, 0.0
        n_eff = float(sum(w for w, *_ in data))
        # loss surface over (a, s)
        n0 = float(self.cfg.get("n0", 6.0))
        lam = n0 / (n_eff + n0)
        pen_w = float(self.cfg.get("pen", 4.0))

        def loss(a, s, z):
            return sum(wg * crps_sorted(apply_map(x, b, a, s, z), y).mean() for wg, x, y, b in data) / n_eff

        def pick(grid, f, p0):
            Ls = np.array([f(v) for v in grid])
            L0 = max(float(Ls.min()), 0.05)
            pen = lam * L0 * pen_w * (np.log(grid) - np.log(p0)) ** 2
            if self.cfg.get("debug"):
                self.ctx.log("  L " + " ".join(f"{v:.2f}:{l:.3f}" for v, l in zip(grid, Ls)))
            return float(grid[int(np.argmin(Ls + pen))])

        # stage 1: a multiplicative rescale of the increment (an allowance
        # or burn-rate shift): a only, spread untouched
        a = pick(A_GRID, lambda v: loss(v, s0 * v, z0), a0)
        # stage 2: spread about the median
        s = pick(S_GRID, lambda v: loss(a, v, z0), s0)
        z = z0
        if self.cfg.get("use_z", False):
            Ls = np.array([loss(a, s, v) for v in Z_GRID])
            L0 = max(float(Ls.min()), 0.05)
            z = float(Z_GRID[int(np.argmin(Ls + lam * L0 * pen_w * 4 * (Z_GRID - z0) ** 2))])
        return a, s, z, n_eff

    def forecast(self, request):
        got = {}
        for c in self.children:
            try:
                got[c] = self.ctx.model(c).forecast(request)
            except Exception as e:  # noqa: BLE001
                self.ctx.log(f"child {c} failed: {type(e).__name__}: {str(e)[:200]}")
                continue
            self.ledger.add(c, request, got[c])
        self.ledger.score(self.data)
        out = {}
        for tr in request.targets:
            if tr.target not in METER:
                continue
            avail = [c for c in self.children if c in got and tr.key in got[c].by_key]
            if not avail:
                out[tr.key] = self._flat(tr)
                continue
            paths = [np.asarray(got[c].by_key[tr.key].paths, dtype=np.float64) for c in avail]
            m = max(tr.n_paths, 40)
            P = np.mean([sorted_samples(p, m) for p in paths], axis=0)
            kind = kind_of(tr.target, tr.cap)
            a, s, z, n = self.fit_map(kind, request.now)
            s_ = self.data.meter(tr.accounts[0], METER[tr.target], tr.cap)
            b = float(s_.level_at(request.now)[0]) if s_ is not None else float(P[:, 0].min())
            b = min(b, float(np.median(P[:, 0])) + 5.0) if np.isfinite(b) else float(P[:, 0].min())
            Q = apply_map(P, b, a, s, z)
            self.ctx.log(f"map {tr.key} @{request.now}: a={a:.2f} s={s:.2f} z={z:.2f} n_eff={n:.1f}")
            if Q.shape[0] != tr.n_paths:
                Q = sorted_samples(Q, tr.n_paths)
            out[tr.key] = TargetForecast(Q)
        return Forecast(out)
