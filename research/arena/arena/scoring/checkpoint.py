"""Score one forecast against what happened.

Truth is the real readings at their real times. The forecast paths are read at
those times by linear interpolation along the request grid (never
extrapolated: a truth time past the last grid point is dropped). Scores come
from `scoringrules`, not hand-rolled code; the only local arithmetic is the
bookkeeping around them.
"""
from __future__ import annotations

import math
import zlib

import numpy as np
import scoringrules as sr

from arena.types import (
    Forecast, Request, ScoreRow, Target, TargetForecast, TargetRequest,
    TargetTruth, Truth,
)

LEAD_EDGES_S = (300.0, 1800.0, 3600.0, 7200.0, 18000.0, 86400.0, 259200.0, 604800.0)
LIMIT_PCT = 99.5          # "reached the limit" for a path (readings round)
METER_TARGETS = {Target.METER_5H, Target.METER_7D, Target.METER_SCOPED}
HOUR_MS = 3_600_000.0
COVER_LEVELS = {"cover50": 0.50, "cover80": 0.80, "cover95": 0.95}
PIT_BINS = 10             # pit_b0 .. pit_b9: share of truth points per PIT decile
# Energy and variogram scores compare whole paths over at most this many
# evenly spaced truth points. scoringrules' variogram score holds an
# [n_paths, T, T] array: a 7-day meter has ~2,000 readings, which is 12 GB and
# 6 s per checkpoint at 200 paths. 128 points keep the path's shape (first
# and last reading included) at ~30 MB.
MULTIVARIATE_MAX_POINTS = 128


class InvalidForecast(ValueError):
    """The forecast cannot be scored (NaN, wrong shape). The runner records it
    as an `invalid_forecast` failure instead of a score."""


def lead_bin(lead_s: float) -> float:
    """Upper edge of the bin a lead falls in; beyond the last edge, the last."""
    for e in LEAD_EDGES_S:
        if lead_s <= e:
            return e
    return LEAD_EDGES_S[-1]


def interpolate_paths(paths: np.ndarray, grid: np.ndarray, times: np.ndarray) -> np.ndarray:
    """[n_paths, len(grid)] -> [n_paths, len(times)], linear along the grid,
    flat at `grid[0]` before the grid. Callers drop times past `grid[-1]`."""
    grid = np.asarray(grid, dtype=np.float64)
    times = np.asarray(times, dtype=np.float64)
    out = np.empty((paths.shape[0], len(times)))
    for i in range(paths.shape[0]):
        out[i] = np.interp(times, grid, paths[i])  # left edge = paths[i, 0]
    return out


def _crps(obs: np.ndarray, ens: np.ndarray) -> np.ndarray:
    """Fair ensemble CRPS per time. ens: [T, M]. One path has no spread to be
    fair about, so it reduces to absolute error.

    Computed with scoringrules' probability-weighted-moment estimator, which
    is the fair estimator exactly (Zamo & Naveau 2018; equal to 1e-15 in
    tests/scoring) but sorts instead of forming every pair: scoringrules'
    "fair" holds [T, M, M], 1.3 GB for a 7-day meter's ~2,000 readings at 200
    paths, and that made the runner's memory peak."""
    if ens.shape[1] == 1:
        return np.abs(ens[:, 0] - obs)
    return np.asarray(sr.crps_ensemble(obs, ens, m_axis=-1, estimator="pwm"))


def _validated(req: TargetRequest, tf: TargetForecast) -> np.ndarray:
    p = np.asarray(tf.paths, dtype=np.float64)
    if p.ndim != 2 or p.shape[0] < 1 or p.shape[1] != len(req.grid):
        raise InvalidForecast(
            f"{req.key}: paths shape {p.shape} does not match grid of {len(req.grid)}")
    # cycle.next_start paths hold NaN on purpose ("no start before the horizon").
    if req.target != Target.CYCLE_NEXT_START and not np.isfinite(p).all():
        raise InvalidForecast(f"{req.key}: paths contain NaN or inf")
    if np.isinf(p).any():
        raise InvalidForecast(f"{req.key}: paths contain inf")
    return p


