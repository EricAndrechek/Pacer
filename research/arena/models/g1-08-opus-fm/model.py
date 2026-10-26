"""g1-08-opus-fm: pretrained forecasters, recalibrated on the user's own past.

See REPORT.md.
- meters: `meters.MeterFM` (Timestral on the cumulative burn, quantile-
  recalibrated per lead from self-backtests on the history);
- split.accounts: `split` (regime persistence with meter-limit blocking);
- cycle.next_start: `nextstart` (weighted analogues of past idle moments);
- spend.hourly, tokens.hourly: `hourly` (pretrained children, Vincentized).
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast

from hourly import HOURLY, forecast_hourly, vincentize
from meters import WINDOW_FOR, MeterFM
from nextstart import forecast_next_start
from spendfm import SpendFM
from split import forecast_split


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.history = None
        self.meters = MeterFM(dict(self.cfg.get("meter", {})), ctx.rng, ctx.log)
        self.spend = SpendFM(dict(self.cfg.get("spend", {})), ctx.rng, ctx.log)

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        now = int(request.now)
        out = {}
        splits, hourly = [], []
        for tr in request.targets:
            if tr.target in WINDOW_FOR:
                out[tr.key] = self.meters.forecast(self.history, now, tr)
            elif tr.target is Target.CYCLE_NEXT_START:
                out[tr.key] = TargetForecast(forecast_next_start(self.history, now, tr,
                                                                 dict(self.cfg.get("next_start", {})), self.rng))
            elif tr.target is Target.SPLIT:
                splits.append(tr)
            elif tr.target in HOURLY:
                hourly.append(tr)
        blend = dict(self.cfg.get("meter_blend", {}))      # window -> [child, weight of the child]
        if blend:
            self._blend(request, out, blend)
        if hourly and self.cfg.get("hourly_mode", "fm") == "fm":
            out.update(self.spend.forecast(self.history, now, hourly))
        elif hourly:
            out.update(forecast_hourly(self.ctx, request, hourly, dict(self.cfg.get("hourly", {})),
                                       self.rng, self.ctx.log))
        if splits:
            group = tuple(request.scope.accounts)
            res = forecast_split(self.history, now, splits, group, dict(self.cfg.get("split", {})), self.rng)
            for tr in splits:
                out[tr.key] = TargetForecast(np.asarray(res[tr.key], dtype=np.float64))
        return Forecast(out)

    def _blend(self, request, out, blend):
        """Meter paths averaged rank by rank with a child's (the FM's copula kept)."""
        from arena.types import Request
        trs = [tr for tr in request.targets if tr.target in WINDOW_FOR and WINDOW_FOR[tr.target] in blend]
        by_child = {}
        for tr in trs:
            by_child.setdefault(blend[WINDOW_FOR[tr.target]][0], []).append(tr)
        for child, ts in by_child.items():
            try:
                fc = self.ctx.model(child).forecast(Request(request.now, request.scope, tuple(ts)))
            except Exception as e:  # noqa: BLE001 - without the child the FM's paths stand
                self.ctx.log(f"blend child {child} failed: {type(e).__name__}: {str(e)[:200]}")
                continue
            for tr in ts:
                if tr.key not in fc.by_key or tr.key not in out:
                    continue
                w = float(blend[WINDOW_FOR[tr.target]][1])
                mine = out[tr.key].paths
                P = vincentize([mine, fc.by_key[tr.key].paths], [1.0 - w, w], tr.n_paths, self.rng)
                lo = mine.min()
                out[tr.key] = TargetForecast(np.maximum.accumulate(np.clip(P, lo, 100.0), axis=1))
