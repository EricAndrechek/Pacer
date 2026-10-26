"""Cycle segmentation and the burn-trajectory methods: numpy ports of
`BurnTrajectory` (segment, PartialCycle, displayedAtReset),
`BurnTrajectoryModels` (linear-recent, recent-rate, recency-weighted,
damped-acceleration, saturating, kalman-trend) and `DiurnalBurnModel`.

The Swift code is the reference; `research/harness/pacer_replay.py` is the
earlier Python port. Where the two differ, this follows Swift, and says so:
- `DiurnalBurnModel.fit` declines until 5% of the cycle's expected activity
  has happened (`minObservedShare`); pacer_replay lacks the guard.
- `TrendEstimator`'s singularity tests are relative to the design's scale
  (`epsilon(of:)`); pacer_replay uses a fixed 1e-12.
- Period keys and segment groups round the reset to the minute half away from
  zero (`.rounded()`); pacer_replay's `round` rounds half to even.

Times are epoch seconds (float64) throughout; values are meter percent.
A projection is a callable taking a float or an array of epoch seconds.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from kit.engine.clock import HOUR_S, LocalClock
from kit.engine.params import Params

# BurnTrajectory.resetDropPoints / resetLowMax
RESET_DROP_POINTS = 15.0
RESET_LOW_MAX = 5.0
# EngineSelfEval.rlCutFractions
RL_CUT_FRACTIONS = (0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9)
# WindowSpec.isWeeklyScale
WEEKLY_SCALE_THRESHOLD = 24 * HOUR_S

METHOD_IDS = ("linear-recent", "recency-weighted", "damped-acceleration", "saturating",
              "kalman-trend", "recent-rate", "diurnal-rate")
DEFAULT_IDS = METHOD_IDS[:6]                 # BurnTrajectory.defaultModels, in order
COMPLEXITY = {"linear-recent": 1, "recency-weighted": 2, "damped-acceleration": 4, "saturating": 3,
              "kalman-trend": 5, "recent-rate": 1, "diurnal-rate": 3}


def is_weekly_scale(duration_s: float) -> bool:
    return duration_s >= WEEKLY_SCALE_THRESHOLD


def round_minute(t: float) -> float:
    """`(t / 60).rounded() * 60`: half away from zero (epochs are positive)."""
    return math.floor(t / 60.0 + 0.5) * 60.0


# ---------------------------------------------------------------------------
# Cycles
# ---------------------------------------------------------------------------

@dataclass
class Cycle:
    """A cycle's readings (sorted by time) and its boundaries."""

    t: np.ndarray
    y: np.ndarray
    start: float
    reset: float

    @property
    def final(self) -> float:
        return float(self.y.max()) if len(self.y) else 0.0

    @property
    def period(self) -> float:
        """`EngineSelfEval.periodKeyRL`: the reset rounded to the minute."""
        return round_minute(self.reset)


class Partial:
    """`BurnTrajectory.PartialCycle`: the readings up to `now`, with the
    window's opening 0% prepended when the first reading came later (#311)."""

    __slots__ = ("t", "y", "h", "now", "start", "reset")

    def __init__(self, t: np.ndarray, y: np.ndarray, now: float, start: float, reset: float,
                 zero_anchor: bool = True):
        m = t <= now
        t, y = t[m], y[m]
        if zero_anchor and len(t) and t[0] > start + 1:
            t = np.concatenate(([start], t))
            y = np.concatenate(([0.0], y))
        self.t, self.y = t, y
        self.now, self.start, self.reset = float(now), float(start), float(reset)
        self.h = (t - start) / HOUR_S

    @property
    def duration_hours(self) -> float:
        return (self.reset - self.start) / HOUR_S

    @property
    def now_hours(self) -> float:
        return (self.now - self.start) / HOUR_S

    @property
    def used_now(self) -> float:
        return float(self.y[-1]) if len(self.y) else 0.0

    @property
    def cut_fraction(self) -> float:
        d = self.duration_hours
        return self.now_hours / d if d > 0 else 1.0


