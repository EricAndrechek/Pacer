"""Recent converted burn, fading: the lab's best five-hour candidates
(tokc-decay / tokm-decay, research/lab/tokens/meterfit_models.py), as path
forecasts.

At `now`, for one meter (account, window, cap):

    now_value = latest reading + k · spend since it
    burn      = k · spend over the last `lookback` (at most the cycle so far) / that time
    ratio     = clip(latest reading / (k · spend from the cycle's start to that reading), 0.25, 4)
    value(ℓ)  = now_value + burn · ratio · τ · (1 − e^(−ℓ/τ))       ℓ = time ahead

kept between the latest reading and 100. `k` is the spend-to-meter conversion
(`kit.spend.fit_conversion`: points per dollar per model family, refit daily
on the 14 days before the day; a weak fit falls back to one pooled factor, as
the lab's forecasters did). `ratio` calibrates the conversion on the cycle so
far; τ is how fast the current burst fades.

**τ is learned walk-forward** per account and half of the window: every past
cycle in the history (reset before now) is cut at 5 %, 10 %, … 95 % of its
window, each cut forecast exactly as above with the conversion of its own day,
and τ is the value of TAUS_H whose error at reset was smallest over the cuts
of the same account and half (median absolute error on the five-hour window,
mean on weekly ones, as in the lab), across every visible account when the
account has fewer than 16 such cuts.

**Paths come from the distribution of past errors at the same phase**: each
cut also records its error (what the meter read − the forecast) along the rest
of its cycle, at fractions of the time left. A path is the forecast plus one
such error trajectory, drawn from the cuts nearest in phase (within 10 % of
the window, and with a burn of the same kind: some vs none), mapped onto
today's time left; then kept within [latest reading, 100] and never falling.
"""
from __future__ import annotations

import numpy as np

from arena.snapshot.cycles import window_ms
from arena.types import Forecast, Target, TargetForecast
from kit import baselines as B
from kit import spend

MIN_MS = 60_000
TAUS_H = (0.5, 1, 2, 4, 8, 16, 48)
PHASES = np.round(np.arange(0.05, 0.951, 0.05), 2)     # where past cycles are cut
FRACS = np.linspace(0.05, 1.0, 20)                     # error trajectory points, of the time left
MIN_CASES = 16
MIN_SPREAD_CASES = 8


class Model:
    def __init__(self, ctx):
        cfg = ctx.config
        self.lookback = int(cfg.get("lookback_min", 30)) * MIN_MS
        self.max_days = int(cfg.get("case_days", 60))
        self.default_tau = {k: float(v) for k, v in cfg.get("default_tau_h", {}).items()}
        self.phase_band = float(cfg.get("phase_band", 0.10))
        self.rng = ctx.rng
        self.log = ctx.log
        self.history = None
        self._cases: dict = {}

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        return Forecast({tr.key: self._meter(tr) for tr in request.targets if tr.target in B.WINDOW_OF})

    # ------------------------------------------------------------------
    def _meter(self, tr):
        h = self.history
        m = B.meter_now(h, tr)
        acct = tr.accounts[0]
        dur = window_ms(m.window_kind)
        n = len(tr.grid)
        d = spend.fit_details(h, acct, m.window_kind, m.scope_model)
        if d is None:
            return TargetForecast.point(np.full(n, m.latest))
        k = d.rates
        st = state(h, acct, k, m.start, m.reset, m.latest_t, m.latest, h.now, self.lookback)
        u_now = (h.now - m.start) / dur
        cases = self._case_table(acct, m.window_kind, m.scope_model)
        weekly = m.window_kind != "five_hour"
        tau_i = self._pick_tau(cases, acct, u_now >= 0.5, weekly, m.window_kind)
        tau = TAUS_H[tau_i] * 3_600_000
        lead = (tr.grid - h.now).astype(np.float64)
        centre = path(st, tau, lead)

        pick = self._spread_cases(cases, acct, u_now, st["burn"] > 0)
        if pick is None:
            # Too little past to learn a spread from: the predicted rise
            # scaled by a lognormal factor (the burn may stop or double).
            mult = np.exp(self.rng.normal(0.0, 0.6, size=tr.n_paths))
            paths = m.latest + (centre[None, :] - m.latest) * mult[:, None]
        else:
            err = cases["truth"][pick] - cases["centre"][pick, tau_i]      # [c, FRACS]
            left = max(m.reset - h.now, 1)
            f = np.clip(lead / left, 0.0, 1.0)
            xs = np.concatenate(([0.0], FRACS))
            e = np.stack([np.interp(f, xs, np.concatenate(([0.0], row))) for row in err])
            draw = self.rng.integers(0, len(e), size=tr.n_paths)
            paths = centre[None, :] + e[draw]
        paths = np.clip(paths, m.latest, 100.0)
        paths = np.maximum.accumulate(paths, axis=1)
        return TargetForecast(paths)

    def _pick_tau(self, cases, acct, half, weekly, kind):
        if cases is not None:
            same = cases["half"] == half
            for m in (same & (cases["account"] == acct), same):
                if m.sum() >= MIN_CASES:
                    ae = cases["ae"][m]
                    score = np.nanmean(ae, axis=0) if weekly else np.nanmedian(ae, axis=0)
                    return int(np.nanargmin(score))
        default = self.default_tau.get(kind, 2.0 if kind == "five_hour" else 16.0)
        return int(np.argmin([abs(t - default) for t in TAUS_H]))

    def _spread_cases(self, cases, acct, u_now, active):
        if cases is None:
            return None
        near = np.abs(cases["phase"] - u_now) <= self.phase_band + 1e-9
        half = cases["half"] == (u_now >= 0.5)
        own = cases["account"] == acct
        act = cases["active"] == active
        for m in (near & own & act, near & act, near & own, near, half & act, half):
            if m.sum() >= MIN_CASES:
                return np.flatnonzero(m)
        m = near if near.sum() >= MIN_SPREAD_CASES else half
        return np.flatnonzero(m) if m.sum() >= MIN_SPREAD_CASES else None

    # ------------------------------------------------------------------
    def _case_table(self, acct, kind, cap):
        """Past cuts of every visible account's cycles of this meter, rebuilt
        when a new cycle has reset or a new day's conversion applies."""
        h = self.history
        accounts = [acct] + [a for a in h.accounts if a != acct]
        stamp = tuple((a, (spend.past_cycles(h, a, kind, cap) or [None])[-1] and
                       spend.past_cycles(h, a, kind, cap)[-1].reset) for a in accounts)
        key = (acct, kind, cap)
        day = spend.local_day_start(h, acct)
        hit = self._cases.get(key)
        if hit is not None and hit[0] == (stamp, day):
            return hit[1]
        parts = [build_cases(h, a, kind, cap, self.lookback, self.max_days) for a in accounts]
        parts = [p for p in parts if p is not None]
        table = None
        if parts:
            table = {c: np.concatenate([p[c] for p in parts]) for c in parts[0]}
        self._cases[key] = ((stamp, day), table)
        return table


