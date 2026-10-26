"""A calibrated, lead-aware ensemble over meter children.

Three things this adds to `kit.ml.combine`'s combiners:

1. **Lead-banded weights.** A child that reads the next half hour well is not
   the one that reads the whole cycle well (on the board, `port-engine-*`
   wins `ae_reset` on the weekly meter while the foundation models win
   `crps`). Weights are fitted per lead band (the share of the forecast's
   span the point sits at) and interpolated along the grid, so the pooled
   path can follow one child early and another late.

2. **Spread calibration.** The pooled forecast is rescaled around its own
   median by a factor fitted on the same past forecasts (a 1-D grid search on
   CRPS, per band). Every strong single model on the board over-covers
   (cover50 ≈ 0.85 where 0.50 is nominal), and a linear pool of them is wider
   still: a mixture is at least as wide as its members. Shrinking it is worth
   more than any reweighting.

3. **A nowcast head.** The first reading after `now` is nearly the last one
   before it. The pooled path is blended toward the live level with a weight
   that decays over `anchor_tau_min`, which is what the persistence models
   are unbeatable at (`next_reading_ae`) without giving up the tail.

Everything is fitted on the ledger of `kit.ml.combine` (backtest origins plus
this episode's own checkpoints, scored only on readings that have arrived),
so nothing here sees the future.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, TargetForecast
from kit.ml.combine import METER, Combiner, kind_of, sorted_samples
from robust_child import ChildCaller

MIN_MS = 60_000.0


def _band_edges(cfg) -> np.ndarray:
    e = cfg.get("bands", [0.15, 0.5])
    return np.asarray([0.0, *[float(x) for x in e], 1.0], dtype=np.float64)


def _half_gini(x: np.ndarray) -> np.ndarray:
    m = x.shape[0]
    w = (2 * np.arange(1, m + 1) - m - 1)[:, None]
    return (np.sort(x, axis=0) * w).sum(axis=0) / (m * m)


def _simplex_min(fun, k, x0=None):
    from scipy.optimize import minimize
    if k == 1:
        return np.ones(1)
    x0 = np.full(k, 1.0 / k) if x0 is None else x0
    res = minimize(fun, x0, method="SLSQP", bounds=[(0.0, 1.0)] * k,
                   constraints=[{"type": "eq", "fun": lambda w: w.sum() - 1.0}],
                   options={"maxiter": 200, "ftol": 1e-10})
    w = np.clip(res.x if np.isfinite(res.x).all() else x0, 0.0, None)
    return w / w.sum() if w.sum() > 0 else np.full(k, 1.0 / k)


class Cell:
    """What was learned for one (kind, lead band): pool weights, the spread
    factor that minimized CRPS there, and the PIT recalibration map."""

    __slots__ = ("w", "scale", "rise", "ab", "n")

    def __init__(self, w, scale, n, ab=None, rise=1.0):
        self.w, self.scale, self.n, self.ab, self.rise = w, scale, n, ab, rise


def _pit(q: np.ndarray, y: np.ndarray, rng) -> np.ndarray:
    """Randomized PIT of y under sorted samples q [m, E] (the scorer's
    definition, so what is fitted here is what is scored)."""
    below = (q < y[None, :]).mean(axis=0)
    at = (q <= y[None, :]).mean(axis=0)
    return below + rng.random(len(y)) * (at - below)


def _fit_beta(u: np.ndarray, n0: float) -> tuple[float, float] | None:
    """Method-of-moments Beta fit of the observed PIT, shrunk toward
    uniform by n / (n + n0). The PIT of a well-calibrated forecast is
    uniform; a forecast that is too wide piles its PIT in the middle
    (a, b > 1) and one that is too narrow piles it in the tails (a, b < 1),
    so reading the pooled quantile curve at the Beta's own quantiles turns
    that shape back into a flat one."""
    u = np.clip(np.asarray(u, dtype=np.float64), 1e-4, 1 - 1e-4)
    n = len(u)
    if n < 8:
        return None
    m, v = float(u.mean()), float(u.var())
    if not (1e-6 < v < m * (1 - m)):
        return None
    c = m * (1 - m) / v - 1.0
    a, b = m * c, (1 - m) * c
    if not (np.isfinite(a) and np.isfinite(b)) or min(a, b) <= 0:
        return None
    lam = n / (n + max(n0, 1e-9))
    a = 1.0 + lam * (min(a, 20.0) - 1.0)
    b = 1.0 + lam * (min(b, 20.0) - 1.0)
    return float(a), float(b)


def _apply_beta(Q: np.ndarray, ab: tuple[float, float] | None) -> np.ndarray:
    """Read the sorted-sample curve Q [m, G] at the Beta's quantiles: the
    calibrated forecast F~ = G(F), whose quantile function is F^-1 o G^-1."""
    if ab is None:
        return Q
    from scipy.special import betaincinv
    m = Q.shape[0]
    lv = (np.arange(m) + 0.5) / m
    u = np.clip(betaincinv(ab[0], ab[1], lv), 0.0, 1.0)
    pos = np.clip(u * m - 0.5, 0.0, m - 1.0)
    lo = np.floor(pos).astype(int)
    hi = np.minimum(lo + 1, m - 1)
    fr = (pos - lo)[:, None]
    return Q[lo] * (1 - fr) + Q[hi] * fr


class BandedEnsemble(Combiner):
    """Combiner with lead-banded weights, a fitted spread factor and a
    nowcast head. Config:

    `bands`           inner edges of the lead-fraction bands (default .15/.5)
    `shrink`          pull of the band's weights toward equal (× mean loss)
    `half_life_n`     forgetting, in forecasts of the kind
    `min_points`      eval points a band needs before it is fitted
    `scales`          spread factors tried
    `scale_shrink`    pull of the fitted factor toward 1
    `anchor_tau_min`  nowcast half-life, per window kind or a number
    `monotone`        enforce non-decreasing paths within the cycle
    `pool`            mixture | quantile  (quantile = Vincentization)
    """

    rule = "banded-stack"
    default_pool = "quantile"

    def __init__(self, ctx):
        super().__init__(ctx)
        self.edges = _band_edges(self.cfg)
        self.nb = len(self.edges) - 1
        self.m_fit = int(self.cfg.get("m_fit", 40))
        self.min_points = int(self.cfg.get("min_points", 12))
        self.scales = np.asarray(self.cfg.get("scales", [0.3, 0.4, 0.5, 0.6, 0.75, 0.9, 1.0, 1.2, 1.5]),
                                 dtype=np.float64)
        self.scale_shrink = float(self.cfg.get("scale_shrink", 0.25))
        self.rises = np.asarray(self.cfg.get("rises", [0.0, 0.25, 0.5, 0.75, 1.0, 1.25]), dtype=np.float64)
        self.rise_shrink = float(self.cfg.get("rise_shrink", 0.15))
        self.shrink = float(self.cfg.get("shrink", 0.05))
        self.caller = ChildCaller(ctx)
        self._cells: dict[tuple[str, tuple[str, ...], int], Cell] = {}
        self._cells_at: dict[str, int] = {}

    # ---- fitting ---------------------------------------------------------
    def _tau_ms(self, kind: str) -> float:
        v = self.cfg.get("anchor_tau_min", {"five_hour": 8.0, "seven_day": 25.0, "weekly_scoped": 25.0})
        w = kind.split(":")[0]
        t = float(v.get(w, 15.0)) if isinstance(v, dict) else float(v)
        return t * MIN_MS

    def _band_of(self, group, times) -> np.ndarray:
        span = max(group.reset - group.origin, 1)
        f = (np.asarray(times, dtype=np.float64) - group.origin) / span
        return np.clip(np.digitize(f, self.edges[1:-1]), 0, self.nb - 1)

    def _fit_kind(self, kind: str, children: tuple[str, ...], now: int) -> None:
        """One cell per band: weights, then the spread factor at those
        weights. Bands with too little truth inherit the next lower band's
        cell (and, failing that, equal weights at scale 1)."""
        groups = [g for g in self.ledger.scored(kind, before=now)
                  if all(c in g.entries for c in children)]
        if not groups:
            for b in range(self.nb):
                self._cells[(kind, children, b)] = Cell(np.full(len(children), 1.0 / len(children)), 1.0, 0)
            return
        hl = max(self.half_life(kind), 1e-6)
        origins = np.array([g.origin for g in groups], dtype=np.float64)
        newer = (origins[None, :] > origins[:, None]).sum(axis=1).astype(np.float64)
        disc = 0.5 ** (newer / hl)

        prev: Cell | None = None
        for b in range(self.nb):
            cols, ys, ws, bs = [], [], [], []
            for g, d in zip(groups, disc):
                if d <= 1e-6 or len(g.y) == 0:
                    continue
                m = self._band_of(g, g.times) == b
                if not m.any():
                    continue
                cols.append(np.stack([g.x(c)[:, m] for c in children]))      # [k, m, e]
                ys.append(g.y[m])
                ws.append(np.full(int(m.sum()), d))
                bs.append(np.full(int(m.sum()), self._base_at(g)))
            npts = int(sum(len(y) for y in ys))
            if npts < self.min_points or not cols:
                self._cells[(kind, children, b)] = prev or Cell(
                    np.full(len(children), 1.0 / len(children)), 1.0, 0)
                continue
            # One array over every eval point of the band: the weight fit and
            # the calibration are then a handful of vectorised operations
            # instead of a Python loop per past forecast.
            X = np.concatenate(cols, axis=2)                                  # [k, m, E]
            y = np.concatenate(ys)
            pw = np.concatenate(ws)
            pw = pw / pw.sum()
            base = np.concatenate(bs)
            w = self._fit_weights(X, y, pw)
            scale, ab, rise = self._fit_calibration(X, y, pw, w, base)
            prev = Cell(w, scale, npts, ab, rise)
            self._cells[(kind, children, b)] = prev

    def _fit_weights(self, X: np.ndarray, y: np.ndarray, pw: np.ndarray) -> np.ndarray:
        """Simplex weights minimising the pooled CRPS over the band's points.

        For a mixture the CRPS is the exact quadratic
        Σ w_i a_i - ½ Σ w_i w_j D_ij, so `a` and `D` are formed once and the
        optimiser never touches the samples again. For a quantile pool the
        weights are fitted on that same quadratic (`fit_objective`): it is
        the right ordering of the children either way, and the width
        difference between the two pools is what the spread factor is for."""
        k = X.shape[0]
        eq = np.full(k, 1.0 / k)
        a = (np.abs(X - y[None, None, :]).mean(axis=1) * pw[None, :]).sum(axis=1)
        D = np.zeros((k, k))
        for i in range(k):
            D[i, i] = 2.0 * float((_half_gini(X[i]) * pw).sum())
            for j in range(i + 1, k):
                v = float((np.abs(X[i][:, None, :] - X[j][None, :, :]).mean(axis=(0, 1)) * pw).sum())
                D[i, j] = D[j, i] = v
        scale0 = max(float(a.mean()), 1e-6)
        if str(self.cfg.get("fit_objective", "mixture")) == "pool" and self.pool_kind == "quantile":
            def fun(w):
                return _wcrps(np.tensordot(w, X, axes=1), y, pw) / scale0 + self.shrink * ((w - eq) ** 2).sum()
        else:
            def fun(w):
                return (a @ w - 0.5 * w @ D @ w) / scale0 + self.shrink * ((w - eq) ** 2).sum()
        return _simplex_min(fun, k)

    def _base_at(self, g) -> float:
        """The meter's level when the forecast was made: what a rise is
        measured from."""
        s = self.data.meter(g.account, METER[g.target], g.cap) if self.data else None
        if s is None:
            return 0.0
        try:
            return float(s.level_at(g.origin)[0])
        except Exception:  # noqa: BLE001 - a series with nothing before the origin
            return 0.0

    def _fit_calibration(self, X, y, pw, w, base):
        """How much of the children's predicted rise to believe, how wide to
        make the result, and the Beta map of its PIT, all by minimising the
        same weighted CRPS over the band's own past points.

        The rise factor is the one that matters most here: a meter whose
        account goes idle simply stays where it is, and every child predicts
        a rise, so the pool's whole distribution sits above the truth
        (`pit_b0` ≈ 0.5 on the visible tier). Shrinking the *rise* keeps the
        forecast anchored where the meter actually is, which no change of
        weights or width can do. `recal` picks what is used:
        a comma-separated subset of rise, scale, beta (`recal`, default all
        three; "none" for an uncalibrated pool)."""
        recal = {t.strip() for t in str(self.cfg.get("recal", "rise,scale,beta")).split(",")}
        q0 = np.tensordot(w, X, axes=1) if self.pool_kind == "quantile" else _mix_samples(X, w, self.m_fit)
        rises = self.rises if "rise" in recal else np.array([1.0])
        scales = self.scales if "scale" in recal else np.array([1.0])
        ab = _fit_beta(_pit(q0, y, self.rng), float(self.cfg.get("beta_n0", 40.0))) \
            if "beta" in recal else None
        best, best_s, best_r = None, 1.0, 1.0
        for r in rises:
            q = base[None, :] + r * (q0 - base[None, :]) if r != 1.0 else q0
            med = np.median(q, axis=0, keepdims=True)
            pen_r = 1.0 + self.rise_shrink * (1.0 - r) ** 2
            for s in scales:
                loss = _wcrps(_apply_beta(med + s * (q - med), ab), y, pw) * pen_r * (
                    1.0 + self.scale_shrink * (np.log(s) ** 2))
                if best is None or loss < best:
                    best, best_s, best_r = loss, float(s), float(r)
        return best_s, ab, best_r

    # ---- forecasting -----------------------------------------------------
    def forecast(self, request):
        got: dict[str, Forecast] = {}
        for c in self.children:
            fc = self.caller.ask(c, request)
            if fc is None:
                continue
            got[c] = fc
            self.ledger.add(c, request, fc)
        self.ledger.score(self.data)
        out = {}
        for tr in request.targets:
            if tr.target not in METER:
                continue
            avail = tuple(c for c in self.children if c in got and tr.key in got[c].by_key)
            if not avail:
                out[tr.key] = self._flat(tr)
                continue
            kind = kind_of(tr.target, tr.cap)
            ck = (kind, avail)
            if self._cells_at.get(f"{kind}|{avail}") != int(request.now):
                self._fit_kind(kind, avail, int(request.now))
                self._cells_at[f"{kind}|{avail}"] = int(request.now)
            paths = [np.asarray(got[c].by_key[tr.key].paths, dtype=np.float64) for c in avail]
            P = self._blend(tr, request.now, paths, ck)
            out[tr.key] = self._finish(tr, request.now, P, kind)
        return Forecast(out)

    def _blend(self, tr, now, paths, ck) -> np.ndarray:
        """Pool per band, then interpolate between the bands' pooled
        quantile curves along the grid (so weights move smoothly)."""
        n = tr.n_paths
        grid = np.asarray(tr.grid, dtype=np.float64)
        reset = float(tr.reset_at) if tr.reset_at is not None else float(grid[-1])
        span = max(reset - now, 1.0)
        f = np.clip((grid - now) / span, 0.0, 1.0)
        S = np.stack([sorted_samples(p, n) for p in paths])                  # [k, n, G]
        mid = 0.5 * (self.edges[:-1] + self.edges[1:])
        base = self._level(tr)
        curves = []
        for b in range(self.nb):
            cell = self._cells.get((ck[0], ck[1], b))
            w = cell.w if cell is not None else np.full(len(paths), 1.0 / len(paths))
            s = cell.scale if cell is not None else 1.0
            r = cell.rise if cell is not None else 1.0
            q = _mix_samples(S, w, n) if self.pool_kind == "mixture" else np.tensordot(w, S, axes=1)
            if r != 1.0:
                q = base + r * (q - base)
            med = np.median(q, axis=0, keepdims=True)
            curves.append(_apply_beta(med + s * (q - med), cell.ab if cell is not None else None))
        Q = np.zeros_like(curves[0])
        for j, fj in enumerate(f):
            lo = int(np.clip(np.searchsorted(mid, fj) - 1, 0, self.nb - 1))
            hi = int(np.clip(lo + 1, 0, self.nb - 1))
            a = 0.0 if hi == lo or mid[hi] <= mid[lo] else \
                float(np.clip((fj - mid[lo]) / (mid[hi] - mid[lo]), 0.0, 1.0))
            Q[:, j] = (1 - a) * curves[lo][:, j] + a * curves[hi][:, j]
        return Q

    def _level(self, tr) -> float:
        """The meter's latest known value: the forecast's own starting point."""
        s = self.data.meter(tr.accounts[0], METER[tr.target], tr.cap) if self.data else None
        if s is None:
            return 0.0
        try:
            return float(s.level_at(self.data.now)[0])
        except Exception:  # noqa: BLE001
            return 0.0

    def _finish(self, tr, now, P, kind) -> TargetForecast:
        """Nowcast head, monotonicity, bounds, and the direct limit extras."""
        grid = np.asarray(tr.grid, dtype=np.float64)
        s = self.data.meter(tr.accounts[0], METER[tr.target], tr.cap) if self.data else None
        if s is not None:
            level = self._level(tr)
            tau = self._tau_ms(kind)
            if tau > 0:
                a = np.exp(-(grid - now) / tau)[None, :]
                P = a * level + (1 - a) * P
            if bool(self.cfg.get("floor_live", True)):
                P = np.maximum(P, level - float(self.cfg.get("floor_slack", 0.0)))
        if bool(self.cfg.get("monotone", True)):
            P = np.maximum.accumulate(P, axis=1)
        P = np.clip(P, 0.0, 100.0)
        extras = {}
        if bool(self.cfg.get("direct_extras", True)):
            hit = (P >= 99.5).any(axis=1)
            extras["p_hit_limit"] = float(hit.mean())
            first = np.where(hit, (P >= 99.5).argmax(axis=1), -1)
            extras["time_to_limit"] = np.where(first >= 0, grid[np.maximum(first, 0)], np.nan)
        return TargetForecast(P, extras)


def _mix_samples(S: np.ndarray, w: np.ndarray, n: int) -> np.ndarray:
    """A linear pool of children's sorted samples, as n sorted samples: the
    mixture's quantile function, read by inverting its CDF on the pooled
    sample set (deterministic, unlike drawing paths)."""
    k, m, G = S.shape
    w = np.asarray(w, dtype=np.float64)
    w = w / max(w.sum(), 1e-12)
    cnt = np.floor(w * n).astype(int)
    rest = n - cnt.sum()
    if rest > 0:
        cnt[np.argsort(-(w * n - cnt), kind="stable")[:rest]] += 1
    rows = []
    for i, c in enumerate(cnt):
        if c <= 0:
            continue
        lv = (np.arange(c) + 0.5) / c
        pos = np.clip(lv * m - 0.5, 0, m - 1)
        lo = np.floor(pos).astype(int)
        hi = np.minimum(lo + 1, m - 1)
        fr = (pos - lo)[:, None]
        rows.append(S[i][lo] * (1 - fr) + S[i][hi] * fr)
    return np.sort(np.vstack(rows), axis=0)


def _wcrps(q: np.ndarray, y: np.ndarray, pw: np.ndarray) -> float:
    """Weighted mean empirical CRPS of sorted samples [m, E] against y [E].

    Fair in the samples: E|X - y| - ½ E|X - X'|, the second term from the
    sorted values (Gini) instead of every pair."""
    a = np.abs(q - y[None, :]).mean(axis=0) - _half_gini(q)
    return float((a * pw).sum())
