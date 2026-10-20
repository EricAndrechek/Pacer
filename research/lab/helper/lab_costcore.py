"""The token-spend forecasters behind the lab-cost-* predictors (the lab's
tokc-rate-*-cal and tokc-decay-* — research/lab/tokens/cost_models.py).

Spend is converted to meter points with ONE points-per-dollar factor per
account, refit daily on the window's last 14 days of reading intervals. The
forecast at a cut:
  now     = the last reading + converted spend since it (a nowcast: the meter
            lags the turns Pacer has already seen)
  burn    = converted spend over the last `lookback`, per second, scaled by
            how much of the converted spend the meter showed this cycle
  rate    = now + burn × remaining
  decay   = now + burn × τ × (1 − e^(−remaining/τ)), τ chosen walk-forward
            from this account's earlier cycles in the same half of the window
Everything reads only spend and readings at or before the cut.
"""
from __future__ import annotations

import bisect
import math

from lab_history import History
from lab_tokens import ledger

TAUS_H = (0.5, 1, 2, 4, 8, 16, 48)
CUTS = (0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9)
_FACTOR: dict[tuple, float | None] = {}
_TAU_ERRORS: dict[tuple, dict[bool, list[list[float]]]] = {}


def factor(history: History, t_cut: float) -> float | None:
    """Points of this window's meter per API $, refit daily on 14 days."""
    day = int(t_cut // 86400)
    key = (history.account, history.window, day)
    if key in _FACTOR:
        return _FACTOR[key]
    led = ledger()
    hi, lo = day * 86400.0, day * 86400.0 - 14 * 86400.0
    rs = history.readings
    i = max(1, bisect.bisect_left(rs, lo, key=lambda r: r.t))
    rise = spent = 0.0
    while i < len(rs) and rs[i].t <= hi:
        a, b = rs[i - 1], rs[i]
        if abs(b.resets_at - a.resets_at) < history.duration / 2 and b.pct >= a.pct and 0 < b.t - a.t < 3600:
            rise += b.pct - a.pct
            spent += led.spent(history.account, a.t, b.t, t_cut)
        i += 1
    k = rise / spent if spent > 1.0 else None
    _FACTOR[key] = k
    return k


def parts(history: History, t_cut: float, cycle_start: float, resets_at: float, lookback: float):
    """(now, calibrated burn per second, remaining seconds), or None."""
    k = factor(history, t_cut)
    if k is None:
        return None
    led = ledger()
    cyc = history.cycle()
    used = cyc[-1].pct if cyc else 0.0
    t_last = cyc[-1].t if cyc else cycle_start
    now = min(100.0, used + k * led.spent(history.account, t_last, t_cut, t_cut))
    conv = k * led.spent(history.account, cycle_start, t_last, t_cut)
    ratio = min(4.0, max(0.25, used / conv)) if conv > 1 else 1.0
    span = min(lookback, t_cut - cycle_start)
    if span <= 0:
        return None
    burn = k * led.spent(history.account, t_cut - span, t_cut, t_cut) / span * ratio
    return now, burn, max(0.0, resets_at - t_cut), used


def rate(history, t_cut, cycle_start, resets_at, lookback):
    p = parts(history, t_cut, cycle_start, resets_at, lookback)
    if p is None:
        return None
    now, burn, remaining, _ = p
    return now + burn * remaining


def _decay_values(p) -> list[float]:
    now, burn, remaining, used = p
    return [min(100.0, max(used, now + burn * t * 3600 * (1 - math.exp(-remaining / (t * 3600))))) for t in TAUS_H]


def decay(history: History, t_cut, cycle_start, resets_at, lookback, weekly: bool):
    p = parts(history, t_cut, cycle_start, resets_at, lookback)
    if p is None:
        return None
    half = (t_cut - cycle_start) / max(resets_at - cycle_start, 1) >= 0.5
    # Each earlier cycle's errors per τ at every cut, computed once.
    errs: list[list[float]] = []
    for c in history.completed_cycles():
        key = (history.account, history.window, round(c.resets_at / 60), lookback)
        if key not in _TAU_ERRORS:
            byhalf: dict[bool, list[list[float]]] = {False: [], True: []}
            for cut in CUTS:
                tc = c.cycle_start + (c.resets_at - c.cycle_start) * cut
                seen = history.readings[:bisect.bisect_right(history.readings, tc, key=lambda r: r.t)]
                if sum(1 for r in seen if r.t > c.cycle_start) < 3:
                    continue
                sub = History(window=history.window, account=history.account, t_cut=tc,
                              cycle_start=c.cycle_start, resets_at=c.resets_at, duration=history.duration,
                              readings=seen)
                q = parts(sub, tc, c.cycle_start, c.resets_at, lookback)
                if q is not None:
                    byhalf[cut >= 0.5].append([abs(v - c.final) for v in _decay_values(q)])
            _TAU_ERRORS[key] = byhalf
        errs += _TAU_ERRORS[key][half]
    values = _decay_values(p)
    if len(errs) < 16:
        return values[TAUS_H.index(1)]
    col = list(zip(*errs))
    stat = [(sum(e) / len(e)) if weekly else sorted(e)[len(e) // 2] for e in col]
    return values[stat.index(min(stat))]
