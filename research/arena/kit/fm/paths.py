"""From a pretrained model's quantiles (or samples) to the sample paths the
arena scores.

Every function takes quantiles as `levels` (Q,) and `q` (..., T, Q): one
quantile curve per level over T times. Paths are `[n_paths, T]`.

- `fix_crossing`: sort along the level axis (some heads cross).
- `extend_tails`: a head trained on 0.1…0.9 says nothing about the outer
  20 %; paths drawn from it would never leave the 10–90 band, which the
  95 % coverage and PIT scores punish. The tails are extrapolated linearly in
  the normal-score scale from the two outermost levels (a Gaussian tail),
  never inward.
- `to_paths`: one uniform per path and time read through each time's
  quantile function. The dependence across times decides the shape of a
  path, not its marginals (CRPS sees only marginals; energy and variogram
  scores and any sum over the horizon see the dependence):
  * `comonotone`: one uniform per path for every time. A path that starts
    high stays high: right for a cumulative meter, whose quantile curves are
    themselves non-decreasing, so every path is too.
  * `ar1`: a Gaussian copula whose latent normal is an AR(1) with
    correlation `rho` per step: hourly spend is autocorrelated (busy spells
    last hours), but not for ever.
  * `independent`: a fresh uniform at each time.
- `monotone_meter`: what a meter path must satisfy: at least the latest
  reading, at most 100, never falling.
- `samples_to_paths`: for a model that samples (Toto), its own draws;
  `isotonic_paths` makes each one non-decreasing without ratcheting noise.
"""
from __future__ import annotations

from typing import Literal

import numpy as np
from scipy.special import ndtr, ndtri

Dependence = Literal["comonotone", "ar1", "independent"]


def fix_crossing(q: np.ndarray) -> np.ndarray:
    return np.sort(np.asarray(q, dtype=np.float64), axis=-1)


def extend_tails(levels, q, lo: float = 0.01, hi: float = 0.99) -> tuple[np.ndarray, np.ndarray]:
    """Add levels `lo` and `hi` when the head stops short of them."""
    lv = np.asarray(levels, dtype=np.float64)
    q = fix_crossing(q)
    if lv.min() > lo + 1e-9 and len(lv) >= 2:
        z0, z1 = ndtri(lv[0]), ndtri(lv[1])
        slope = (q[..., 1] - q[..., 0]) / (z1 - z0)
        new = q[..., 0] - np.maximum(slope, 0.0) * (z0 - ndtri(lo))
        lv = np.concatenate(([lo], lv))
        q = np.concatenate((new[..., None], q), axis=-1)
    if lv.max() < hi - 1e-9 and len(lv) >= 2:
        z0, z1 = ndtri(lv[-2]), ndtri(lv[-1])
        slope = (q[..., -1] - q[..., -2]) / (z1 - z0)
        new = q[..., -1] + np.maximum(slope, 0.0) * (ndtri(hi) - z1)
        lv = np.concatenate((lv, [hi]))
        q = np.concatenate((q, new[..., None]), axis=-1)
    return lv, q


def uniforms(n_paths: int, n_times: int, dependence: Dependence = "comonotone", rho: float = 0.8,
             rng: np.random.Generator | None = None) -> np.ndarray:
    """[n_paths, n_times] uniforms with the requested dependence across times."""
    rng = rng or np.random.default_rng(0)
    if dependence == "comonotone":
        # Stratified: path i sits at the (i + 0.5)/n quantile everywhere (a
        # random permutation keeps path order uninformative).
        u = (np.arange(n_paths) + 0.5) / n_paths
        return np.repeat(rng.permutation(u)[:, None], n_times, axis=1)
    if dependence == "independent":
        return rng.uniform(size=(n_paths, n_times))
    if dependence == "ar1":
        rho = float(np.clip(rho, -0.999, 0.999))
        z = np.empty((n_paths, n_times))
        z[:, 0] = rng.standard_normal(n_paths)
        e = rng.standard_normal((n_paths, n_times))
        s = np.sqrt(1.0 - rho * rho)
        for t in range(1, n_times):
            z[:, t] = rho * z[:, t - 1] + s * e[:, t]
        return ndtr(z)
    raise ValueError(f"unknown dependence {dependence!r}")


def to_paths(levels, q, n_paths: int, dependence: Dependence = "comonotone", rho: float = 0.8,
             rng: np.random.Generator | None = None) -> np.ndarray:
    """Quantiles `q` [T, Q] at `levels` -> paths [n_paths, T]. A uniform
    beyond the outermost level reads that level (no further extrapolation)."""
    lv = np.asarray(levels, dtype=np.float64)
    q = fix_crossing(q)
    T = q.shape[0]
    u = uniforms(n_paths, T, dependence, rho, rng)
    out = np.empty((n_paths, T))
    for j in range(T):
        out[:, j] = np.interp(u[:, j], lv, q[j])
    return out


def interp_times(t_from: np.ndarray, t_to: np.ndarray, v: np.ndarray) -> np.ndarray:
    """Linear interpolation of `v` [len(t_from), …] (along axis 0) at `t_to`,
    flat beyond the ends."""
    t_from = np.asarray(t_from, dtype=np.float64)
    t_to = np.asarray(t_to, dtype=np.float64)
    v = np.asarray(v, dtype=np.float64)
    flat = v.reshape(v.shape[0], -1)
    out = np.stack([np.interp(t_to, t_from, flat[:, k]) for k in range(flat.shape[1])], axis=-1)
    return out.reshape((len(t_to),) + v.shape[1:])


def monotone_meter(paths: np.ndarray, floor: float, cap: float = 100.0) -> np.ndarray:
    """Clip to [floor, cap] and make each path non-decreasing in time."""
    p = np.clip(np.asarray(paths, dtype=np.float64), floor, cap)
    return np.maximum.accumulate(p, axis=-1)


def burn_quantiles(q_cum: np.ndarray, c_last: float) -> np.ndarray:
    """Cumulative-burn quantile curves [H, Q] -> burn since now, per level
    non-decreasing in time and never negative, with no crossing."""
    b = np.asarray(q_cum, dtype=np.float64) - float(c_last)
    b = np.maximum.accumulate(np.maximum(b, 0.0), axis=0)
    return fix_crossing(b)


def isotonic_paths(paths: np.ndarray) -> np.ndarray:
    """Each path's closest non-decreasing path (least squares, pool adjacent
    violators). A running max would ratchet every upward wiggle of a noisy
    sample into the level; this keeps the path's average course."""
    from scipy.optimize import isotonic_regression
    p = np.asarray(paths, dtype=np.float64)
    return np.stack([isotonic_regression(row).x for row in p]) if p.size else p


def samples_to_paths(samples: np.ndarray, n_paths: int, rng: np.random.Generator | None = None) -> np.ndarray:
    """A model's own sample paths [S, T] -> [n, T]: all of them when S is at
    most the request's count, else a random subset."""
    s = np.asarray(samples, dtype=np.float64)
    if s.shape[0] <= n_paths:
        return s
    rng = rng or np.random.default_rng(0)
    return s[np.sort(rng.choice(s.shape[0], size=n_paths, replace=False))]