def post_reset_start(y: np.ndarray) -> int:
    """`postResetStartIndex`: index after the last in-cycle reset (a drop of
    ≥ 15 points landing at ≤ 5), else 0."""
    if len(y) < 2:
        return 0
    hits = np.nonzero(((y[:-1] - y[1:]) >= RESET_DROP_POINTS) & (y[1:] <= RESET_LOW_MAX))[0]
    return int(hits[-1] + 1) if len(hits) else 0


def segment_all(t: np.ndarray, y: np.ndarray, r: np.ndarray, duration: float) -> tuple[list[Cycle], int | None]:
    """Every reset group as a Cycle (sorted by start) and the index of the
    current one (the group with the latest minute-rounded reset). `t` must be
    sorted; `r` holds each reading's own reset (no nulls)."""
    if len(t) == 0:
        return [], None
    keys = np.floor(r / 60.0 + 0.5) * 60.0
    uniq, inv = np.unique(keys, return_inverse=True)
    order = np.argsort(inv, kind="stable")             # rows of each group, in time order
    bounds = np.searchsorted(inv[order], np.arange(len(uniq) + 1))
    cycles: list[tuple[float, Cycle]] = []
    for g in range(len(uniq)):
        idx = order[bounds[g]:bounds[g + 1]]
        gt, gy, gr = t[idx], y[idx], r[idx]
        split = post_reset_start(gy)
        kt, ky, kr = gt[split:], gy[split:], gr[split:]
        if len(kt) == 0:
            continue
        reset = float(kr.max())
        start = float(gt[split - 1]) if split > 0 else reset - duration
        cycles.append((float(uniq[g]), Cycle(kt, ky, start, reset)))
    cur_key = float(uniq[-1])
    cycles.sort(key=lambda kc: kc[1].start)
    cur = next((i for i, (k, _) in enumerate(cycles) if k == cur_key), None)
    return [c for _, c in cycles], cur


def segment(t: np.ndarray, y: np.ndarray, r: np.ndarray, duration: float, now: float,
            zero_anchor: bool = True) -> tuple[Partial | None, list[Cycle]]:
    """`BurnTrajectory.segment`: the current partial cycle at `now` and the
    other cycles (history, sorted by start)."""
    cycles, cur = segment_all(t, y, r, duration)
    if cur is None:
        return None, cycles
    c = cycles[cur]
    partial = Partial(c.t, c.y, now, c.start, c.reset, zero_anchor)
    return partial, cycles[:cur] + cycles[cur + 1:]


# ---------------------------------------------------------------------------
# The display rule
# ---------------------------------------------------------------------------

def anchor_shift(proj, c: Partial) -> float:
    return max(0.0, c.used_now - float(proj(c.now)))


def displayed_at_reset(proj, c: Partial) -> float:
    """`BurnTrajectory.displayedAtReset`: anchored to the live value (shift up
    only) and clamped to [usedNow, 100]."""
    return min(100.0, max(c.used_now, float(proj(c.reset)) + anchor_shift(proj, c)))


def displayed_path(proj, c: Partial, times: np.ndarray) -> np.ndarray:
    """The drawn trajectory at `times`: the anchored curve, floored at the live
    value and capped at 100 (`rateLimitTrajectories`), made non-decreasing."""
    a = anchor_shift(proj, c)
    v = np.minimum(100.0, np.maximum(c.used_now, np.asarray(proj(times), dtype=np.float64) + a))
    return np.maximum.accumulate(v) if len(v) else v


# ---------------------------------------------------------------------------
# Methods (BurnTrajectoryModels)
# ---------------------------------------------------------------------------

def _ls_line(x: np.ndarray, y: np.ndarray):
    n = float(len(x))
    sx, sy = float(x.sum()), float(y.sum())
    sxx, sxy = float((x * x).sum()), float((x * y).sum())
    det = n * sxx - sx * sx
    if abs(det) <= 1e-9:
        return None
    return (n * sxy - sx * sy) / det, (sy * sxx - sx * sxy) / det


