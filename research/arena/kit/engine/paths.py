"""An outlook as forecast paths on a request's grid.

The middle of the fan is the shown model's drawn trajectory: the anchored
projection, floored at the latest reading, capped at 100, non-decreasing
(`rateLimitTrajectories`); at the reset it is the displayed value. The
spread is the model's own conformal residuals (truth − displayed at reset,
the calibrator the app's band reads), one residual per path at evenly spaced
levels through the conformal quantile rule, grown linearly in time from 0
now to the full residual at the reset. Each path is clipped to
[latest reading, 100] and kept non-decreasing.

When the calibrator holds fewer than `conformal_min_residuals` residuals the
app states no band, and neither does this: every path is the middle one.
"""
from __future__ import annotations

import numpy as np

from kit.engine.core import displayed_path
from kit.engine.params import Params
from kit.engine.selfeval import quantile


def flat_paths(value: float, n_grid: int, n_paths: int) -> np.ndarray:
    return np.full((n_paths, n_grid), float(value))


def outlook_paths(outlook, grid_s: np.ndarray, n_paths: int, params: Params) -> np.ndarray:
    """[n_paths, len(grid)] paths for an outlook that has a projection."""
    c = outlook.partial
    center = displayed_path(outlook.proj, c, grid_s)
    res = outlook.residuals
    if len(res) < params.conformal_min_residuals:
        return np.repeat(center[None, :], n_paths, axis=0)
    u = (np.arange(n_paths, dtype=np.float64) + 0.5) / n_paths
    r = np.asarray(quantile(res, u), dtype=np.float64)
    span = max(c.reset - c.now, 1.0)
    s = np.clip((grid_s - c.now) / span, 0.0, 1.0)
    paths = np.clip(center[None, :] + r[:, None] * s[None, :], c.used_now, 100.0)
    return np.maximum.accumulate(paths, axis=1)
