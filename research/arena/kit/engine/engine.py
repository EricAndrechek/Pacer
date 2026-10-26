"""One rate-limit window's engine at a moment: what `UsageIntelligenceEngine`
does in a refit (`recompute` → `makeFit` → `rateLimitOutlook`), for one
(account, window) and either the shipping selection rule or one fixed method.

Per call, with only the readings known at `now`:
1. the live read: the last `rate_fetch_days` (32) of readings, segmented
   into the current partial cycle and the cycles before it;
2. newly completed cycles are scored into the record (the first call also
   back-fills every older completed cycle, as the app's launch pass does);
3. the roster: the six default models, plus the diurnal model once the live
   read holds a completed cycle (its table from those cycles and the activity
   grid as of now);
4. selection (rule only): the record's best method for the live phase, else
   the cold backtest, else the default; then the stand-in rule when the pick
   cannot fit this cycle;
5. the band: the shown model's stratified conformal residuals.

The `WindowEngine` keeps its record between calls, so a model that calls it
at successive checkpoints scores each cycle once, when it completes.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from kit.engine.clock import DAY_S, LocalClock
from kit.engine.core import (
    METHOD_IDS, Diurnal, Partial, displayed_at_reset, anchor_shift, diurnal_rate_table,
    is_weekly_scale, roster, segment, segment_all,
)
from kit.engine.params import Params, SHIPPING
from kit.engine.selfeval import (
    Record, best_method, calibrators, cold_select, phase_of, resolve, score_cycles, shadow_floors,
    stratum_key,
)

RULE = "rule"


@dataclass
class Outlook:
    """What the window would show at `now`."""

    method: str | None             # the model drawn (None: nothing could fit)
    selected: str | None           # what selection picked, before any stand-in
    partial: Partial
    proj: object | None            # projection callable (epoch seconds -> %)
    value: float | None            # the displayed value at reset
    anchor: float = 0.0
    stratum: str | None = None     # which calibrator served the band
    residuals: np.ndarray = field(default_factory=lambda: np.zeros(0))
    selection: str = ""            # "record" | "cold" | "default" | "fixed"
    fits: dict = field(default_factory=dict)   # the roster this refit fitted with

    @property
    def used_now(self) -> float:
        return self.partial.used_now

    @property
    def reset(self) -> float:
        return self.partial.reset


class WindowEngine:
    def __init__(self, duration_s: float, clock: LocalClock, *, method: str = RULE,
                 params: Params = SHIPPING):
        if method != RULE and method not in METHOD_IDS:
            raise ValueError(f"unknown method {method!r}")
        self.duration = float(duration_s)
        self.clock = clock
        self.method = method
        self.params = params
        self.methods = METHOD_IDS if method == RULE else (method,)
        self.record = Record()
        self._backfilled = False

    @property
    def weekly(self) -> bool:
        return is_weekly_scale(self.duration)

    def observe(self, t: np.ndarray, y: np.ndarray, r: np.ndarray, now: float,
                grid: np.ndarray | None, params: Params | None = None) -> Outlook | None:
        """The outlook at `now` from readings (epoch seconds, %, own reset; sorted
        by time, known by now). None when the window has no live cycle."""
        p = params or self.params
        live = t >= now - p.rate_fetch_days * DAY_S
        cur, hist = segment(t[live], y[live], r[live], self.duration, now, p.zero_anchor)
        # Cycles that completed inside the live read (`newRLOutcomes`), then, on
        # the first call, every older one (`backfillRateLimitRecordIfNeeded`,
        # which skips what a refit already scored).
        score_cycles(self.record, hist, p, clock=self.clock, prior=grid, methods=self.methods, now=now)
        if not self._backfilled and not p.legacy_engine:
            all_cycles, cur_i = segment_all(t, y, r, self.duration)
            older = [c for i, c in enumerate(all_cycles) if i != cur_i]
            score_cycles(self.record, older, p, clock=self.clock, prior=grid, methods=self.methods, now=now)
            self._backfilled = True
        if cur is None or cur.reset <= now or len(cur.t) == 0:
            return None

        diurnal = Diurnal(diurnal_rate_table(hist, grid, self.clock), self.clock) if hist else None
        fits = roster(diurnal, p.legacy_engine)
        phase = phase_of(cur.cut_fraction) if p.rl_select_by_phase else None
        if self.method == RULE and p.legacy_engine:
            # Before #311: no stand-in; the selected model (or the roster's
            # first when it is not in the roster) shows, or nothing does.
            pick, how = best_method(self.record, p, self.weekly, None), "record"
            if pick is None:
                shadows = shadow_floors(p, self.weekly)
                pick, how = cold_select({k: f for k, f in fits.items() if k not in shadows}, hist, p), "cold"
            if pick is None:
                pick, how = ("diurnal-rate" if self.weekly else "recency-weighted"), "default"
            shown = pick if pick in fits else next(iter(fits))
            proj = fits[shown](cur, p)
        elif self.method == RULE:
            pick, how = best_method(self.record, p, self.weekly, phase), "record"
            if pick is None:
                pick, how = cold_select(fits, hist, p), "cold"
            if pick is None:
                pick, how = ("diurnal-rate" if self.weekly else "recency-weighted"), "default"
            shown, proj = resolve(fits, pick, cur, self.record, p, self.weekly, phase)
        else:
            pick, how = self.method, "fixed"
            fit = fits.get(self.method)
            proj = fit(cur, p) if fit is not None else None
            shown = self.method if proj is not None else None
        if proj is None:
            return Outlook(None, pick, cur, None, None, selection=how, fits=fits)

        # Bands read the record as well as the live read since #306; before
        # #311 they came from the live read alone.
        rec = Record() if p.legacy_engine else self.record
        cal = calibrators(shown, fits[shown], hist, rec, self.duration, self.clock, p)
        key = stratum_key(cur.cut_fraction, cur.start, self.clock)
        if key in cal:
            stratum, res = key, cal[key]
        else:
            stratum, res = "pooled", cal["pooled"]
        return Outlook(shown, pick, cur, proj, displayed_at_reset(proj, cur), anchor_shift(proj, cur),
                       stratum, res, how, fits)
