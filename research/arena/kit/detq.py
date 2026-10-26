"""Deterministic quantiles: a model's forecast as exact quantiles, before any
path is drawn. Sample paths cannot be matched across languages (different
random streams); these can, so they are what a port (Swift, in Pacer) checks
itself against. Nothing here changes what a model scores: each entry point
reads the same intermediates the model's own `forecast` draws its paths from.

    quantiles(model, request, levels) -> {key: DetQ}

- **Timestral meters** (`kit.fm.meter_model.MeterModel`): the forecaster's
  quantile head is deterministic given its weights; the meter's quantile at a
  level is linear in the level between the head's (tail-extended) levels,
  exactly what the comonotone paths are read from.
- **The analog model** (`g1-10-fable-analog`), when its meter forecast is a
  pure analog draw (the table has cuts, effective sample size >= `min_ess`,
  `block_share` 0: the five-hour meter): the draw is a weighted resample of
  the table's trajectories, so its quantiles are the weighted (type 1, inverse
  CDF) quantiles of those trajectories, then the dispersion shrink, which is
  monotone. Otherwise (the weekly meter's day-model simulation, a low-ESS
  mixture, the cold-start pace fallback) the forecast is a simulation: `exact`
  is False and the quantiles are those of `MC_PATHS` simulated paths (seeded),
  to be matched within Monte-Carlo error, not exactly.
- **The calibration layer** (`kit.calib.CalibModel`): the child's
  deterministic quantile curves at CURVE_LEVELS, treated as that many
  comonotone paths, through `kit.calib.apply`, read at the levels. Exact when
  the child's are.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field, replace

import numpy as np

from arena.types import Target

LEVELS_OUT = (0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95)
CURVE_LEVELS = (np.arange(200) + 0.5) / 200
MC_PATHS = 4000
MC_SPREAD = 4.0 * np.sqrt(2.0)   # standard errors of a difference of two n-path quantile estimates
TYPE1_TOL = 1e-9
WINDOW_FOR = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}


@dataclass
class DetQ:
    """`q` [len(levels), G] on the request grid. `exact`: reproducible to
    float precision (else a Monte-Carlo estimate from `mc_paths` paths, with
    `lo`/`hi`: the same estimate at each level -/+ MC_SPREAD standard errors,
    the band a second independent estimate falls in). `detail`:
    intermediates worth checking on their own."""

    levels: np.ndarray
    q: np.ndarray
    exact: bool
    mc_paths: int = 0
    detail: dict = field(default_factory=dict)
    lo: np.ndarray | None = None
    hi: np.ndarray | None = None
    sampled: np.ndarray | None = field(default=None, repr=False)   # MC: the sorted paths [mc_paths, G]

    @property
    def median(self) -> np.ndarray:
        return self.at(np.array([0.5]))[0]

    def at(self, levels) -> np.ndarray:
        """Linear in the level between this object's levels."""
        lv = np.asarray(levels, dtype=np.float64)
        return np.stack([np.interp(lv, self.levels, self.q[:, j]) for j in range(self.q.shape[1])], axis=1)


def weighted_type1(values: np.ndarray, weights: np.ndarray, levels) -> np.ndarray:
    """Per column of values [n, G]: the smallest value whose cumulative
    normalized weight (values sorted ascending, ties in row order) reaches
    the level, within TYPE1_TOL. [len(levels), G]."""
    V = np.asarray(values, dtype=np.float64)
    p = np.asarray(weights, dtype=np.float64)
    p = p / p.sum()
    lv = np.asarray(levels, dtype=np.float64)
    out = np.empty((len(lv), V.shape[1]))
    for j in range(V.shape[1]):
        o = np.argsort(V[:, j], kind="stable")
        cw = np.cumsum(p[o])
        k = np.minimum(np.searchsorted(cw, lv - TYPE1_TOL, side="left"), len(o) - 1)
        out[:, j] = V[o[k], j]
    return out


def mc_shift(levels, n: int) -> np.ndarray:
    lv = np.asarray(levels, dtype=np.float64)
    return MC_SPREAD * np.sqrt(lv * (1.0 - lv) / n)


def from_sampled(levels, S: np.ndarray, detail: dict) -> DetQ:
    """A Monte-Carlo DetQ from sorted paths S [n, G]."""
    from kit.calib import read_sorted
    lv = np.asarray(levels, dtype=np.float64)
    d = mc_shift(lv, S.shape[0])
    return DetQ(lv, read_sorted(S, lv), False, S.shape[0], detail,
                read_sorted(S, np.clip(lv - d, 0.0, 1.0)), read_sorted(S, np.clip(lv + d, 0.0, 1.0)), S)


