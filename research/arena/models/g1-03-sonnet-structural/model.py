"""Structural: past-cycle bootstrap conditioned on current burn state.

Key insight: the meter's future depends primarily on whether a work session
is currently active and at what rate. Past cycles in similar positions
(same value + same burn rate + similar time-of-day) give calibrated paths.

The burn rate is the structural link between API spend and meter movement.
Conditioning on it filters out inactive cycles when the current cycle is
active, and vice versa, giving much tighter predictions.
"""
from __future__ import annotations

import numpy as np
import polars as pl

from arena.pricing import price_turns
from arena.types import Forecast, Target, TargetForecast
from kit import spend as kspend

HOUR_MS = 3_600_000
WEEK_MS = 7 * 24 * HOUR_MS
MIN_MS = 60_000

WINDOW_FOR = {
    Target.METER_5H: "five_hour",
    Target.METER_7D: "seven_day",
    Target.METER_SCOPED: "weekly_scoped",
}
WINDOW_DURATION_MS = {
    "five_hour": 5 * HOUR_MS,
    "seven_day": WEEK_MS,
    "weekly_scoped": WEEK_MS,
}


class Model:
    def __init__(self, ctx):
        self.cfg = ctx.config
        self.rng = ctx.rng
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target in WINDOW_FOR:
                out[tr.key] = self._meter(request.now, tr)
            elif tr.target is Target.SPEND_HOURLY:
                out[tr.key] = self._spend(request.now, tr)
        return Forecast(out)

    # ------------------------------------------------------------------
    def _meter(self, now: int, tr) -> TargetForecast:
        wk = WINDOW_FOR[tr.target]
        acct = tr.accounts[0]
        cap = tr.cap if tr.target is Target.METER_SCOPED else None
        grid = np.asarray(tr.grid, dtype=np.int64)

        cycle = kspend.current_cycle(self.history, acct, wk, cap)
        if cycle is None:
            return TargetForecast.point(np.zeros(len(grid)), tr.n_paths)

        cycle_start, cycle_reset, cycle_readings = cycle
        duration = float(cycle_reset - cycle_start)
        if duration <= 0:
            return TargetForecast.point(np.zeros(len(grid)), tr.n_paths)

        current_phase = float(np.clip((now - cycle_start) / duration, 0.0, 1.0))
        current_value, current_rate_pph = self._current_state(
            cycle_readings, cycle_start, duration, now
        )
        # Live value: use as starting point but condition bootstrap on reading
        lv = kspend.live_value(self.history, acct, wk, cap)
        live_offset = max(0.0, float(lv) - current_value) if lv is not None else 0.0

        grid_phases = np.clip(
            (grid.astype(np.float64) - cycle_start) / duration,
            current_phase, 1.0
        )

        past = kspend.past_cycles(self.history, acct, wk, cap)
        min_cycles = int(self.cfg.get("min_cycles", 5))

        if len(past) >= min_cycles:
            paths = self._bootstrap_paths(
                past, current_value, current_rate_pph, current_phase,
                grid_phases, tr.n_paths, cycle_start, wk, live_offset
            )
        else:
            paths = self._fallback_paths(
                current_value + live_offset, current_rate_pph, grid_phases, tr.n_paths, duration
            )

        return TargetForecast(paths)

    def _current_state(self, cycle_readings, cycle_start, duration, now):
        """Current meter value and recent burn rate (% per hour)."""
        if cycle_readings.height == 0:
            return 0.0, 0.0

        r = cycle_readings.sort("t_event")
        times = r["t_event"].dt.epoch("ms").to_numpy().astype(np.float64)
        utils = r["util_pct"].to_numpy().astype(np.float64)

        current_value = float(utils[-1])

        # Burn rate: slope over the last 30 min (or less if cycle is young)
        lookback_ms = float(self.cfg.get("rate_lookback_min", 30)) * MIN_MS
        t_lo = max(float(cycle_start), float(now) - lookback_ms)
        mask = times >= t_lo
        if mask.sum() < 2:
            return current_value, 0.0

        t_win = times[mask]
        u_win = utils[mask]
        elapsed = float(t_win[-1] - t_win[0])
        if elapsed < 1000:
            return current_value, 0.0

        rate_pph = float(u_win[-1] - u_win[0]) / elapsed * HOUR_MS
        return current_value, max(0.0, rate_pph)

    def _bootstrap_paths(
        self,
        past,
        current_value: float,
        current_rate_pph: float,
        current_phase: float,
        grid_phases: np.ndarray,
        n_paths: int,
        cycle_start: int,
        wk: str,
        live_offset: float = 0.0,
    ) -> np.ndarray:
        """Sample from past cycles conditioned on (reading, burn rate, time); start from live value."""
        period_ms = WINDOW_DURATION_MS[wk]
        duration_h = period_ms / HOUR_MS

        value_sigma = float(self.cfg.get("value_sigma", 15.0))
        rate_sigma = float(self.cfg.get("rate_sigma_pph", 8.0))
        time_sigma_frac = float(self.cfg.get("time_sigma_frac", 0.15))
        recency_half_life_days = float(self.cfg.get("recency_half_life_days", 14.0))

        is_active = current_rate_pph > float(self.cfg.get("active_threshold_pph", 0.5))

        # Time-of-day (0–1) for the current cycle start
        day_ms = 24 * HOUR_MS
        current_tod = float(cycle_start % day_ms) / day_ms

        n_past = len(past)
        v_at_phase = np.empty(n_past)
        rate_at_phase = np.empty(n_past)
        increments = np.empty((n_past, len(grid_phases)))
        tod_offsets = np.empty(n_past)        # time-of-day at past cycle start
        recency_days = np.empty(n_past)       # days before current cycle start
        is_active_past = np.empty(n_past, dtype=bool)

        rate_window_frac = 0.05

        for i, c in enumerate(past):
            dur_c = float(c.reset - c.start)
            tod_offsets[i] = float(c.start % day_ms) / day_ms
            recency_days[i] = max(0.0, float(cycle_start - c.start)) / (day_ms)

            if dur_c <= 0:
                v_at_phase[i] = 0.0
                rate_at_phase[i] = 0.0
                increments[i] = 0.0
                is_active_past[i] = False
                continue

            phases_c = (c.t.astype(np.float64) - c.start) / dur_c
            utils_c = c.util.astype(np.float64)
            order = np.argsort(phases_c)
            phases_c, utils_c = phases_c[order], utils_c[order]

            if len(phases_c) == 0:
                v_at_phase[i] = 0.0
                rate_at_phase[i] = 0.0
                increments[i] = 0.0
                is_active_past[i] = False
                continue

            if phases_c[0] > 1e-6:
                phases_c = np.concatenate(([0.0], phases_c))
                utils_c = np.concatenate(([0.0], utils_c))
            if phases_c[-1] < 1.0 - 1e-6:
                phases_c = np.concatenate((phases_c, [1.0]))
                utils_c = np.concatenate((utils_c, [utils_c[-1]]))

            v_at_phase[i] = float(np.interp(current_phase, phases_c, utils_c))

            ph_lo = max(0.0, current_phase - rate_window_frac)
            ph_hi = min(1.0, current_phase + rate_window_frac)
            v_lo = float(np.interp(ph_lo, phases_c, utils_c))
            v_hi = float(np.interp(ph_hi, phases_c, utils_c))
            dph = max(ph_hi - ph_lo, 1e-6)
            rate_at_phase[i] = max(0.0, (v_hi - v_lo) / dph / duration_h)
            is_active_past[i] = rate_at_phase[i] > float(self.cfg.get("active_threshold_pph", 0.5))

            v_at_grid = np.interp(grid_phases, phases_c, utils_c)
            increments[i] = v_at_grid - v_at_phase[i]

        # --- Compute weights ---

        # 1. Activity state match
        activity_w = np.where(is_active_past == is_active, 1.0, 0.2)

        # 2. Value similarity
        value_w = np.exp(-0.5 * ((v_at_phase - current_value) / max(value_sigma, 1.0)) ** 2)

        # 3. Burn rate similarity when active
        if is_active:
            rate_w = np.exp(-0.5 * ((rate_at_phase - current_rate_pph) / max(rate_sigma, 0.1)) ** 2)
        else:
            rate_w = np.ones(n_past)

        # 4. Time-of-day similarity (circular, 24h clock)
        diff_tod = np.abs(tod_offsets - current_tod)
        diff_tod = np.minimum(diff_tod, 1.0 - diff_tod)
        time_w = np.exp(-0.5 * (diff_tod / max(time_sigma_frac, 0.01)) ** 2)

        # 5. Recency: recent cycles are more representative
        recency_w = np.exp(-recency_days * np.log(2) / max(recency_half_life_days, 1.0))

        weights = activity_w * value_w * rate_w * time_w * recency_w
        w_sum = float(weights.sum())
        if w_sum <= 0 or not np.isfinite(w_sum):
            weights = value_w
            w_sum = float(weights.sum())
            if w_sum <= 0:
                weights = np.ones(n_past) / n_past
            else:
                weights /= w_sum
        else:
            weights /= w_sum

        start = current_value + live_offset
        idx = self.rng.choice(n_past, size=n_paths, p=weights, replace=True)

        paths = start + increments[idx]

        paths = np.clip(paths, start, 100.0)
        paths = np.maximum.accumulate(paths, axis=1)
        return paths

    def _fallback_paths(
        self, current_value: float, rate_pph: float, grid_phases: np.ndarray,
        n_paths: int, duration: float
    ) -> np.ndarray:
        """Structural projection with log-normal uncertainty when too few past cycles."""
        # Expected future: exponential decay of current rate
        tau = 2 * HOUR_MS  # 2-hour decay constant
        leads = grid_phases * duration  # ms into cycle
        remaining = leads - leads[0]  # ms from now
        expected_rise = rate_pph * tau / HOUR_MS * (1.0 - np.exp(-remaining / tau))
        center = np.clip(current_value + expected_rise, current_value, 100.0)

        # Spread: log-normal multiplier on the rise
        mult = np.exp(self.rng.normal(0.0, 0.7, size=(n_paths, 1)))
        paths = current_value + (center[None, :] - current_value) * mult
        paths = np.clip(paths, current_value, 100.0)
        paths = np.maximum.accumulate(paths, axis=1)
        return paths

    # ------------------------------------------------------------------
    def _spend(self, now: int, tr) -> TargetForecast:
        lookback_h = int(self.cfg.get("spend_lookback_h", 24))
        lookback_ms = lookback_h * HOUR_MS
        turns = self.history.table("turns").filter(
            pl.col("account").is_in(list(tr.accounts))
            & (pl.col("t_event").dt.epoch("ms") > now - lookback_ms)
        )
        priced = price_turns(turns, self.history.table("prices"), as_of=self.history.now)
        per_hour = float(priced["cost_usd"].sum() or 0.0) / lookback_h
        grid = np.asarray(tr.grid, dtype=np.float64)
        return TargetForecast.point(np.full(len(grid), per_hour), tr.n_paths)
