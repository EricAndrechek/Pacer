"""From a `meter_readings` frame (rows known at now) to meter paths: the
glue between the harness's request and `limitsim`."""
from __future__ import annotations

import numpy as np
import polars as pl

from arena.types import Target
from kit.fm.series import meter_series

import limitsim as L

WINDOW_OF = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}


def _cfg(kind: str, cfg: dict) -> dict:
    c = dict(L.DEFAULTS[kind])
    c.update(cfg.get(kind, {}) if isinstance(cfg.get(kind, {}), dict) else {})
    return c


def _series(readings: pl.DataFrame, acct: str, kind: str, cap, now: int):
    return meter_series(readings, acct, kind, cap, now)


def current_level(s, reset_at) -> float:
    if reset_at is not None:
        u = s.used_now(int(reset_at))
        if u is not None:
            return float(u)
    return 0.0


def stay_hours(s, reset_at, u0: float, now: int) -> float:
    """How long this cycle's meter has read u0 (since it last read lower)."""
    if reset_at is None or u0 <= 0:
        return 0.0
    m = s.cycle_mask(int(reset_at))
    if not m.any():
        return 0.0
    t, u = s.times[m], s.cycle_util[m]
    lower = np.nonzero(u < u0)[0]
    i = lower[-1] + 1 if len(lower) else 0
    if i >= len(t):
        return 0.0
    return max(0.0, (now - int(t[i])) / L.HOUR)


def weekly_block_until(readings: pl.DataFrame, acct: str, now: int):
    """The seven-day reset when the account's seven-day meter reads 100 now
    (the account is blocked until then), else None."""
    s = _series(readings, acct, "seven_day", None, now)
    if len(s) == 0 or not s.active[-1]:
        return None
    r = int(s.reset[-1])
    if r <= now or s.cycle_util[-1] < 100:
        return None
    return r


def idle_hours(s, now: int) -> float:
    """Hours since this meter last rose (any cycle): how long the account
    has been left alone on this meter."""
    if len(s) < 2:
        return 0.0
    rose = np.nonzero(np.diff(s.cum) > 0)[0]
    if not len(rose):
        return (now - int(s.times[0])) / L.HOUR
    return max(0.0, (now - int(s.times[rose[-1] + 1])) / L.HOUR)


def flat_paths(readings, now, tr) -> np.ndarray:
    kind = WINDOW_OF[tr.target]
    cap = tr.cap if tr.target is Target.METER_SCOPED else None
    s = _series(readings, tr.accounts[0], kind, cap, now)
    u0 = current_level(s, tr.reset_at)
    return np.full((tr.n_paths, len(tr.grid)), u0)