def quantiles(model, request, levels=LEVELS_OUT) -> dict[str, DetQ]:
    """Every meter target of the request the model answers, as DetQ."""
    from kit.calib import CalibModel
    from kit.fm.meter_model import MeterModel
    if isinstance(model, CalibModel):
        return calib_quantiles(model, request, levels)
    if isinstance(model, MeterModel):
        return timestral_quantiles(model, request, levels)
    if _analog_module(model) is not None:
        return analog_quantiles(model, request, levels)
    raise NotImplementedError(f"no deterministic quantiles for {type(model).__module__}.{type(model).__name__}")


# ---------------------------------------------------------------------------
# Timestral (any kit.fm meter model with a quantile head)
# ---------------------------------------------------------------------------

def timestral_quantiles(model, request, levels=LEVELS_OUT) -> dict[str, DetQ]:
    readings = model.history.table("meter_readings")
    lv = np.asarray(levels, dtype=np.float64)
    out = {}
    for tr in request.targets:
        wk = WINDOW_FOR.get(tr.target)
        if wk is None:
            continue
        mq = model.meter_quantiles(readings, int(request.now), tr, wk)
        if mq.levels is None:
            q = np.repeat(mq.q[:, 0][None, :], len(lv), axis=0)
        else:
            q = np.stack([np.interp(lv, mq.levels, mq.q[j]) for j in range(mq.q.shape[0])], axis=1)
        detail = {"used": mq.used, "step_ms": int(mq.step), "horizon_steps": int(mq.horizon),
                  "context": mq.ctx_v, "flat": mq.levels is None}
        if mq.levels is not None:
            detail.update(levels_ext=mq.levels, raw_levels=mq.raw_levels, raw=mq.raw)
        out[tr.key] = DetQ(lv, q, True, 0, detail)
    return out


# ---------------------------------------------------------------------------
# g1-10-fable-analog
# ---------------------------------------------------------------------------

def _analog_module(model):
    mod = sys.modules.get(type(model).__module__)
    A = getattr(mod, "A", None)
    return A if A is not None and hasattr(A, "meter_paths_from_table") else None


def analog_query(model, tr):
    """(A, B, MeterQuery, cfg, table, kind) exactly as the model's `_meter` builds them."""
    from kit import baselines as B
    A = _analog_module(model)
    h = model.history
    acct = tr.accounts[0]
    m = B.meter_now(h, tr)
    kind, cap = m.window_kind, m.scope_model
    cfg = model.cfg.get("meter", {}).get(kind, {})
    tz = A.tz_ms(h, acct)
    now = h.now
    lags = A.meter_lags(kind)
    if len(m.t):
        u_now = float(m.util[-1])
        rates = np.array([u_now - A.step_at(m.t, m.util, np.array([now - lag]))[0] for lag in lags])
    else:
        u_now, rates = 0.0, np.zeros(len(lags))
    q = A.MeterQuery(e=float(now - m.start), remaining=float(m.reset - now), u=u_now, rates=rates,
                     hour=float(A.local_hour(np.array([now]), tz)[0]),
                     dow=int(A.local_dow(np.array([now]), tz)[0]), acct=acct, now=now)
    accounts = tuple(h.accounts) if h.accounts else (acct,)
    if acct not in accounts:
        accounts = (acct, *accounts)
    T = model._table(kind, cap, accounts, tz)
    return A, q, cfg, T, kind, tz


def analog_trajectories(A, T, q, grid: np.ndarray, cfg: dict) -> np.ndarray:
    """[len(T), G]: every table row's path on the grid, as `meter_paths_from_table`
    builds a drawn row's (pace scaling, interpolation, whole-point increments, clip)."""
    fr = np.clip((grid.astype(np.float64) - q.now) / max(q.remaining, 1.0), 0.0, 1.0)
    fk = np.concatenate(([0.0], np.arange(1, T.M + 1) / T.M))
    D = np.concatenate([np.zeros((len(T), 1)), T.D], axis=1)
    alpha = float(cfg.get("scale_alpha", 0.0))
    if alpha > 0:
        j = len(T.lags) - 1
        L = T.lags[j]
        c = float(cfg.get("scale_floor", 2.0))
        pace_q = 0.5 * max(q.rates[j], 0.0) + 0.5 * q.u / max(q.e, L) * L
        pace_a = 0.5 * np.maximum(T.rates[:, j], 0.0) + 0.5 * T.u0 / np.maximum(T.e, L) * L
        s = np.clip(((pace_q + c) / (pace_a + c)) ** alpha, float(cfg.get("scale_min", 0.3)),
                    float(cfg.get("scale_max", 3.0)))
        D = D * s[:, None]
    pos = np.clip(np.searchsorted(fk, fr, side="right") - 1, 0, T.M - 1)
    f0, f1 = fk[pos], fk[pos + 1]
    a = (fr - f0) / np.maximum(f1 - f0, 1e-12)
    inc = D[:, pos] * (1 - a) + D[:, pos + 1] * a
    inc = np.where(inc >= 0, np.floor(inc + 1e-9), np.ceil(inc - 1e-9))
    return np.clip(q.u + inc, 0.0, 100.0)


