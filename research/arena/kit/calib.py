"""The calibration layer: one child's meter forecasts, with their spread
recalibrated around the child's own median, learned only from the child's
own out-of-sample past.

**What it learns from.** The child's forecasts over the parent's past
(`ctx.backtest`: each made by a fresh fit at its origin, without seeing what
followed), plus the child's forecasts during this episode, each scored on the
readings known *now* that came after its origin, in its cycle, up to its
reset (the scorer's truth, as far as it has arrived). Each stored forecast is
kept as its quantiles at `M_LEVELS` levels per grid time, with its lowest
value (where `apply` clips) and whether its values were whole points (then
`apply` rounds); a *record* is one truth reading: the forecast's quantiles
read at that reading's time (linear along the grid, like the scorer), the
reading, and its lead. At most `per_bin` readings per forecast and lead bin,
evenly spaced, so a forecast polled every few seconds does not drown the rest.

**What it learns**, per window kind (five-hour, seven-day, each scoped cap)
and lead bin (`LEAD_BINS`), each forecast origin counting once per bin:

- `scale` (the default): s(c), the factor on every path's deviation from the
  median at which the child's central c-range would have covered c of the
  truths, at c = 0.5, 0.8, 0.95 (`KNOTS`; piecewise linear in c between
  them, flat outside). Coverage is the scorer's randomized one (a tie's PIT
  spread uniformly over it), measured after the clip and rounding `apply`
  does, so an idle forecast flat at the reading whose truth sits on it counts
  as calibrated at every level instead of pulling the scale to 0. A forecast
  that is a single point and missed cannot be fixed by scaling and is left
  out of this fit.
- `crps`: one factor per bin minimizing the records' CRPS instead.
- `pit`: the child's own level on each side of the median whose range covers
  c of the truths (an isotonic remap of the child's randomized PIT, the
  median keeping its level); `both`: `scale`, then `pit` on the scaled records.

On the visible tier's last weeks `scale` beat the others: `pit` and `both`
cannot widen past the child's own range and chase its recent skew, and a
two-sided scale (separate factors below and above the median) chased its
recent bias; both cost CRPS on the days after (see `fit_scale`).

**Shrinkage.** A bin's estimate is pulled toward the kind's pooled estimate
by n_bin / (n_bin + n0_bin), and the pooled one toward "no change" (s = 1,
h(c) = c) by n / (n + n0), n counting forecast origins (scale in log space).
Fewer than `min_origins` origins: no change at all. Between lead bins the
parameters are interpolated in log-lead between the bins' centres.

**How it applies** to the child's paths [n, G], column by column (each grid
time): each path keeps its rank, its central level is c = |2r - 1| (r its
mid-rank level, ties averaged), and its new value is the child's distribution
read through the map; the column is rearranged so levels never cross and
shifted so its median is exactly the child's; every path is made
non-decreasing in time (least squares, pool adjacent violators) when every
child path was; rounded to whole points when every child value was
(`round`); clipped to [the child's lowest value, max(100, the child's
highest)]. The median path is unchanged up to that rounding and repair.

The same functions apply to quantile curves (`apply` on a comonotone set of
curves, e.g. a child's exact quantiles at (i + 0.5)/200), which is how
`kit.detq` gives this layer a deterministic entry point.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass

import numpy as np

from arena.snapshot.cycles import MeterIndex
from arena.types import Forecast, Target, TargetForecast

MIN_MS = 60_000
HOUR_MS = 3_600_000
METER = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}
METHODS = ("scale", "crps", "pit", "both")
KNOTS = np.array([0.5, 0.8, 0.95])            # the central coverages fitted (cover50, cover80, cover95)
M_LEVELS = 40                                 # a stored forecast: its quantiles at (i + 0.5) / 40 per grid time
S_MAX = 3.0                                   # scale factors live in [1 / S_MAX, S_MAX]
EPS = 1e-6                                    # a reading "equals" a quantile within this
H_GRID = np.linspace(0.0, 1.0, 401)           # where H (folded-PIT CDF) is evaluated
# Lead bins, seconds: (upper edges, centres). Centres are the geometric middles
# of each bin (the first from 1 min), rounded; parameters are interpolated in
# log-lead between centres and held flat beyond the first and last.
LEAD_BINS = {
    "five_hour": ((1800.0, 7200.0, np.inf), (300.0, 3600.0, 11400.0)),
    "weekly": ((7200.0, 86400.0, 259200.0, np.inf), (600.0, 25200.0, 151200.0, 396000.0)),
}
DEFAULTS = {
    "method": "scale",
    "n0": 8.0,                 # origins at which the pooled fit gets half its weight
    "n0_bin": 8.0,             # origins at which a lead bin's own fit gets half its weight
    "min_origins": 3,
    "s_max": S_MAX,            # scale factors stay in [1 / s_max, s_max]
    "per_bin": 8,              # truth readings per forecast and lead bin
    "round": True,             # whole points when the child's paths are whole
    "backtest": True,
    "backtest_every_h": {"five_hour": 2, "seven_day": 8, "weekly_scoped": 8},
    "backtest_n": {"five_hour": 24, "seven_day": 24, "weekly_scoped": 24},
}


def window_of(kind: str) -> str:
    return kind.split(":")[0]


def bins_of(kind: str) -> tuple[tuple[float, ...], tuple[float, ...]]:
    return LEAD_BINS["five_hour" if window_of(kind) == "five_hour" else "weekly"]


def kind_of(target: Target, cap: str | None) -> str | None:
    w = METER.get(target)
    if w is None:
        return None
    return f"{w}:{cap}" if w == "weekly_scoped" else w


# ---------------------------------------------------------------------------
# Small exact pieces (each written to be restated line for line elsewhere)
# ---------------------------------------------------------------------------

def level_grid(m: int) -> np.ndarray:
    return (np.arange(m) + 0.5) / m


def sorted_levels(paths: np.ndarray, m: int = M_LEVELS) -> np.ndarray:
    """[m, G]: per grid time, the paths' values at levels (i + 0.5) / m
    (`read_sorted` of the sorted column)."""
    P = np.sort(np.asarray(paths, dtype=np.float64), axis=0)
    if P.shape[0] == m:
        return P
    return read_sorted(P, level_grid(m))


def read_sorted(S: np.ndarray, levels) -> np.ndarray:
    """Values of sorted samples S [n, ...] at `levels`: position level * n - 0.5,
    linear between order statistics, clamped to the ends. [len(levels), ...]."""
    S = np.asarray(S, dtype=np.float64)
    n = S.shape[0]
    pos = np.clip(np.asarray(levels, dtype=np.float64) * n - 0.5, 0.0, n - 1.0)
    i0 = np.floor(pos).astype(np.int64)
    i1 = np.minimum(i0 + 1, n - 1)
    a = (pos - i0).reshape((-1,) + (1,) * (S.ndim - 1))
    return S[i0] * (1.0 - a) + S[i1] * a


def piecewise(x_knots, y_knots, x):
    """Linear between knots, flat outside (np.interp)."""
    return np.interp(x, x_knots, y_knots)


def weighted_mean(v: np.ndarray, w: np.ndarray) -> float:
    return float((v * w).sum() / w.sum()) if w.sum() > 0 else float("nan")


def tie_interval(q: np.ndarray, y: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """(F(y-), F(y)) of each record's samples q [N, m] at its reading y [N]."""
    y = np.asarray(y, dtype=np.float64)[:, None]
    return (q < y - EPS).mean(axis=1), (q <= y + EPS).mean(axis=1)