def linear_recent(c: Partial, p: Params):
    cutoff = c.now_hours - c.duration_hours * p.linear_recent_lookback_fraction
    m = c.h >= cutoff
    x, y = (c.h[m], c.y[m]) if int(m.sum()) >= 2 else (c.h, c.y)
    if len(x) < 2:
        return None
    line = _ls_line(x, y)
    if line is None:
        return None
    slope, intercept = line
    start = c.start
    return lambda t: slope * ((np.asarray(t, dtype=np.float64) - start) / HOUR_S) + intercept


def recent_rate(c: Partial, p: Params):
    """`RecentRate` (#272): the meter's rise over the last hour (a day on
    weekly-scale windows), held from the latest reading."""
    if len(c.t) < 2:
        return None
    frm = c.now - (24 * HOUR_S if is_weekly_scale(c.reset - c.start) else HOUR_S)
    t0, u0 = c.start, 0.0
    if frm > c.start:
        k = int(np.searchsorted(c.t, frm, side="right")) - 1
        if k >= 0:
            t0, u0 = float(c.t[k]), float(c.y[k])
    last_t, last_u = float(c.t[-1]), float(c.y[-1])
    span = last_t - t0
    if span < 300:
        return None
    rate = max(0.0, (last_u - u0) / span)
    return lambda t: last_u + rate * (np.asarray(t, dtype=np.float64) - last_t)


def _det3(a, b, c, d, e, f, g, h, i):
    return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)


def _eps(*diag: float) -> float:
    s = sum(abs(v) for v in diag)
    return 1e-12 * max(1.0, s * s)


def _trend_fit(c: Partial, p: Params, *, min_samples: int, damping_tau_s: float, max_accel_frac: float):
    """`TrendEstimator.fit` + `projectedValue` (recency-weighted LS in
    half-life units, damped and clamped acceleration)."""
    half_life_h = c.duration_hours * p.recency_half_life_fraction
    if half_life_h <= 0:
        return None
    min_span = max(300.0, c.duration_hours * HOUR_S * 0.05)
    t, v = c.t, c.y
    if len(t) < min_samples or t[-1] - t[0] < min_span:
        return None
    u = ((t - c.now) / HOUR_S) / half_life_h
    w = np.power(2.0, u)
    u2 = u * u
    s0, s1, s2 = float(w.sum()), float((w * u).sum()), float((w * u2).sum())
    s3, s4 = float((w * u2 * u).sum()), float((w * u2 * u2).sum())
    t0, t1, t2 = float((w * v).sum()), float((w * v * u).sum()), float((w * v * u2).sum())
    det = s0 * s2 - s1 * s1
    if abs(det) <= _eps(s0, s2):
        return None
    level = (t0 * s2 - t1 * s1) / det
    slope_ph = ((s0 * t1 - s1 * t0) / det) / half_life_h
    accel = 0.0
    if len(np.unique(u)) >= 3:
        d = _det3(s0, s1, s2, s1, s2, s3, s2, s3, s4)
        if abs(d) > _eps(s0, s2, s4):
            cq = _det3(s0, s1, t0, s1, s2, t1, s2, s3, t2) / d
            accel = 2 * cq / (half_life_h * half_life_h)
    tau_h = damping_tau_s / HOUR_S
    if tau_h <= 0:
        accel_e = 0.0
    else:
        max_boost = max_accel_frac * abs(slope_ph)
        if math.isfinite(max_boost):
            cap = max_boost / tau_h
            accel_e = max(-cap, min(cap, accel))
        else:
            accel_e = accel
    now = c.now

    def project(tt):
        h = (np.asarray(tt, dtype=np.float64) - now) / HOUR_S
        lin = level + slope_ph * h
        if tau_h <= 0 or accel_e == 0:
            return lin
        return lin + accel_e * tau_h * (h - tau_h * (1 - np.exp(-h / tau_h)))

    return project


def recency_weighted(c: Partial, p: Params):
    return _trend_fit(c, p, min_samples=3, damping_tau_s=3600.0, max_accel_frac=0.0)


