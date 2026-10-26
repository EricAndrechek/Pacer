"""The engine's self-evaluation and bands: ports of `EngineSelfEval`
(newOutcomesRL, bestMethod, phaseErrors, typicalError), the stand-in rule
(`UsageIntelligenceEngine.resolveModel`), the cold-start backtest
(`BurnTrajectory.score` + `ForecastSelector.select`) and the stratified
additive conformal calibrators (`stratifiedRLCalibrators`,
`ConformalCalibrator`).

A `Record` is one (account, window)'s track record: every method's displayed
value at each cut of each completed cycle, the v2 `EngineEvalOutcome` rows.
Each cycle is scored once, when first seen complete, as the app does; rows
are never re-scored.
"""
from __future__ import annotations

import math

import numpy as np

from kit.engine.clock import LocalClock
from kit.engine.core import (
    COMPLEXITY, DEFAULT_FITS, RL_CUT_FRACTIONS, Cycle, Diurnal, DiurnalAccumulator, Partial,
    displayed_at_reset,
)
from kit.engine.params import Params

COLD_CUTS = (0.5, 0.6, 0.7)            # BurnTrajectory.score's cuts


class Record:
    def __init__(self) -> None:
        self.rows: dict[str, dict[float, dict[float, float]]] = {}   # method -> period -> cut -> predicted
        self.truth: dict[float, float] = {}                           # period -> realized final
        self.scored: set[float] = set()

    def add(self, method: str, period: float, cut: float, predicted: float) -> None:
        self.rows.setdefault(method, {}).setdefault(period, {})[cut] = predicted

    def errors(self, method: str, phase: str | None = None, recency: int = 0) -> np.ndarray:
        """|predicted − truth| for `phase`'s cuts (every cut when None), over
        the last `recency` scored periods when set."""
        per = self.rows.get(method, {})
        periods = sorted(per)
        if recency:
            periods = periods[-recency:]
        out = [abs(pred - self.truth[p]) for p in periods for cf, pred in per[p].items()
               if phase is None or phase_of(cf) == phase]
        return np.asarray(out, dtype=np.float64)

    def n_periods(self, method: str) -> int:
        return len(self.rows.get(method, {}))


def phase_of(cut_fraction: float) -> str:
    """`EngineSelfEval.SelectionPhase`: early before half the window."""
    return "early" if cut_fraction < 0.5 else "late"