def below_share(flo: np.ndarray, fhi: np.ndarray, x) -> np.ndarray:
    """[N, len(x)]: the randomized PIT's chance of falling at or below x: the
    share of its tie interval [flo, fhi] below x (the scorer spreads a tie's
    PIT uniformly over it); for a point PIT, whether it is <= x."""
    x = np.atleast_1d(np.asarray(x, dtype=np.float64))[None, :]
    flo, fhi = flo[:, None], fhi[:, None]
    width = fhi - flo
    part = np.clip(np.minimum(fhi, x) - flo, 0.0, None)
    point = (flo <= x + 1e-12).astype(np.float64)
    return np.where(width > 1e-12, part / np.where(width > 1e-12, width, 1.0), point)


def coverage(flo: np.ndarray, fhi: np.ndarray, x) -> np.ndarray:
    """Randomized coverage [N, len(x)] of the central x-range [(1 - x)/2, (1 + x)/2]."""
    x = np.atleast_1d(np.asarray(x, dtype=np.float64))
    return below_share(flo, fhi, (1.0 + x) / 2.0) - below_share(flo, fhi, (1.0 - x) / 2.0)


def origin_weights(origin: np.ndarray) -> np.ndarray:
    """Each origin's records share a total weight of 1."""
    _, inv, cnt = np.unique(origin, return_inverse=True, return_counts=True)
    return 1.0 / cnt[inv]