def damped_acceleration(c: Partial, p: Params):
    remaining = max(3600.0, c.reset - c.now)
    return _trend_fit(c, p, min_samples=4, damping_tau_s=remaining, max_accel_frac=1.0)


def _ceilings() -> np.ndarray:
    out, x = [], 1.05
    while x <= 2.5:            # the same float accumulation as the Swift loop
        out.append(x)
        x += 0.05
    return np.array(out)


CEILINGS = _ceilings()


def saturating(c: Partial, p: Params):
    """`Saturating`: L·(1 − e^(−k·s)), L on a grid of ceilings over the max,
    closed-form k per L, lowest original-space SSE (first on ties)."""
    s, y = c.h, c.y
    if len(s) < 3:
        return None
    y_max = float(y.max())
    if y_max <= 0:
        return None
    big_l = np.maximum(y_max * CEILINGS, y_max + 1)                    # [K]
    valid = (y[None, :] > 0) & (y[None, :] < big_l[:, None] * 0.999)  # [K, n]
    ratio = np.where(valid, y[None, :] / big_l[:, None], 0.0)
    z = np.where(valid, -np.log(1 - ratio), 0.0)
    sk = (s[None, :] * z).sum(axis=1)
    ss = np.where(valid, (s * s)[None, :], 0.0).sum(axis=1)
    ok = ss > 1e-9
    k = np.where(ok, sk / np.where(ok, ss, 1.0), 0.0)
    ok &= k > 0
    if not ok.any():
        return None
    pred = big_l[:, None] * (1 - np.exp(-k[:, None] * s[None, :]))
    sse = np.where(ok, ((pred - y[None, :]) ** 2).sum(axis=1), np.inf)
    i = int(np.argmin(sse))
    L, kk, start = float(big_l[i]), float(k[i]), c.start
    return lambda t: L * (1 - np.exp(-kk * ((np.asarray(t, dtype=np.float64) - start) / HOUR_S)))


def kalman_trend(c: Partial, p: Params):
    """`KalmanTrend`: local level + trend, constant-velocity transition,
    q = r = 0.5²; the filtered level carried forward at the filtered slope."""
    n = len(c.t)
    if n < 3:
        return None
    q = r = 0.25
    h = c.h.tolist()
    ys = c.y.tolist()
    level, slope = ys[0], 0.0
    p00, p01, p11 = 25.0, 0.0, 25.0
    last_t = h[0]
    for i in range(1, n):
        t = h[i]
        dt = max(1e-3, t - last_t)
        last_t = t
        level += slope * dt
        np00 = p00 + 2 * dt * p01 + dt * dt * p11 + q * dt * dt * dt / 3
        np01 = p01 + dt * p11 + q * dt * dt / 2
        np11 = p11 + q * dt
        innov = ys[i] - level
        denom = np00 + r
        if denom <= 1e-12:
            return None
        k0, k1 = np00 / denom, np01 / denom
        level += k0 * innov
        slope += k1 * innov
        p00, p01, p11 = (1 - k0) * np00, (1 - k0) * np01, np11 - k1 * np01
    if not (math.isfinite(level) and math.isfinite(slope)):
        return None
    anchor_h, start = last_t, c.start
    return lambda t: level + slope * ((np.asarray(t, dtype=np.float64) - start) / HOUR_S - anchor_h)


# ---------------------------------------------------------------------------
# Diurnal rate (DiurnalBurnModel)
# ---------------------------------------------------------------------------

MIN_OBSERVED_SHARE = 0.05
DIURNAL_STEP_S = 600.0


def normalized_prior(prior: np.ndarray | None) -> np.ndarray:
    if prior is None or np.shape(prior) != (7, 24):
        return np.ones((7, 24))
    m = float(np.mean(prior))
    return np.asarray(prior, dtype=np.float64) / m if m > 0 else np.ones((7, 24))


