"""g1-10-fable-analog: kernel-weighted analog ensembles for every target.

Meters: every complete past cycle of the same window (and cap) is cut every
few minutes; each cut records the level, the rise over the last 15 min / 1 h
(weekly: 1 / 6 / 24 h), the local hour and weekday, and the increment
trajectory from the cut to its reset. At `now` the cuts are weighted by
closeness in phase, time of day, recent burn, account and recency; paths are
the sampled trajectories re-based on the latest reading and clipped to
[0, 100]. Bandwidths widen until the effective sample size is adequate; with
no complete cycle a pace-mixture fallback stands in.

Hourly spend / tokens: the same with hour-ends as analog starts (features:
local hour, weekday, the last 1 / 3 / 24 hours), trajectories of the next H
hours, chained when the history is shorter than the horizon.

Split: analog starts on the account's share series (hour, recent share).

Next start: empirical conditional time-to-next-turn given the idle duration
so far (left-truncated), the local hour and weekday.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast
from kit import baselines as B
from kit import spend as S

import analog as A

HOUR = A.HOUR
MIN = A.MIN
WINDOW_OF = B.WINDOW_OF


class Model:
    def __init__(self, ctx):
        self.cfg = ctx.config
        self.rng = ctx.rng
        self.log = ctx.log
        self.history = None
        self._tables: dict = {}

    def fit(self, history):
        self.history = history
        self._tables = {}

    def update(self, events):
        self.history = self.history.extend(events)

    # ------------------------------------------------------------------
    def forecast(self, request):
        out = {}
        for tr in request.targets:
            try:
                if tr.target in WINDOW_OF:
                    out[tr.key] = self._meter(tr)
                elif tr.target in (Target.SPEND_HOURLY, Target.TOKENS_HOURLY):
                    out[tr.key] = self._hourly(tr)
                elif tr.target is Target.SPLIT:
                    out[tr.key] = self._split(tr, request)
                elif tr.target is Target.CYCLE_NEXT_START:
                    out[tr.key] = self._next_start(tr)
            except Exception as ex:  # never fail the whole request
                self.log(f"{tr.key}: fallback after {type(ex).__name__}: {ex}")
                out[tr.key] = self._safe(tr)
        return Forecast(out)

    def _span_hours(self):
        """Hours of history available: from the episode's start when known,
        else from the earliest turn or reading."""
        h = self.history
        start = getattr(h, "start", None)
        if start is None:
            cands = []
            for name in ("turns", "meter_readings"):
                t = h.table(name)
                if t.height:
                    cands.append(int(t.select(__import__("polars").col("t_event").dt.epoch("ms").min()).item()))
            start = min(cands) if cands else h.now
        return int(min(self.cfg.get("hourly_history_days", 60) * 24, max(1, (h.now - start) // HOUR + 1)))

    def _safe(self, tr):
        if tr.target in WINDOW_OF:
            return B.meter_flat(self.history, tr)
        if tr.target is Target.CYCLE_NEXT_START:
            return B.next_start_never(self.history, tr)
        if tr.target is Target.SPLIT:
            return TargetForecast.point(np.full(len(tr.grid), 1.0))
        return B.hourly_flat(self.history, tr, 24)

    # ------------------------------------------------------------------
    # Meters
    # ------------------------------------------------------------------
    def _table(self, kind, cap, accounts, tz):
        cfg = self.cfg.get("meter", {}).get(kind, {})
        # Cache by the set of complete cycles: new ones appear only after a reset.
        n_cycles = sum(len(S.past_cycles(self.history, a, kind, cap)) for a in accounts)
        key = (kind, cap, tuple(accounts), n_cycles)
        T = self._tables.get(key)
        if T is None:
            T = A.build_meter_table(self.history, accounts, kind, cap, tz,
                                    int(cfg.get("step_min", 5)) * MIN, int(cfg.get("M", 60)))
            self._tables = {k: v for k, v in self._tables.items() if k[:3] != key[:3]}
            self._tables[key] = T
            self.log(f"meter table {kind}/{cap}: {len(T)} cuts from {T.n_cycles} cycles")
        return T

    def _meter(self, tr):
        h = self.history
        acct = tr.accounts[0]
        m = B.meter_now(h, tr)
        kind, cap = m.window_kind, m.scope_model
        cfg = self.cfg.get("meter", {}).get(kind, {})
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
        T = self._table(kind, cap, accounts, tz)
        grid = tr.grid.astype(np.int64)
        verbose = self.log if self.cfg.get("verbose") else None
        paths, e = A.meter_paths_from_table(T, q, grid, tr.n_paths, self.rng, cfg, verbose)
        min_ess = float(cfg.get("min_ess", 8))
        # Day-block bootstrap of hourly increments: a second component that
        # uses every reading (the current cycle too), and the whole answer
        # when no complete cycle exists yet.
        block_share = float(cfg.get("block_share", 0.0))
        block = None
        if block_share > 0 or paths is None or e < min_ess:
            series = S.meter_series(h, acct, kind, cap)
            if cfg.get("block_method", "daymodel") == "bootstrap":
                block = A.meter_block_paths(series, q, grid, T.W, tz, tr.n_paths, self.rng, cfg, verbose)
            else:
                fam = S._cap_family(cap) if cap else None
                td, since = A.turn_day_activity(h, acct, fam, now, tz, int(cfg.get("block_days", 60)))
                if not cfg.get("use_turns", True):
                    td, since = None, np.inf
                block = A.meter_daymodel_paths(series, q, grid, T.W, tz, tr.n_paths, self.rng, cfg, verbose,
                                               turn_days=td, since_turn_h=since)
        if paths is None:
            paths = block if block is not None else A.meter_paths_pace(q, grid, tr.n_paths, self.rng, kind)
        else:
            share = block_share if e >= min_ess else max(block_share, 1 - e / min_ess)
            k = int(round(tr.n_paths * share))
            if k > 0 and block is not None:
                paths[:k] = block[:k]
            elif k > 0:
                paths[:k] = A.meter_paths_pace(q, grid, k, self.rng, kind)
        # Dispersion shrink toward the ensemble median (hidden-tier five-hour
        # bands were far too wide: 50 % bands covered ~94 % of readings).
        shrink = float(cfg.get("shrink", 1.0))
        if shrink < 1.0:
            med = np.median(paths, axis=0, keepdims=True)
            paths = np.clip(np.rint(med + shrink * (paths - med)), 0.0, 100.0)
        return TargetForecast(paths)

    # ------------------------------------------------------------------
    # Hourly spend and tokens
    # ------------------------------------------------------------------
    def _hourly(self, tr):
        h = self.history
        what = "spend" if tr.target is Target.SPEND_HOURLY else "tokens"
        fam = tr.family if tr.target is Target.TOKENS_HOURLY else None
        H = len(tr.grid)
        span_h = self._span_hours()
        ends, v = S.hourly_series(h, tr.accounts, span_h, what, fam)
        tz = A.tz_ms(h, tr.accounts[0])
        paths = A.hourly_analog_paths(ends, v, H, h.now, tz, tr.n_paths, self.rng,
                                      self.cfg.get("hourly", {}), None)
        return TargetForecast(np.maximum(paths, 0.0))

    # ------------------------------------------------------------------
    # Split
    # ------------------------------------------------------------------
    def _split(self, tr, request):
        h = self.history
        group = tuple(request.scope.accounts)
        acct = tr.accounts[0]
        H = len(tr.grid)
        span_h = self._span_hours()
        ends, mine = S.hourly_series(h, (acct,), span_h, "spend")
        den = np.zeros_like(mine)
        for a in group:
            den += S.hourly_series(h, (a,), span_h, "spend")[1]
        with np.errstate(divide="ignore", invalid="ignore"):
            share = np.where(den > 0, mine / den, np.nan)
        tz = A.tz_ms(h, acct)
        paths = A.share_analog_paths(ends, share, H, h.now, tz, tr.n_paths, self.rng,
                                     self.cfg.get("split", {}), len(group))
        return TargetForecast(paths)

    # ------------------------------------------------------------------
    # Next start
    # ------------------------------------------------------------------
    def _next_start(self, tr):
        h = self.history
        acct = tr.accounts[0]
        T = A.turn_times(h, acct)
        tz = A.tz_ms(h, acct)
        # the idle stretch began at the last known reset of the five-hour window
        m = S.meter_series(h, acct, "five_hour")
        past = m["reset"][m["active"] & (m["reset"] <= h.now)]
        idle_since = int(past.max()) if len(past) else int(h.now - 5 * HOUR)
        horizon = int(tr.grid[-1])
        cfg = self.cfg.get("next_start", {})
        if cfg.get("method", "hazard") == "analog":
            vals = A.next_start_paths(T, h.now, idle_since, horizon, tz, tr.n_paths, self.rng,
                                      cfg, h.start, self.log)
        else:
            vals = A.next_start_hazard_paths(T, h.now, idle_since, horizon, tz, tr.n_paths, self.rng,
                                             cfg, self.log if self.cfg.get("verbose") else None)
        return TargetForecast(vals[:, None])
