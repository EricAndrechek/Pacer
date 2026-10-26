"""Structural meter models (`models/struct-*`): spend paths from a child
spend model, turned into meter paths by the account's own spend-to-meter
conversion.

For each meter target (account, window, the cycle's reset):

1. `kit.spend.fit_conversion`: meter points per API-equivalent dollar, per
   model family, fitted on the 14 days before today (no peeking);
2. the start: `kit.spend.live_value` (the latest reading plus the converted
   spend since it), else the latest reading of this cycle;
3. ONE child call per forecast, through `ctx.model(child)` (the runner runs
   the child at this moment on this view): `spend.hourly` for each (account,
   family) with points per dollar, hourly to the latest reset, the family
   named on the request (the fm-*-spend models honour it);
   When the fit is weak (the app would show no live value: little rise or
   R² < 0.5), interval-level NNLS on integer meter steps gives unstable
   per-family rates (a one-point step in an interval with a few cents of one
   family reads as dozens of points per dollar). Then (`weak = "ratio"`) the
   rate is the account's total rise over its total spend in the same 14
   days, the same for every family (for a scoped cap, that cap's family);
   `weak = "fit"` keeps the weak fit;
4. meter path = start + Σ_family points_per_usd × cumulative spend, read at
   the grid (spend spread evenly within each hour), capped at 100. Spend is
   never negative and the rates never are, so paths never fall. The horizon
   ends at the reset, so nothing carries over it. `spend_by = "total"` (the
   default) asks for the account's whole spend instead, at one rate (the
   families' rates weighted by last week's spend mix): one dense series
   rather than several sparse ones, which scored better on the visible tier
   of both snapshots for the 5-hour and 7-day meters. A scoped cap's single
   family stays by family. With `spend_by = "family"`, family paths are paired
   by rank (`family_dependence = "comonotone"`, a heavy hour is heavy for
   every family) or as drawn (`"independent"`).

No conversion (nothing to fit) or a failed child: the meter now, flat.

`model.toml`: `children = ["fm-<x>-spend"]`, and `[config] child = "fm-<x>-spend"`.
"""
from __future__ import annotations

import math

import numpy as np

from arena.types import Forecast, Request, Target, TargetForecast, TargetRequest
from kit import spend as kspend
from kit.fm.meter_model import WINDOW_FOR
from kit.fm.paths import interp_times, monotone_meter
from kit.fm.series import DAY_MS, HOUR_MS, PriceCache, TurnFrame, meter_series
from kit.spend import FAMILIES

FIT_DAYS = 14