# ----------------------------------------------------------------------
# The forecast for one moment, and the past cuts it learns from
# ----------------------------------------------------------------------

def state(h, acct, k, start, reset, t_last, used, now, lookback) -> dict:
    """now_value, burn (points per ms), ratio and the reading, for one cut."""
    def conv(t0, t1):
        return float(spend.spent_between(h, acct, t0, t1)[0] @ k)
    now_value = min(100.0, used + conv(t_last, now))
    cyc = conv(start, t_last)
    ratio = float(np.clip(used / cyc, 0.25, 4.0)) if cyc > 1 else 1.0
    span = min(lookback, now - start)
    burn = conv(now - span, now) / span if span > 0 else 0.0
    return {"now_value": now_value, "burn": burn, "ratio": ratio, "used": used}


def path(st, tau, lead):
    v = st["now_value"] + st["burn"] * st["ratio"] * tau * (1.0 - np.exp(-np.asarray(lead) / tau))
    return np.clip(v, st["used"], 100.0)


def build_cases(h, acct, kind, cap, lookback, max_days):
    """Every past cut of one account's cycles: phase, half, account, whether
    it was burning, the forecast's error at reset for each τ, and the forecast
    and the truth at FRACS of the time left. Each cut uses the conversion of
    its own day (no peeking past it) and only readings of its own cycle."""
    cycles = spend.past_cycles(h, acct, kind, cap)
    if not cycles:
        return None
    dur = window_ms(kind)
    lo = h.now - max_days * spend.DAY_MS
    complete_by = max(15 * MIN_MS, 0.05 * dur)
    today = spend.local_day_start(h, acct)
    rates: dict[int, np.ndarray | None] = {}
    rows = {c: [] for c in ("phase", "half", "account", "active", "ae", "centre", "truth")}
    taus = np.array(TAUS_H) * 3_600_000
    for c in cycles:
        if c.reset < lo or not len(c.t) or c.t[-1] < c.reset - complete_by:
            continue                      # too old, or its end was not seen
        final = float(c.util[-1])
        for u in PHASES:
            cut = int(c.start + u * dur)
            j = int(np.searchsorted(c.t, cut, "right")) - 1
            if j < 0 or cut - c.t[j] > spend.HOUR_MS:
                continue                  # no fresh reading of this cycle at the cut
            day = min(spend.local_day_start(h, acct, cut), today)
            if day not in rates:
                d = spend.fit_on_day(h, acct, kind, cap, day)
                rates[day] = None if d is None else d.rates
            k = rates[day]
            if k is None:
                continue
            used = float(c.util[j])
            st = state(h, acct, k, c.start, c.reset, int(c.t[j]), used, cut, lookback)
            left = c.reset - cut
            at = cut + FRACS * left
            idx = np.searchsorted(c.t, at, "right") - 1
            truth = np.where(idx >= 0, c.util[np.maximum(idx, 0)], used)
            truth[-1] = final
            cen = np.stack([path(st, tau, FRACS * left) for tau in taus])          # [taus, FRACS]
            rows["phase"].append(u)
            rows["half"].append(u >= 0.5)
            rows["account"].append(acct)
            rows["active"].append(st["burn"] > 0)
            rows["ae"].append(np.abs(cen[:, -1] - final))
            rows["centre"].append(cen)
            rows["truth"].append(truth)
    if not rows["phase"]:
        return None
    return {"phase": np.array(rows["phase"]), "half": np.array(rows["half"]),
            "account": np.array(rows["account"], dtype=object), "active": np.array(rows["active"]),
            "ae": np.stack(rows["ae"]), "centre": np.stack(rows["centre"]), "truth": np.stack(rows["truth"])}