def analog_quantiles(model, request, levels=LEVELS_OUT) -> dict[str, DetQ]:
    lv = np.asarray(levels, dtype=np.float64)
    out = {}
    for tr in request.targets:
        if WINDOW_FOR.get(tr.target) is None:
            continue
        A, q, cfg, T, kind, tz = analog_query(model, tr)
        grid = np.asarray(tr.grid, dtype=np.int64)
        detail = {"kind": kind, "u": q.u, "elapsed_ms": int(q.e), "remaining_ms": int(q.remaining),
                  "rates": q.rates, "hour": q.hour, "dow": q.dow, "tz_ms": int(tz), "table_rows": len(T),
                  "table_cycles": int(T.n_cycles)}
        exact = False
        if len(T):
            w, scale, e = A.meter_weights(T, q, cfg)
            detail.update(ess=e, bw_scale=scale)
            exact = (np.isfinite(w).all() and w.sum() > 0 and e >= float(cfg.get("min_ess", 8))
                     and float(cfg.get("block_share", 0.0)) <= 0)
        if exact:
            V = analog_trajectories(A, T, q, grid, cfg)
            Q = weighted_type1(V, w, lv)
            shrink = float(cfg.get("shrink", 1.0))
            if shrink < 1.0:
                med = weighted_type1(V, w, [0.5])[0]
                Q = np.clip(np.rint(med[None, :] + shrink * (Q - med[None, :])), 0.0, 100.0)
                detail["shrink_median"] = med
            detail["shrink"] = shrink
            out[tr.key] = DetQ(lv, Q, True, 0, detail)
            continue
        # A simulation: quantiles of MC_PATHS seeded paths (the model's own code).
        saved = model.rng
        model.rng = np.random.default_rng(int(request.now) % (2 ** 32))
        try:
            P = model._meter(replace(tr, n_paths=MC_PATHS)).paths
        finally:
            model.rng = saved
        out[tr.key] = from_sampled(lv, np.sort(P, axis=0), detail)
    return out


# ---------------------------------------------------------------------------
# The calibration layer
# ---------------------------------------------------------------------------

def calib_quantiles(model, request, levels=LEVELS_OUT) -> dict[str, DetQ]:
    """Needs `model.ctx.model(child)` to be the child itself (an in-process
    instance, as `arena port-fixtures` runs it), not a runner proxy."""
    from kit.calib import apply, kind_of, read_sorted
    child = model.ctx.model(model.child)
    base = quantiles(child, request, CURVE_LEVELS)
    now = int(request.now)
    model.fits = model.calibrate(now)
    lv = np.asarray(levels, dtype=np.float64)
    out = {}
    for tr in request.targets:
        d = base.get(tr.key)
        kind = kind_of(tr.target, tr.cap)
        if d is None or kind is None:
            continue
        fit = model.fits.get(kind)
        rw = bool(model.cfg.get("round", True))

        def through(curves):
            return read_sorted(np.sort(apply(fit, curves, tr.grid, now, round_whole=rw), axis=0), lv)
        detail = {"fit": fit.to_json() if fit is not None else None, "child_exact": d.exact}
        res = DetQ(lv, through(d.q), d.exact, d.mc_paths, detail)
        if not d.exact and d.sampled is not None:
            # The map is monotone in the child's values: the child's MC band
            # carried through it bounds the calibrated estimate.
            dd = mc_shift(CURVE_LEVELS, d.sampled.shape[0])
            # (Approximately: rounding to whole points can tip a bound by half
            # a point, so the estimate itself is kept inside its band.)
            res.lo = np.minimum(through(read_sorted(d.sampled, np.clip(CURVE_LEVELS - dd, 0.0, 1.0))), res.q)
            res.hi = np.maximum(through(read_sorted(d.sampled, np.clip(CURVE_LEVELS + dd, 0.0, 1.0))), res.q)
        out[tr.key] = res
    return out