class StructModel:
    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.history = None
        self._conv: dict = {}
        self._prices = PriceCache()

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def conversion(self, account: str, wk: str, cap: str | None):
        """(fit, rates to use): refit once per day, as the app does (the fit
        only reads days before today's)."""
        key = (account, wk, cap, int(self.history.now) // DAY_MS)
        if key not in self._conv:
            conv = kspend.fit_conversion(self.history, account, wk, cap)
            rates = {f: v for f, v in (conv.points_per_usd.items() if conv else ()) if v > 0}
            if (conv is None or conv.weak) and self.cfg.get("weak", "ratio") == "ratio":
                rates = self._ratio(account, wk, cap) or rates
            self._conv[key] = (conv, rates)
        return self._conv[key]

    def _ratio(self, account: str, wk: str, cap: str | None) -> dict:
        """Total rise / total spend over the fit's 14 days, per family."""
        hi = (int(self.history.now) // DAY_MS) * DAY_MS
        lo = hi - FIT_DAYS * DAY_MS
        s = meter_series(self.history.table("meter_readings"), account, wk, cap, hi)
        if len(s) < 2:
            return {}
        rise = float(np.interp(hi, s.times, s.cum) - np.interp(lo, s.times, s.cum))
        tf = TurnFrame(_AsOf(self.history, hi), FIT_DAYS * 24, (account,), self._prices)
        fams = [cap.lower()] if cap and cap.lower() in FAMILIES else [f for f in FAMILIES if f in tf.families((account,))]
        spend = sum(float(tf.hourly((account,), "spend", f).sum()) for f in fams)
        if rise <= 0 or spend <= 0:
            return {}
        return {f: rise / spend for f in fams}

    def forecast(self, request):
        now = int(request.now)
        readings = self.history.table("meter_readings")
        plans, need = [], {}
        for tr in request.targets:
            wk = WINDOW_FOR.get(tr.target)
            if wk is None:
                continue
            acct = tr.accounts[0]
            cap = tr.cap if tr.target is Target.METER_SCOPED else None
            s = meter_series(readings, acct, wk, cap, now)
            used = s.used_now(tr.reset_at) if tr.reset_at is not None else None
            if used is None:
                used = float(s.cycle_util[s.active][-1]) if s.active.any() else 0.0
            conv, rates = self.conversion(acct, wk, cap)
            start = None
            if conv is not None and self.cfg.get("start", "live") == "live":
                start = kspend.live_value(self.history, acct, wk, cap)
            start = max(float(start), used) if start is not None else used
            hours = max(1, int(math.ceil((int(tr.grid[-1]) - now) / HOUR_MS)))
            # One family only (a scoped cap counts its own family): keep it by family.
            if len(rates) > 1 and self.cfg.get("spend_by", "total") == "total":
                rates = {None: self._blend(acct, rates)}
            for f in rates:
                need[(acct, f)] = max(need.get((acct, f), 0), hours)
            plans.append((tr, start, rates, hours))
        spend = self._child(request, need) if need else {}
        out = {}
        for tr, start, rates, hours in plans:
            out[tr.key] = self._meter(now, tr, start, rates, hours, spend)
        return Forecast(out)

    def _blend(self, account: str, rates: dict) -> float:
        """One rate for the account's total spend: the families' rates
        weighted by their share of its spend over the last week."""
        tf = TurnFrame(self.history, 7 * 24, (account,), self._prices)
        w = {f: float(tf.hourly((account,), "spend", f).sum()) for f in rates}
        tot = sum(w.values())
        if tot <= 0:
            return float(np.mean(list(rates.values())))
        return sum(rates[f] * w[f] for f in rates) / tot

    # ------------------------------------------------------------------
    @staticmethod
    def _key(acct: str, fam: str | None) -> str:
        return f"spend.hourly:{acct}" + (f":{fam}" if fam else "")

    def _child(self, request, need: dict) -> dict:
        now = int(request.now)
        trs = []
        for (acct, fam), hours in sorted(need.items(), key=lambda kv: (kv[0][0], kv[0][1] or "")):
            trs.append(TargetRequest(key=self._key(acct, fam), target=Target.SPEND_HOURLY,
                                     accounts=(acct,), grid=now + HOUR_MS * np.arange(1, hours + 1, dtype=np.int64),
                                     units="usd_per_hour", n_paths=int(self.cfg.get("child_paths", 200)),
                                     family=fam))
        try:
            fc = self.ctx.model(self.cfg["child"]).forecast(Request(now, request.scope, tuple(trs)))
        except Exception as e:  # noqa: BLE001 - a failed child leaves the meter flat, and says so
            self.ctx.log(f"child {self.cfg.get('child')} failed: {type(e).__name__}: {str(e)[:300]}")
            return {}
        return {k: (acct, fam, fc.by_key[self._key(acct, fam)].paths)
                for k, (acct, fam) in enumerate(need) if self._key(acct, fam) in fc.by_key}

    def _meter(self, now, tr, start, rates, hours, spend) -> TargetForecast:
        grid = np.asarray(tr.grid, dtype=np.int64)
        acct = tr.accounts[0]
        fams = [(fam, P) for (a, fam, P) in spend.values() if a == acct and fam in rates]
        if not fams or start >= 100.0:
            return TargetForecast.point(np.full(len(grid), min(start, 100.0)), tr.n_paths)
        n = min(min(P.shape[0] for _, P in fams), tr.n_paths)
        t_rel = HOUR_MS * np.arange(0, hours + 1, dtype=np.float64)
        g_rel = (grid - now).astype(np.float64)
        total = np.zeros((n, len(grid)))
        comonotone = self.cfg.get("family_dependence", "comonotone") == "comonotone"
        for fam, P in fams:
            P = np.maximum(np.asarray(P, dtype=np.float64)[:, :hours], 0.0)
            if comonotone:
                P = P[np.argsort(P.sum(axis=1))]
            P = P[np.linspace(0, P.shape[0] - 1, n).round().astype(int)]
            cum = np.concatenate([np.zeros((n, 1)), np.cumsum(P, axis=1)], axis=1)          # [n, hours + 1]
            total += rates[fam] * interp_times(t_rel, g_rel, cum.T).T
        if comonotone:
            total = total[self.rng.permutation(n)]
        return TargetForecast(monotone_meter(start + total, start))


class _AsOf:
    """A history read as if `now` were an earlier moment (the fit window's
    end): only `now` changes, every row is still one known by the real now."""

    def __init__(self, history, now: int):
        self._h, self.now = history, int(now)

    def table(self, name):
        return self._h.table(name)