def meter_paths(readings: pl.DataFrame, now: int, tr, tz_min: int, accounts: tuple, rng, cfg: dict,
                return_steps: bool = False):
    kind = WINDOW_OF[tr.target]
    cap = tr.cap if tr.target is Target.METER_SCOPED else None
    c = _cfg(kind, cfg)
    acct = tr.accounts[0]
    step = int(c["step_min"]) * L.MIN
    tz_ms = int(tz_min) * L.MIN
    lookback = int(float(c["lookback_days"]) * L.DAY)
    stale = 3 * step if kind == "five_hour" else 3 * L.HOUR
    reset = int(tr.reset_at) if tr.reset_at is not None else int(tr.grid[-1])
    dur = L.WINDOW[kind]
    own = _series(readings, acct, kind, cap, now)
    u0 = current_level(own, tr.reset_at)
    hists, falls = [], []
    own_h = L.step_history(own.times, own.cum, own.cycle_util, own.active, now, step, lookback, tz_ms, stale)
    hists.append((own_h, 1.0))
    falls.append(L.find_falls(own.times, own.cycle_util, own.active, own.reset, dur))
    other_w = float(c.get("other_account_weight", 0.5))
    if other_w > 0:
        others = [a for a in accounts if a != acct]
        for a in others:
            s = _series(readings, a, kind, cap, now)
            if len(s) < 2:
                continue
            hh = L.step_history(s.times, s.cum, s.cycle_util, s.active, now, step, lookback, tz_ms, stale)
            hists.append((hh, other_w))
            falls.append(L.find_falls(s.times, s.cycle_util, s.active, s.reset, dur))
    beh = L.learn_behaviour(hists, c["bands"], float(c["half_life_days"]), float(c["prior_hours"]), step,
                            float(c["rebase_prior"]), float(c["rebase_weeks_prior"]), falls)
    ceil, leak_step = None, 0.0
    if c.get("use_ceilings", True):
        zone_lo = float(c.get("zone_lo", 90))
        park_min = int(float(c.get("park_frac", 0.12)) * dur)
        tops = [(t, 1.0) for t in L.cycle_tops(own.times, own.cycle_util, own.active, own.reset, dur, now,
                                               zone_lo, park_min)]
        if other_w > 0:
            for a in [a for a in accounts if a != acct]:
                s = _series(readings, a, kind, cap, now)
                tops += [(t, other_w) for t in L.cycle_tops(s.times, s.cycle_util, s.active, s.reset, dur, now,
                                                            zone_lo, park_min)]
        ce = L.learn_ceilings(tops, now, float(c.get("ceil_half_life_days", 28.0)), zone_lo,
                              float(c.get("ceil_prior_w100", 0.5)), float(c.get("leak_prior", 0.005)),
                              float(c.get("leak_prior_hours", 48.0)),
                              {int(k): float(v) for k, v in dict(c.get("prior_park", {"95": 0.1, "97": 0.1, "99": 0.3})).items()},
                              float(c.get("late_h", 0.0)), float(c.get("leak_late_prior", 0.0)),
                              float(c.get("leak_late_prior_hours", 0.0)))
        stay = stay_hours(own, tr.reset_at, u0, now)
        free = (own_h.level < min(float(c["park_from"]), 100.0))
        surv = lambda hrs: L.zero_burn_survival(own_h, hrs, step, float(c["half_life_days"]), free)
        lv, pr = L.ceiling_posterior(ce, u0, stay, surv)
        ceil = rng.choice(lv.astype(np.float64), size=tr.n_paths, p=pr)
        H = max(1, int(np.ceil((reset - now) / step)))
        r_h = (reset - (now + step * np.arange(1, H + 1))) / L.HOUR          # hours to reset at each step's end
        lam = np.where(r_h <= ce.late_h, ce.leak_late_per_hour, ce.leak_per_hour) if ce.late_h > 0 \
            else np.full(H, ce.leak_per_hour)
        leak_step = 1.0 - np.exp(-lam * step / L.HOUR)
        beh.keep = np.ones_like(beh.keep)
    h = own_h
    if len(h.burn) < int(c["min_hist_steps"]) or h.burn.sum() <= 0:
        # Too little of this meter's own past: borrow another account's, at
        # a discount (a new account rarely carries a whole account's load).
        best = max(hists[1:], key=lambda x: x[0].burn.sum(), default=None)
        if best is not None and best[0].burn.sum() > 0 and (len(h.burn) < 2 or h.burn.sum() <= 0):
            b = best[0]
            h = L.StepHist(b.t_end, b.burn * float(c.get("borrow_scale", 0.5)), b.level, b.tod, b.age_days, b.covered)
    delay = None
    min_stay = float(c.get("delay_min_stay_h", 0.0))
    if min_stay > 0 and h is own_h:
        idle = idle_hours(own, now)
        if idle >= min_stay:
            free_h = h.level < min(float(c["park_from"]), 100.0)
            lens, wts = L.idle_runs(h, float(c["half_life_days"]), free_h)
            delay = L.resume_delay(lens, wts, idle * L.HOUR / step, tr.n_paths, rng,
                                   float(c.get("delay_tail_mult", 0.5)))
    if kind != "seven_day" and c.get("couple_weekly", True):
        # The account's seven-day limit reached blocks all use: this meter
        # holds until that limit resets (A1: five-hour burn 45x lower,
        # scoped burn zero while the seven-day meter read 100).
        until = weekly_block_until(readings, acct, now)
        if until is not None:
            k = int(np.ceil((until - now) / step))
            delay = np.maximum(delay, k) if delay is not None else np.full(tr.n_paths, k, np.int64)
    times, vals = L.simulate(h, beh, u0, now, reset, step, tz_ms, tr.n_paths, rng, c, c["bands"],
                             ceil=ceil, leak_per_step=leak_step, delay=delay)
    paths = L.to_grid(times, vals, tr.grid)
    if return_steps:
        return paths, (times, vals, beh)
    return paths