def typical(errs: np.ndarray, weekly: bool) -> float:
    """`typicalError`: the median, the mean on weekly-scale windows."""
    if len(errs) == 0:
        return math.inf
    if weekly:
        return float(np.mean(errs))
    s = np.sort(errs)
    n = len(s)
    return float(s[n // 2]) if n % 2 else float((s[n // 2 - 1] + s[n // 2]) / 2)


def median(xs) -> float:
    xs = sorted(xs)
    n = len(xs)
    if n == 0:
        return math.inf
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


# ---------------------------------------------------------------------------
# Scoring completed cycles (newOutcomesRL)
# ---------------------------------------------------------------------------

def score_cycles(record: Record, cycles: list[Cycle], params: Params, *, clock: LocalClock,
                 prior: np.ndarray | None, methods: tuple[str, ...], now: float) -> int:
    """Score every cycle in `cycles` (sorted by start) that has reset by `now`
    and is not yet in the record. The diurnal model scored on cycle i learns
    from the list's cycles before i, as `newOutcomesRL` does (the full history
    for the launch backfill, the 32-day read for a live refit). Returns the
    number of cycles scored."""
    todo = [i for i, c in enumerate(cycles) if c.reset <= now and c.period not in record.scored]
    if not todo:
        return 0
    want_diurnal = "diurnal-rate" in methods
    fits = {m: DEFAULT_FITS[m] for m in methods
            if m in DEFAULT_FITS and not (params.legacy_engine and m == "recent-rate")}
    acc = DiurnalAccumulator(clock) if want_diurnal else None
    todo_set, done = set(todo), 0
    for i, cyc in enumerate(cycles):
        if i in todo_set and cyc.period not in record.scored:
            _score_one(record, cyc, fits, acc, prior, clock, params)
            done += 1
        if acc is not None:
            acc.add(cyc)
        if i >= todo[-1]:
            break
    return done


def _score_one(record: Record, cyc: Cycle, fits: dict, acc, prior, clock, params: Params) -> None:
    period = cyc.period
    record.scored.add(period)
    final = cyc.final
    if final <= 0:
        return
    duration = cyc.reset - cyc.start
    if duration <= 0:
        return
    roster = dict(fits)
    if acc is not None:
        roster["diurnal-rate"] = Diurnal(acc.table(prior), clock)
    any_row = False
    for cf in RL_CUT_FRACTIONS:
        now = cyc.start + duration * cf
        n_seen = int(np.searchsorted(cyc.t, now, side="right"))
        if n_seen < 3:
            continue
        partial = Partial(cyc.t[:n_seen], cyc.y[:n_seen], now, cyc.start, cyc.reset, params.zero_anchor)
        for mid, fit in roster.items():
            proj = fit(partial, params)
            if proj is None:
                continue
            # v2 rows grade the value shown (#300); the engine before #311
            # graded the raw line at the reset.
            pred = float(proj(cyc.reset)) if params.legacy_engine else displayed_at_reset(proj, partial)
            record.add(mid, period, cf, pred)
            any_row = True
    if any_row:
        record.truth[period] = final


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

def best_method(record: Record, params: Params, weekly: bool, phase: str | None) -> str | None:
    """`EngineSelfEval.bestMethod`: lowest typical error over the phase's cuts
    (two scored periods at least), near-ties to the simpler model."""
    if params.legacy_engine:
        return _legacy_best_method(record, params, weekly)
    ph = phase if params.rl_select_by_phase else None
    scored = []
    for mid in record.rows:
        if record.n_periods(mid) < 2:
            continue
        errs = record.errors(mid, ph, params.rl_selection_recency)
        if len(errs) == 0:
            continue
        scored.append((mid, typical(errs, weekly), COMPLEXITY.get(mid, 3)))
    if not scored:
        return None
    best = min(x[1] for x in scored)
    band = best * params.rl_tie_relative if params.rl_tie_relative > 0 else 1.5
    near = [x for x in scored if x[1] <= best + band]
    return min(near, key=lambda x: (x[2], x[1]))[0]


def shadow_floors(params: Params, weekly: bool) -> dict[str, int]:
    """`rlShadowFloors` (before #311): kalman-trend everywhere, and the diurnal
    model on session-cadence windows, needed this many scored periods."""
    floors = {"kalman-trend": params.shadow_promotion_min_periods}
    if not weekly:
        floors["diurnal-rate"] = params.shadow_promotion_min_periods
    return floors


def _legacy_best_method(record: Record, params: Params, weekly: bool) -> str | None:
    """`bestMethod` before #311: the median over every cut on every window,
    shadow floors, the absolute 1.5 pp tie band."""
    floors = shadow_floors(params, weekly)
    scored = []
    for mid in record.rows:
        if record.n_periods(mid) < floors.get(mid, 2):
            continue
        scored.append((mid, typical(record.errors(mid), False), COMPLEXITY.get(mid, 3)))
    if not scored:
        return None
    best = min(x[1] for x in scored)
    near = [x for x in scored if x[1] <= best + 1.5]
    return min(near, key=lambda x: (x[2], x[1]))[0]


def accuracy_error(record: Record, method: str, params: Params, weekly: bool, phase: str | None) -> float:
    """`Accuracy.MethodStat.typicalAbsError` (infinite without a record)."""
    ph = phase if params.rl_select_by_phase else None
    return typical(record.errors(method, ph), weekly)


def resolve(fits: dict, selected: str, partial: Partial, record: Record, params: Params,
            weekly: bool, phase: str | None):
    """`resolveModel` (#301): the selected model if it fits this cycle, else
    the best-recorded model that does (lowest typical error, then simpler;
    roster order breaks full ties). (id, projection) or (None, None)."""
    if selected in fits:
        proj = fits[selected](partial, params)
        if proj is not None:
            return selected, proj
    best = None
    for mid, fit in fits.items():
        proj = fit(partial, params)
        if proj is None:
            continue
        rank = (accuracy_error(record, mid, params, weekly, phase), COMPLEXITY.get(mid, 3))
        if best is None or rank < best[0]:
            best = (rank, mid, proj)
    return (best[1], best[2]) if best else (None, None)


def cold_select(fits: dict, cycles: list[Cycle], params: Params, *, min_scored: int = 6,
                min_coverage: float = 0.5, simpler_within: float = 2.0) -> str | None:
    """`BurnTrajectory.score` over the history's cuts 0.5/0.6/0.7 (per-cycle
    median error of the raw projection over the unseen tail) and
    `ForecastSelector.select` with the engine's cold policy."""
    scores = []
    for mid, fit in fits.items():
        errors, attempts = [], 0
        for cyc in cycles:
            duration = cyc.reset - cyc.start
            for cf in COLD_CUTS:
                now = cyc.start + duration * cf
                n_seen = int(np.searchsorted(cyc.t, now, side="right"))
                n_future = len(cyc.t) - n_seen
                if n_seen < 3 or n_future < 2:
                    continue
                attempts += 1
                partial = Partial(cyc.t[:n_seen], cyc.y[:n_seen], now, cyc.start, cyc.reset, params.zero_anchor)
                proj = fit(partial, params)
                if proj is None:
                    continue
                ae = np.sort(np.abs(np.asarray(proj(cyc.t[n_seen:]), dtype=np.float64) - cyc.y[n_seen:]))
                errors.append(float(ae[len(ae) // 2]))
        coverage = len(errors) / attempts if attempts else 0.0
        scores.append((mid, COMPLEXITY.get(mid, 3), median(errors), coverage, len(errors)))
    eligible = [s for s in scores if s[4] >= min_scored and s[3] >= min_coverage and math.isfinite(s[2])]
    if not eligible:
        return None
    best = min(eligible, key=lambda s: s[2])
    near = [s for s in eligible if s[2] <= best[2] + simpler_within]
    return min(near, key=lambda s: (s[1], s[2]))[0]


# ---------------------------------------------------------------------------
# Conformal bands
# ---------------------------------------------------------------------------

def stratum_key(cut_fraction: float, cycle_start: float, clock: LocalClock) -> str:
    """`rlStratum`: window phase × day regime of the cycle's start."""
    regime = "weekend" if clock.is_weekend(cycle_start) else "weekday"
    return f"{phase_of(cut_fraction)}|{regime}"


def calibrators(method: str, fit, history: list[Cycle], record: Record, duration: float,
                clock: LocalClock, params: Params) -> dict[str, np.ndarray]:
    """`stratifiedRLCalibrators`: walk-forward residuals (truth − displayed)
    per stratum, from the refit's history and the record (the record's row
    wins where both cover a (cycle, cut)); one median residual per cycle in a
    bucket while fewer than `conformal_block_min_cycles` cycles back it.
    Always has "pooled"; a stratum stands alone with enough residuals."""
    rec_rows = record.rows.get(method, {})
    cases: dict[float, dict[float, tuple[float, float]]] = {}
    for cyc in history:
        final = cyc.final
        if final <= 0:
            continue
        period = cyc.period
        have = rec_rows.get(period, {})
        for cf in RL_CUT_FRACTIONS:
            if cf in have:
                continue                       # the record's row is used instead
            cut_now = cyc.start + duration * cf
            n_seen = int(np.searchsorted(cyc.t, cut_now, side="right"))
            if n_seen < 3:
                continue
            partial = Partial(cyc.t[:n_seen], cyc.y[:n_seen], cut_now, cyc.start, cyc.reset, params.zero_anchor)
            proj = fit(partial, params)
            if proj is None:
                continue
            cases.setdefault(period, {})[cf] = (cyc.start, final - displayed_at_reset(proj, partial))
    for period, cuts in rec_rows.items():
        truth = record.truth.get(period, 0.0)
        if truth <= 0:
            continue
        for cf, pred in cuts.items():
            cases.setdefault(period, {})[cf] = (period - duration, truth - pred)

    periods = sorted(cases)
    by_stratum: dict[str, list[tuple[int, float]]] = {}
    pooled: list[tuple[int, float]] = []
    for ci, period in enumerate(periods):
        for cf in sorted(cases[period]):
            start, res = cases[period][cf]
            pooled.append((ci, res))
            by_stratum.setdefault(stratum_key(cf, start, clock), []).append((ci, res))
    blocks = len(periods) < params.conformal_block_min_cycles

    def reduce(pairs: list[tuple[int, float]]) -> np.ndarray:
        if not blocks:
            vals = [r for _, r in pairs]
        else:
            per: dict[int, list[float]] = {}
            for ci, r in pairs:
                per.setdefault(ci, []).append(r)
            vals = [median(v) for v in per.values()]
        a = np.asarray(vals, dtype=np.float64)
        return np.sort(a[np.isfinite(a)])

    out = {"pooled": reduce(pooled)}
    for key, pairs in by_stratum.items():
        rs = reduce(pairs)
        if len(rs) >= params.rl_stratum_min_scores:
            out[key] = rs
    return out


def quantile(residuals: np.ndarray, p):
    """`ConformalCalibrator.quantile`: the ⌈(n+1)·p⌉-th smallest, clamped.
    `p` may be an array."""
    n = len(residuals)
    if n == 0:
        return np.nan
    rank = np.ceil((n + 1) * np.asarray(p, dtype=np.float64)).astype(np.int64)
    idx = np.clip(rank, 1, n) - 1
    return residuals[idx]


def gated_quantile(residuals: np.ndarray, p: float, min_residuals: int) -> float | None:
    if len(residuals) < min_residuals:
        return None
    return float(quantile(residuals, p))