def pit_values(obs: np.ndarray, ens: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Randomized PIT of each observation against its ensemble (ens: [M, T]):
    F(y-) + U * (F(y) - F(y-)). Readings and many paths are integers, so ties
    are common; spreading them uniformly keeps a calibrated forecast flat
    instead of piling ties into the middle bins."""
    below = (ens < obs[None, :]).mean(axis=0)
    at_or_below = (ens <= obs[None, :]).mean(axis=0)
    return below + rng.random(len(obs)) * (at_or_below - below)


def pit_histogram(pit: np.ndarray, bins: int = PIT_BINS) -> np.ndarray:
    """Share of PIT values in each of `bins` equal bins of [0, 1] (the last
    bin closed). Sums to 1; flat (1/bins each) when calibrated."""
    idx = np.minimum((np.asarray(pit) * bins).astype(int), bins - 1)
    return np.bincount(idx, minlength=bins)[:bins] / max(len(pit), 1)


def even_subset(n: int, k: int = MULTIVARIATE_MAX_POINTS) -> np.ndarray:
    """Indices of at most k evenly spaced points of n, first and last kept."""
    if n <= k:
        return np.arange(n)
    return np.unique(np.linspace(0, n - 1, k).round().astype(np.int64))


def _binned(rows, key, target, metric, leads_s, per_time):
    """Whole-path mean row plus one row per lead bin that has values."""
    rows.append(ScoreRow(key, target, metric, None, float(np.mean(per_time))))
    bins = np.array([lead_bin(l) for l in leads_s])
    for e in LEAD_EDGES_S:
        m = bins == e
        if m.any():
            rows.append(ScoreRow(key, target, metric, e, float(np.mean(per_time[m]))))


def _score_next_start(req, p, tt, now, rows):
    horizon_h = (tt.horizon_end - now) / HOUR_MS
    h = (p[:, -1] - now) / HOUR_MS
    h = np.where(np.isnan(h), horizon_h, np.minimum(h, horizon_h))
    actual = horizon_h if math.isnan(tt.next_start) else min((tt.next_start - now) / HOUR_MS, horizon_h)
    crps = float(_crps(np.array([actual]), h[None, :])[0])
    rows.append(ScoreRow(req.key, req.target.value, "crps", None, crps))
    rows.append(ScoreRow(req.key, req.target.value, "ae_point", None,
                         float(abs(np.median(h) - actual))))


def _score_target(request: Request, req: TargetRequest, tf: TargetForecast,
                  tt: TargetTruth) -> list[ScoreRow]:
    p = _validated(req, tf)
    key, tgt = req.key, req.target.value
    rows: list[ScoreRow] = []
    now = request.now

    if req.target == Target.CYCLE_NEXT_START:
        _score_next_start(req, p, tt, now, rows)
        return rows

    times = np.asarray(tt.times, dtype=np.float64)
    vals = np.asarray(tt.values, dtype=np.float64)
    keep = times <= float(req.grid[-1])      # never extrapolate
    times, vals = times[keep], vals[keep]
    if len(times) == 0:
        return rows
    order = np.argsort(times, kind="stable")
    times, vals = times[order], vals[order]

    at = interpolate_paths(p, req.grid, times)           # [M, T]
    leads_s = (times - now) / 1000.0
    median = np.median(at, axis=0)

    _binned(rows, key, tgt, "crps", leads_s, _crps(vals, at.T))
    _binned(rows, key, tgt, "ae_point", leads_s, np.abs(median - vals))

    if len(times) >= 2:
        sel = even_subset(len(times))
        rows.append(ScoreRow(key, tgt, "energy", None,
                             float(sr.es_ensemble(vals[sel], at[:, sel], m_axis=0, v_axis=1))))
        rows.append(ScoreRow(key, tgt, "variogram", None,
                             float(sr.vs_ensemble(vals[sel], at[:, sel], m_axis=0, v_axis=1))))

    rows.append(ScoreRow(key, tgt, "next_reading_ae", None, float(abs(median[0] - vals[0]))))

    for name, level in COVER_LEVELS.items():
        lo = np.quantile(at, (1 - level) / 2, axis=0)
        hi = np.quantile(at, 1 - (1 - level) / 2, axis=0)
        rows.append(ScoreRow(key, tgt, name, None, float(np.mean((vals >= lo) & (vals <= hi)))))

    # PIT histogram: the share of this checkpoint's truth points in each PIT
    # decile. The tie-breaking draw is seeded by the checkpoint and key, so a
    # rerun scores identically.
    rng = np.random.default_rng([int(now) & 0xFFFFFFFF, zlib.crc32(key.encode())])
    for b, share in enumerate(pit_histogram(pit_values(vals, at, rng))):
        rows.append(ScoreRow(key, tgt, f"pit_b{b}", None, float(share)))

    if req.target in METER_TARGETS:
        reset = tt.reset_at if tt.reset_at is not None else req.reset_at
        if reset is not None and reset <= tt.horizon_end:
            rows.append(ScoreRow(key, tgt, "ae_reset", None, float(abs(median[-1] - vals[-1]))))

        grid = np.asarray(req.grid, dtype=np.float64)
        before = grid <= reset if reset is not None else np.ones(len(grid), bool)
        if before.any() and tt.hit_limit is not None:
            share = float(np.mean((p[:, before] >= LIMIT_PCT).any(axis=1)))
            rows.append(ScoreRow(key, tgt, "brier_hit", None, (share - float(tt.hit_limit)) ** 2))
            direct = tf.extras.get("p_hit_limit")
            if direct is not None and np.isscalar(direct):
                rows.append(ScoreRow(key, tgt, "brier_hit_direct", None,
                                     (float(direct) - float(tt.hit_limit)) ** 2))

        # Time to the limit in hours from now, capped at the horizon; a path
        # that never gets there counts as the horizon.
        horizon_h = (tt.horizon_end - now) / HOUR_MS
        reached = p >= LIMIT_PCT
        first = np.where(reached.any(axis=1), reached.argmax(axis=1), -1)
        path_h = np.where(first >= 0, (grid[np.maximum(first, 0)] - now) / HOUR_MS, horizon_h)
        path_h = np.minimum(path_h, horizon_h)
        actual_h = horizon_h if math.isnan(tt.time_to_limit) else \
            min((tt.time_to_limit - now) / HOUR_MS, horizon_h)
        rows.append(ScoreRow(key, tgt, "crps_ttl", None,
                             float(_crps(np.array([actual_h]), path_h[None, :])[0])))
    return rows


def score_checkpoint(request: Request, forecast: Forecast, truth: Truth) -> list[ScoreRow]:
    """Every metric for every target key present in the request, forecast and
    truth. A missing key is skipped; an unscoreable forecast raises
    `InvalidForecast`."""
    rows: list[ScoreRow] = []
    for req in request.targets:
        tf = forecast.by_key.get(req.key)
        tt = truth.by_key.get(req.key)
        if tf is None or tt is None:
            continue
        rows.extend(_score_target(request, req, tf, tt))
    return rows
