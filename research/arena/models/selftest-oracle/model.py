"""Self-test oracle (`arena selftest`): forecasts the truth the runner hands
it in `ctx.oracle` (runner `_with_oracle`, enabled only by trusted code in the
runner's own process). Without it, it is the constant 0 (selftest-constant).

From the truth (real reading times and values) to grid paths:
- hourly targets: the truth is read at grid times, so it is copied in place;
- meters: the grid path that the scorer, reading it at the truth's times,
  reads back as the truth (least squares; exact while each grid step holds at
  most one reading); never past 99.4 unless a reading reached the limit (so a
  path "hits" only when the truth did);
- cycle.next_start: the actual start, NaN when none.

`config.shift_ms` (a control) pretends every value happened that much later:
a correct harness must then score it worse."""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast

METERS = (Target.METER_5H, Target.METER_7D, Target.METER_SCOPED)


def interp_matrix(grid: np.ndarray, t: np.ndarray) -> np.ndarray:
    """A [len(t), len(grid)] with A @ path == np.interp(t, grid, path): how
    the scorer reads a grid path at the truth times (flat before grid[0])."""
    g = grid.astype(np.float64)
    A = np.zeros((len(t), len(g)))
    for r, x in enumerate(t.astype(np.float64)):
        if x <= g[0] or len(g) == 1:
            A[r, 0] = 1.0
        elif x >= g[-1]:
            A[r, -1] = 1.0
        else:
            j = int(np.searchsorted(g, x, side="right")) - 1
            a = (x - g[j]) / (g[j + 1] - g[j])
            A[r, j], A[r, j + 1] = 1.0 - a, a
    return A


def onto_grid(grid: np.ndarray, t: np.ndarray, v: np.ndarray, eps: float = 1e-6) -> np.ndarray:
    """The grid path the scorer reads back as the truth: exactly whenever
    each grid step holds at most one reading, else as near as least squares
    gets, staying close to the plain interpolation where the truth leaves a
    grid value free."""
    g = grid.astype(np.float64)
    natural = np.interp(g, t.astype(np.float64), v)
    A = interp_matrix(g, t)
    M = np.vstack([A, np.sqrt(eps) * np.eye(len(g))])
    rhs = np.concatenate([v, np.sqrt(eps) * natural])
    return np.linalg.lstsq(M, rhs, rcond=None)[0]


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.shift = int(ctx.config.get("shift_ms", 0))

    def fit(self, history):
        pass

    def update(self, events):
        pass

    def forecast(self, request):
        truth = getattr(self.ctx, "oracle", None) or {}
        out = {}
        for tr in request.targets:
            tt = truth.get(tr.key)
            n = len(tr.grid)
            if tr.target is Target.CYCLE_NEXT_START:
                v = np.nan if tt is None else tt.next_start + (self.shift if np.isfinite(tt.next_start) else 0)
                out[tr.key] = TargetForecast(np.full((1, n), v))
                continue
            if tt is None or len(tt.times) == 0:
                out[tr.key] = TargetForecast.point(np.zeros(n))
                continue
            t = tt.times + self.shift
            if tr.target in METERS:
                p = onto_grid(tr.grid, t, tt.values)
                cap = 100.0 if tt.values.max() >= 100.0 else 99.4
                p = np.clip(p, 0.0, cap)
            else:
                p = np.interp(tr.grid.astype(np.float64), t.astype(np.float64), tt.values)
            out[tr.key] = TargetForecast.point(p)
        return Forecast(out)