def finish(V: np.ndarray, floor, whole) -> np.ndarray:
    """What `apply` does to new values after the map, per record: clip to
    [floor, 100] (floor [N]) and round where the child's values were whole
    (whole [N] bool)."""
    V = np.clip(V, np.asarray(floor, dtype=np.float64)[:, None], 100.0)
    w = np.asarray(whole, dtype=bool)
    if w.any():
        V = np.where(w[:, None], np.rint(V), V)
    return V


def scale_samples(q: np.ndarray, s) -> np.ndarray:
    """Records' samples [N, m] with their deviations from the median scaled
    by s (a scalar, or [N, m])."""
    med = read_sorted(q.T, [0.5])[0][:, None]
    return med + s * (q - med)


def fit_scale(q: np.ndarray, y: np.ndarray, w: np.ndarray, floor, whole, s_max: float = S_MAX) -> np.ndarray:
    """Scale factors at KNOTS: for knot c, the s in [1/s_max, s_max] at
    which the weighted chance that the reading falls outside the new central
    c-range is 1 - c. The records' samples are scaled around their median by
    s (both sides alike), clipped and rounded as `apply` would (`finish`),
    and the chance read from the randomized PIT. It only falls as s grows:
    bisection in log s, 40 halvings, the smallest s that reaches the target
    (the nearer bound when none does).

    Both sides alike on purpose: separate lower and upper factors fitted
    this way chased the child's recent bias (a spread-only map cannot move
    the median, so a few days of forecasts that ran high taught it a huge
    lower tail) and cost up to a fifth of the CRPS on the next days."""
    out = np.ones(len(KNOTS))
    if not len(y) or w.sum() <= 0:
        return out

    def miss(s: float, c: float) -> float:
        flo, fhi = tie_interval(finish(scale_samples(q, s), floor, whole), y)
        v = below_share(flo, fhi, (1.0 - c) / 2.0)[:, 0] + 1.0 - below_share(flo, fhi, (1.0 + c) / 2.0)[:, 0]
        return weighted_mean(v, w)

    lo0, hi0 = -np.log(s_max), np.log(s_max)
    for k, c in enumerate(KNOTS):
        target = 1.0 - c
        if miss(np.exp(hi0), c) > target:
            out[k] = s_max
            continue
        if miss(np.exp(lo0), c) <= target:
            out[k] = 1.0 / s_max
            continue
        lo, hi = lo0, hi0
        for _ in range(40):
            mid = 0.5 * (lo + hi)
            if miss(np.exp(mid), c) <= target:
                hi = mid
            else:
                lo = mid
        out[k] = float(np.exp(hi))
    return out


def crps_samples(Q: np.ndarray, y: np.ndarray) -> np.ndarray:
    """[N]: the CRPS of each record's equally weighted samples Q [N, m] at y."""
    Q = np.sort(Q, axis=1)
    m = Q.shape[1]
    a = np.abs(Q - y[:, None]).mean(axis=1)
    wts = (2 * np.arange(1, m + 1) - m - 1) / (m * m)
    return a - (Q * wts[None, :]).sum(axis=1)


def fit_scale_crps(q: np.ndarray, y: np.ndarray, w: np.ndarray, floor, whole, s_max: float = S_MAX) -> np.ndarray:
    """One scale for both sides and every level: the s in [1/s_max, s_max]
    minimizing the weighted mean CRPS of the records' samples so scaled
    (clipped and rounded as `apply` would), on a grid of 41 values in log s."""
    if not len(y) or w.sum() <= 0:
        return np.ones(len(KNOTS))
    grid = np.exp(np.linspace(-np.log(s_max), np.log(s_max), 41))
    loss = [weighted_mean(crps_samples(finish(scale_samples(q, s), floor, whole), y), w) for s in grid]
    return np.full(len(KNOTS), float(grid[int(np.argmin(loss))]))