class DiurnalAccumulator:
    """The per-cell sums `DiurnalBurnModel.rateTable` folds over cycles,
    kept so a walk over cycles adds one cycle at a time."""

    def __init__(self, clock: LocalClock):
        self.clock = clock
        self.sums = np.zeros((7, 24))
        self.cnt = np.zeros((7, 24))

    def add(self, cyc: Cycle) -> None:
        t, y = cyc.t, cyc.y
        if len(t) < 2:
            return
        dt = np.diff(t)
        ok = dt > 0
        if not ok.any():
            return
        rate = np.maximum(0.0, np.diff(y))[ok] / dt[ok]
        mid = t[:-1][ok] + dt[ok] / 2
        wd, hr = self.clock.weekday_hour(mid)
        np.add.at(self.sums, (wd, hr), rate)
        np.add.at(self.cnt, (wd, hr), 1.0)

    def table(self, prior: np.ndarray | None, pseudocount: float = 6.0) -> np.ndarray:
        obs = np.zeros((7, 24))
        pop = self.cnt > 0
        obs[pop] = self.sums[pop] / self.cnt[pop]
        if pop.any():
            mean = float(obs[pop].mean())
            if mean > 0:
                obs = obs / mean
        w = self.cnt / (self.cnt + pseudocount)
        return w * np.where(pop, obs, 0.0) + (1 - w) * normalized_prior(prior)


def diurnal_rate_table(cycles: list[Cycle], prior: np.ndarray | None, clock: LocalClock,
                       pseudocount: float = 6.0) -> np.ndarray:
    """`DiurnalBurnModel.rateTable`: [7][24] relative accrual rates from the
    cycles' reading-to-reading rises, shrunk toward the activity prior."""
    acc = DiurnalAccumulator(clock)
    for cyc in cycles:
        acc.add(cyc)
    return acc.table(prior, pseudocount)


class Diurnal:
    """`DiurnalBurnModel` for one rate table."""

    def __init__(self, table: np.ndarray, clock: LocalClock, step: float = DIURNAL_STEP_S):
        self.table, self.clock, self.step = np.asarray(table, dtype=np.float64), clock, step

    def integrate(self, a: float, b: float) -> float:
        """∫ shape dt over [a, b] in fixed steps from `a`, each bucketed by its
        midpoint's (weekday, hour)."""
        if b <= a or self.step <= 0:
            return 0.0
        n = int(math.ceil((b - a) / self.step))
        ts = a + self.step * np.arange(n, dtype=np.float64)
        ts = ts[ts < b]
        dt = np.minimum(self.step, b - ts)
        wd, hr = self.clock.weekday_hour(ts + dt / 2)
        return float((self.table[wd, hr] * dt).sum())

    def __call__(self, c: Partial, p: Params):
        used = c.used_now
        if used <= 0:
            return None
        observed = self.integrate(c.start, c.now)
        if observed <= 0:
            return None
        full = self.integrate(c.start, c.reset)
        if full <= 0 or observed < full * MIN_OBSERVED_SHARE:
            return None
        level = used / observed
        origin, base, integ = c.now, used, self.integrate

        def project(t):
            if np.ndim(t) == 0:
                tt = float(t)
                return base + (level * integ(origin, tt) if tt > origin else 0.0)
            ta = np.asarray(t, dtype=np.float64)
            return np.array([base + (level * integ(origin, x) if x > origin else 0.0) for x in ta])

        return project


# ---------------------------------------------------------------------------
# Rosters
# ---------------------------------------------------------------------------

DEFAULT_FITS = {
    "linear-recent": linear_recent,
    "recency-weighted": recency_weighted,
    "damped-acceleration": damped_acceleration,
    "saturating": saturating,
    "kalman-trend": kalman_trend,
    "recent-rate": recent_rate,
}


def roster(diurnal: Diurnal | None, legacy: bool = False) -> dict:
    """The six default models, then the diurnal model when there is a table
    (in the app's order, which breaks full ties). The engine before #311 had
    no recent-rate."""
    out = {k: v for k, v in DEFAULT_FITS.items() if not (legacy and k == "recent-rate")}
    if diurnal is not None:
        out["diurnal-rate"] = diurnal
    return out
