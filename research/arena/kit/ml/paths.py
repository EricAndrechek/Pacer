"""Quantiles, paths and scores shared by the learned models and the
combiners.

- `tidy_rise_quantiles`: make a [levels × leads] table of meter rises a
  proper cumulative forecast: no crossing across levels, never falling with
  lead, within [0, headroom].
- `rise_paths`: such a table, read at anchor leads, to sample paths on a
  request grid (comonotone: a path high early stays high, as a meter does).
- `sorted_samples` / `crps_sorted`: the empirical CRPS of a sample set,
  exact for the samples, from their sorted values (the combiners store each
  child's forecast as m sorted values per grid time).
"""
from __future__ import annotations

import numpy as np

from arena.types import TargetForecast


def tidy_rise_quantiles(q: np.ndarray, headroom: float) -> np.ndarray:
    """q: [n_levels, n_leads] (levels ascending, leads ascending)."""
    q = np.clip(np.asarray(q, dtype=np.float64), 0.0, max(headroom, 0.0))
    q = np.sort(q, axis=0)
    return np.maximum.accumulate(q, axis=1)


def with_tails(levels: np.ndarray, q: np.ndarray, headroom: float) -> tuple[np.ndarray, np.ndarray]:
    """Extend a quantile table to levels 0 and 1 by half the outer gaps
    (bounded by 0 and the headroom), so sampled paths aren't cut at the
    outermost fitted levels."""
    lo = np.maximum(q[0] - 0.5 * (q[1] - q[0]), 0.0)
    hi = np.minimum(q[-1] + 0.5 * (q[-1] - q[-2]), max(headroom, 0.0))
    hi = np.maximum(hi, q[-1])
    return np.concatenate(([0.0], levels, [1.0])), np.vstack([lo, q, hi])


def rise_paths(levels: np.ndarray, q: np.ndarray, anchor_fracs: np.ndarray, grid_fracs: np.ndarray,
               used: float, n_paths: int, rng: np.random.Generator) -> TargetForecast:
    """Paths of the meter (used + rise) on a grid, from rise quantiles at
    anchor lead fractions (rise 0 at lead 0)."""
    head = max(100.0 - used, 0.0)
    q = tidy_rise_quantiles(q, head)
    lv, q = with_tails(np.asarray(levels, dtype=np.float64), q, head)
    q = np.maximum.accumulate(np.sort(q, axis=0), axis=1)
    fa = np.concatenate(([0.0], anchor_fracs))
    qa = np.hstack([np.zeros((len(lv), 1)), q])
    g = np.clip(grid_fracs, 0.0, 1.0)
    Q = np.stack([np.interp(g, fa, row) for row in qa])          # [levels, grid]
    tf = TargetForecast.from_quantiles(lv, Q, n_paths=n_paths, rng=rng)
    tf.paths = np.clip(used + tf.paths, used, 100.0)
    return tf


def sample_rise_paths(samples: np.ndarray, anchor_fracs: np.ndarray, grid_fracs: np.ndarray,
                      used: float) -> np.ndarray:
    """Whole sampled rise trajectories at anchor fracs ([n, k]) to meter
    paths on the grid."""
    head = max(100.0 - used, 0.0)
    s = np.maximum.accumulate(np.clip(samples, 0.0, head), axis=1)
    fa = np.concatenate(([0.0], anchor_fracs))
    sa = np.hstack([np.zeros((len(s), 1)), s])
    g = np.clip(grid_fracs, 0.0, 1.0)
    out = np.stack([np.interp(g, fa, row) for row in sa])
    return np.clip(used + out, used, 100.0)


def grid_fracs(grid: np.ndarray, now: int, reset: int) -> np.ndarray:
    span = max(reset - now, 1)
    return (np.asarray(grid, dtype=np.float64) - now) / span


def sorted_samples(paths: np.ndarray, m: int) -> np.ndarray:
    """[m, G]: the paths' quantiles at levels (i + 0.5) / m per grid time
    (all of them, sorted, when there are exactly m)."""
    P = np.sort(np.asarray(paths, dtype=np.float64), axis=0)
    n = P.shape[0]
    if n == m:
        return P
    lv = (np.arange(m) + 0.5) / m
    pos = lv * n - 0.5
    lo = np.clip(np.floor(pos).astype(int), 0, n - 1)
    hi = np.clip(lo + 1, 0, n - 1)
    w = (pos - lo)[:, None]
    return (1 - w) * P[lo] + w * P[hi]


def crps_sorted(x: np.ndarray, y: np.ndarray) -> np.ndarray:
    """CRPS of the empirical distribution of each column's samples.
    x: [m, E] sorted ascending along axis 0; y: [E]."""
    m = x.shape[0]
    a = np.abs(x - y[None, :]).mean(axis=0)
    w = (2 * np.arange(1, m + 1) - m - 1)[:, None]
    b = (w * x).sum(axis=0) / (m * m)            # = E|X - X'| / 2
    return a - b


def crps_paths(paths: np.ndarray, y: np.ndarray) -> np.ndarray:
    """Ensemble CRPS per column: paths [n, E] read at the truth times."""
    return crps_sorted(np.sort(paths, axis=0), y)