def fit_pit_sides(q: np.ndarray, y: np.ndarray, w: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """(h_lo, h_hi) at KNOTS: G(x) = the weighted chance that the reading's
    randomized PIT is <= x, on H_GRID (made non-decreasing); the child's
    lower level a' = the first x with G(x) >= (1 - c)/2 (linear between grid
    points), h_lo(c) = 1 - 2 min(a', 1/2); the upper b' at (1 + c)/2,
    h_hi(c) = 2 max(b', 1/2) - 1. The new quantile at a level α below 1/2 is
    the child's at 1/2 - h_lo(1 - 2α)/2, and above the median likewise."""
    if not len(y) or w.sum() <= 0:
        return KNOTS.copy(), KNOTS.copy()
    flo, fhi = tie_interval(q, y)
    G = np.maximum.accumulate((below_share(flo, fhi, H_GRID) * w[:, None]).sum(axis=0) / w.sum())

    def inv(level: float) -> float:
        j = int(np.searchsorted(G, level - 1e-12, side="left"))
        if j <= 0:
            return 0.0
        if j >= len(H_GRID):
            return 1.0
        g0, g1 = G[j - 1], G[j]
        a = (level - g0) / (g1 - g0) if g1 > g0 else 1.0
        return float(H_GRID[j - 1] + a * (H_GRID[j] - H_GRID[j - 1]))
    h_lo = np.array([1.0 - 2.0 * min(inv((1.0 - c) / 2.0), 0.5) for c in KNOTS])
    h_hi = np.array([2.0 * max(inv((1.0 + c) / 2.0), 0.5) - 1.0 for c in KNOTS])
    return h_lo, h_hi


# ---------------------------------------------------------------------------
# A kind's fit
# ---------------------------------------------------------------------------

SIDES = ("s", "h_lo", "h_hi")


@dataclass
class KindFit:
    """The learned map of one window kind: per lead bin, the scale of the
    deviations from the median at KNOTS and the child's level on each side
    of the median at KNOTS ("no change": s = 1, h = c), and how many
    forecast origins each rests on."""

    kind: str
    method: str
    centers_s: list[float]
    s: list[list[float]]           # [bins][3]
    h_lo: list[list[float]]
    h_hi: list[list[float]]
    n_bin: list[int]
    n: int

    @classmethod
    def identity(cls, kind: str, method: str, n: int = 0) -> "KindFit":
        _, centers = bins_of(kind)
        b = len(centers)
        def ones():
            return [[1.0] * 3 for _ in range(b)]

        def knots():
            return [list(map(float, KNOTS)) for _ in range(b)]
        return cls(kind, method, list(centers), ones(), knots(), knots(), [0] * b, n)

    def to_json(self) -> dict:
        return asdict(self)

    @classmethod
    def from_json(cls, d: dict) -> "KindFit":
        return cls(**d)

    def at(self, lead_s) -> dict[str, np.ndarray]:
        """Each of SIDES as [L, 3] at leads (seconds): linear in log-lead
        between the bins' centres (scales in log), flat beyond."""
        x = np.log(np.maximum(np.asarray(lead_s, dtype=np.float64), 1.0))
        xc = np.log(np.asarray(self.centers_s, dtype=np.float64))
        out = {}
        for name in SIDES:
            A = np.asarray(getattr(self, name), dtype=np.float64)
            if name.startswith("s"):
                out[name] = np.stack([np.exp(np.interp(x, xc, np.log(A[:, k]))) for k in range(3)], axis=1)
            else:
                out[name] = np.stack([np.interp(x, xc, A[:, k]) for k in range(3)], axis=1)
        return out

    def is_identity(self) -> bool:
        return (np.allclose(self.s, 1.0) and np.allclose(self.h_lo, KNOTS[None, :])
                and np.allclose(self.h_hi, KNOTS[None, :]))


def lead_bin(kind: str, lead_s: np.ndarray) -> np.ndarray:
    edges, _ = bins_of(kind)
    return np.searchsorted(np.asarray(edges[:-1]), np.asarray(lead_s, dtype=np.float64), side="left")


def _shrink_log(raw: np.ndarray, toward: np.ndarray, lam: float) -> np.ndarray:
    return np.exp(lam * np.log(raw) + (1.0 - lam) * np.log(toward))


def _monotone_h(h: np.ndarray) -> np.ndarray:
    return np.maximum.accumulate(np.clip(h, 0.0, 1.0))


def fit_kind(kind: str, q: np.ndarray, y: np.ndarray, lead_s: np.ndarray, origin: np.ndarray,
             method: str = "scale", n0: float = 6.0, n0_bin: float = 6.0, min_origins: int = 3,
             floor=None, whole=None, s_max: float = S_MAX) -> KindFit:
    """Fit one kind's map from its records: q [N, m] sorted samples at each
    reading, y [N] readings, lead_s [N], origin [N] (any id per forecast),
    floor [N] (the child's lowest value in that forecast, where `apply`
    clips) and whole [N] (the child's values were whole points, so `apply`
    rounds)."""
    if method not in METHODS:
        raise ValueError(f"unknown calibration method {method!r}; one of {METHODS}")
    _, centers = bins_of(kind)
    nb = len(centers)
    floor = np.full(len(y), -np.inf) if floor is None else np.asarray(floor, dtype=np.float64)
    whole = np.zeros(len(y), dtype=bool) if whole is None else np.asarray(whole, dtype=bool)
    n = len(np.unique(origin)) if len(origin) else 0
    fit = KindFit.identity(kind, method, n)
    if n < min_origins:
        return fit
    b = lead_bin(kind, lead_s)
    fit.n_bin = [int(len(np.unique(origin[b == j]))) for j in range(nb)]
    lam = n / (n + n0)
    if method in ("scale", "crps", "both"):
        spread = q[:, -1] - q[:, 0]
        med = read_sorted(q.T, [0.5])[0]
        ok = (spread > EPS) | (np.abs(y - med) <= EPS)     # a single point that missed: no scale fixes it
        fn = fit_scale_crps if method == "crps" else fit_scale

        def raw(m):
            return fn(q[m], y[m], origin_weights(origin[m]), floor[m], whole[m], s_max)
        pooled = _shrink_log(raw(ok), np.ones(3), lam) if ok.any() else np.ones(3)
        rows = []
        for j in range(nb):
            m = ok & (b == j)
            nj = len(np.unique(origin[m])) if m.any() else 0
            rows.append((_shrink_log(raw(m), pooled, nj / (nj + n0_bin)) if nj else pooled).tolist())
        fit.s = rows
    if method in ("pit", "both"):
        qq = q
        if method == "both":
            at = fit.at(lead_s)
            c = np.abs(2.0 * level_grid(q.shape[1]) - 1.0)
            sc = np.stack([piecewise(KNOTS, row, c) for row in at["s"]])
            qq = np.sort(finish(scale_samples(q, sc), floor, whole), axis=1)
        p_lo, p_hi = fit_pit_sides(qq, y, origin_weights(origin))
        pooled = {"lo": _monotone_h(lam * p_lo + (1.0 - lam) * KNOTS),
                  "hi": _monotone_h(lam * p_hi + (1.0 - lam) * KNOTS)}
        rows = {"lo": [], "hi": []}
        for j in range(nb):
            m = b == j
            nj = fit.n_bin[j]
            if nj == 0:
                for side in rows:
                    rows[side].append(pooled[side].tolist())
                continue
            r_lo, r_hi = fit_pit_sides(qq[m], y[m], origin_weights(origin[m]))
            lj = nj / (nj + n0_bin)
            rows["lo"].append(_monotone_h(lj * r_lo + (1.0 - lj) * pooled["lo"]).tolist())
            rows["hi"].append(_monotone_h(lj * r_hi + (1.0 - lj) * pooled["hi"]).tolist())
        fit.h_lo, fit.h_hi = rows["lo"], rows["hi"]
    return fit


# ---------------------------------------------------------------------------
# Applying a fit to paths (or to a comonotone set of quantile curves)
# ---------------------------------------------------------------------------

def mid_ranks(P: np.ndarray) -> np.ndarray:
    """[n, G] mid-rank level of each value in its column, ties averaged:
    (average 1-based rank - 0.5) / n."""
    from scipy.stats import rankdata
    return (rankdata(P, method="average", axis=0) - 0.5) / P.shape[0]


def monotone_paths(P: np.ndarray) -> np.ndarray:
    """Each path's closest non-decreasing path (least squares), only where it falls."""
    bad = (np.diff(P, axis=1) < -1e-12).any(axis=1)
    if not bad.any():
        return P
    from scipy.optimize import isotonic_regression
    out = P.copy()
    for i in np.flatnonzero(bad):
        out[i] = isotonic_regression(P[i]).x
    return out


def apply(fit: KindFit | None, paths: np.ndarray, grid: np.ndarray, now: int, *,
          round_whole: bool = True, cap: float = 100.0) -> np.ndarray:
    """The child's paths [n, G] recalibrated by `fit` (None or identity: unchanged)."""
    P = np.asarray(paths, dtype=np.float64)
    if fit is None or fit.is_identity() or P.ndim != 2 or P.shape[0] < 2:
        return P
    n, G = P.shape
    lead = (np.asarray(grid, dtype=np.float64) - float(now)) / 1000.0
    k = fit.at(lead)                                                   # each [G, 3]
    r = mid_ranks(P)
    c = np.abs(2.0 * r - 1.0)
    below = r < 0.5
    order = np.argsort(P, axis=0, kind="stable")
    V = P
    if fit.method in ("scale", "crps", "both"):
        med = np.median(P, axis=0)
        s = np.stack([piecewise(KNOTS, k["s"][j], c[:, j]) for j in range(G)], axis=1)
        V = med[None, :] + s * (P - med[None, :])
        # rearrange: the j-th smallest child value gets the j-th smallest new one
        V = _rearrange(V, order)
    if fit.method in ("pit", "both"):
        S = np.sort(V, axis=0)
        xk = np.concatenate([[0.0], KNOTS, [1.0]])

        def hcurve(name, j):
            return np.interp(c[:, j], xk, np.concatenate([[0.0], k[name][j], [1.0]]))
        hc = np.stack([np.where(below[:, j], hcurve("h_lo", j), hcurve("h_hi", j)) for j in range(G)], axis=1)
        beta = 0.5 + np.sign(r - 0.5) * hc / 2.0
        V = np.stack([read_sorted(S[:, j], beta[:, j]) for j in range(G)], axis=1)
    # The two middle paths sit either side of the median, so each side's map
    # moves them (by a hair: their central level is 1/n); shift the column so
    # the median path is exactly the child's.
    V = V + (np.median(P, axis=0) - np.median(V, axis=0))[None, :]
    if (np.diff(P, axis=1) >= -1e-12).all():
        V = monotone_paths(V)
    if round_whole and np.all(np.abs(P - np.rint(P)) < 1e-9):
        V = np.rint(V)
    return np.clip(V, P.min(), max(cap, float(P.max())))


def _rearrange(V: np.ndarray, order: np.ndarray) -> np.ndarray:
    out = np.empty_like(V)
    S = np.sort(V, axis=0)
    cols = np.arange(V.shape[1])[None, :]
    out[order, cols] = S
    return out


# ---------------------------------------------------------------------------
# Stored forecasts and their records
# ---------------------------------------------------------------------------

@dataclass
class Stored:
    origin: int
    key: str
    kind: str
    account: str
    window: str
    cap: str | None
    reset: int
    grid: np.ndarray
    q: np.ndarray                  # [M_LEVELS, G] float32
    floor: float                   # the child's lowest value in this forecast (`apply` clips there)
    whole: bool                    # every value a whole point (`apply` rounds)
    final: bool = False
    rec: tuple | None = None       # (q, y, lead) cached once final


class Store:
    """The child's forecasts seen so far (backtests and this episode's own),
    and the records they give against the readings known at a moment."""

    def __init__(self, per_bin: int = 8):
        self.per_bin = per_bin
        self.items: dict[tuple[int, str], Stored] = {}

    def add(self, request, forecast: Forecast) -> int:
        added = 0
        for tr in request.targets:
            kind = kind_of(tr.target, tr.cap)
            tf = forecast.by_key.get(tr.key)
            if kind is None or tf is None or tr.reset_at is None:
                continue
            p = np.asarray(tf.paths, dtype=np.float64)
            if p.ndim != 2 or p.shape[1] != len(tr.grid) or not np.isfinite(p).all():
                continue
            self.items[(int(request.now), tr.key)] = Stored(
                int(request.now), tr.key, kind, tr.accounts[0], METER[tr.target], tr.cap, int(tr.reset_at),
                np.asarray(tr.grid, dtype=np.int64), sorted_levels(p).astype(np.float32), float(p.min()),
                bool(np.all(np.abs(p - np.rint(p)) < 1e-9)))
            added += 1
        return added

    def records(self, meters: "MeterSource", now: int) -> dict[str, tuple[np.ndarray, ...]]:
        """{kind: (q [N, m], y [N], lead_s [N], origin [N], floor [N], whole [N])}
        from every stored forecast made before now, against readings known at now."""
        acc: dict[str, list] = {}
        for st in self.items.values():
            if st.origin >= now:
                continue
            if st.final and st.rec is not None:
                rec = st.rec
            else:
                idx = meters.get(st.account, st.window, st.cap)
                if idx is None:
                    continue
                times, vals = idx.truth(st.origin, now, st.reset)
                keep = times <= st.grid[-1]
                times, vals = times[keep], vals[keep]
                rec = self._select(st, times, vals)
                st.final = st.reset <= now - 10 * MIN_MS
                st.rec = rec if st.final else None
            if rec is None:
                continue
            k = len(rec[1])
            acc.setdefault(st.kind, []).append((*rec, np.full(k, st.origin, dtype=np.int64),
                                                np.full(k, st.floor), np.full(k, st.whole)))
        out = {}
        for kind, parts in acc.items():
            out[kind] = tuple(np.concatenate([p[i] for p in parts]) for i in range(6))
        return out

    def _select(self, st: Stored, times: np.ndarray, vals: np.ndarray):
        if not len(times):
            return None
        lead = (times - st.origin) / 1000.0
        b = lead_bin(st.kind, lead)
        pick = []
        for j in np.unique(b):
            ix = np.flatnonzero(b == j)
            if len(ix) > self.per_bin:
                ix = ix[np.unique(np.linspace(0, len(ix) - 1, self.per_bin).round().astype(np.int64))]
            pick.append(ix)
        ix = np.sort(np.concatenate(pick))
        g = st.grid.astype(np.float64)
        t = times[ix].astype(np.float64)
        Q = st.q.astype(np.float64)                                    # [m, G]
        q = np.stack([np.interp(t, g, row) for row in Q], axis=1)      # [N, m], rows stay sorted
        return q, vals[ix].astype(np.float64), lead[ix]


class MeterSource:
    """As-of meter indexes from one history (rebuilt when the history moves on)."""

    def __init__(self, history):
        self.readings = history.table("meter_readings")
        self._idx: dict = {}

    def get(self, account: str, window: str, cap: str | None) -> MeterIndex | None:
        k = (account, window, cap)
        if k not in self._idx:
            idx = MeterIndex.from_readings(self.readings, account, window, cap) if self.readings.height else None
            self._idx[k] = idx if idx is not None and len(idx) else None
        return self._idx[k]


def fit_all(records: dict[str, tuple[np.ndarray, ...]], cfg: dict) -> dict[str, KindFit]:
    method = str(cfg.get("method", DEFAULTS["method"]))
    out = {}
    for kind, (q, y, lead, origin, floor, whole) in records.items():
        out[kind] = fit_kind(kind, q, y, lead, origin, method, float(cfg.get("n0", DEFAULTS["n0"])),
                             float(cfg.get("n0_bin", DEFAULTS["n0_bin"])),
                             int(cfg.get("min_origins", DEFAULTS["min_origins"])), floor, whole,
                             float(cfg.get("s_max", DEFAULTS["s_max"])))
    return out


# ---------------------------------------------------------------------------
# The wrapper model
# ---------------------------------------------------------------------------

class CalibModel:
    """Duck-typed arena model over ONE child (model.toml `children`, or
    config `child`). Meter targets come back recalibrated; anything else the
    child answers passes through unchanged. Config: DEFAULTS."""

    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = {**DEFAULTS, **dict(ctx.config)}
        kids = [str(c) for c in (getattr(ctx, "children", ()) or ())]
        self.child = str(self.cfg.get("child") or (kids[0] if kids else ""))
        if not self.child:
            raise ValueError("a calibration wrapper needs one child (model.toml `children`)")
        if self.cfg["method"] not in METHODS:
            raise ValueError(f"unknown calibration method {self.cfg['method']!r}; one of {METHODS}")
        self.store = Store(int(self.cfg["per_bin"]))
        self.history = None
        self.meters: MeterSource | None = None
        self.fits: dict[str, KindFit] = {}

    # contract ------------------------------------------------------------
    def fit(self, history):
        self.history = history
        self.meters = MeterSource(history)
        if not self.cfg.get("backtest", True):
            return
        now = int(history.now)
        for every, targets, n in self.backtest_plan():
            # On a fixed lattice, so a child's backtest forecasts are shared
            # (child cache) by episodes on the same view.
            since = (now - n * every) // every * every
            try:
                items = self.ctx.backtest(self.child, every=every, targets=targets, since=since)
            except Exception as e:  # noqa: BLE001 - no backtest: the layer starts as "no change"
                self.ctx.log(f"backtest {self.child}: {type(e).__name__}: {str(e)[:200]}")
                continue
            added = sum(self.store.add(req, fc) for req, fc in items)
            self.ctx.log(f"backtest {self.child} every {every / HOUR_MS:g}h: {len(items)} origins, {added} forecasts")

    def update(self, events):
        self.history = self.history.extend(events)
        self.meters = MeterSource(self.history)

    def forecast(self, request):
        fc = self.ctx.model(self.child).forecast(request)
        now = int(request.now)
        self.fits = self.calibrate(now)
        self.store.add(request, fc)
        out = {}
        for tr in request.targets:
            tf = fc.by_key.get(tr.key)
            if tf is None:
                continue
            kind = kind_of(tr.target, tr.cap)
            if kind is None:
                out[tr.key] = tf
                continue
            out[tr.key] = TargetForecast(self.apply(kind, tf.paths, tr.grid, now), dict(tf.extras or {}))
        return Forecast(out)

    # pieces --------------------------------------------------------------
    def calibrate(self, now: int) -> dict[str, KindFit]:
        recs = self.store.records(self.meters, now) if self.meters is not None else {}
        fits = fit_all(recs, self.cfg)
        for kind, f in sorted(fits.items()):
            self.ctx.log(f"calib {kind} @{now}: n={f.n} bins={f.n_bin} "
                         + " ".join(f"{k}={np.round(np.asarray(getattr(f, k)), 3).tolist()}" for k in SIDES))
        return fits

    def apply(self, kind: str, paths: np.ndarray, grid: np.ndarray, now: int) -> np.ndarray:
        return apply(self.fits.get(kind), paths, grid, now, round_whole=bool(self.cfg.get("round", True)))

    def backtest_plan(self) -> list[tuple[int, tuple[Target, ...], int]]:
        """(every, targets, origins) per backtest call; windows sharing a
        cadence share a call."""
        every_h = self.cfg.get("backtest_every_h", DEFAULTS["backtest_every_h"])
        n_by = self.cfg.get("backtest_n", DEFAULTS["backtest_n"])
        by: dict[int, tuple[list[Target], int]] = {}
        for t, w in METER.items():
            if w not in every_h:
                continue
            every = int(float(every_h[w]) * HOUR_MS)
            n = int(n_by.get(w, 24) if isinstance(n_by, dict) else n_by)
            ts, nn = by.get(every, ([], 0))
            by[every] = (ts + [t], max(nn, n))
        return [(e, tuple(ts), n) for e, (ts, n) in sorted(by.items())]
