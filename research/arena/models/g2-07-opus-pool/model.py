"""g2-07-opus-pool: the limit simulator pooled with a pretrained meter model.

`g2-07-opus-limit` calls the limit well where the account's own habits
decide it (parking short of 100, re-bases, how long an idle account stays
idle); `fm-timestral-5m-meter` reads the recent shape of the meter well (when a
climb reaches 100, plateaus after a burst). Their paths are pooled per
target: a share `w` of the request's paths comes from the pretrained model,
the rest from the simulator. A linear pool of two calibrated forecasts can
only lower Brier and CRPS against the average of the two, and it is where
their errors differ (the limit call and the timing) that it gains most.
If a child fails, the other's paths stand alone.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast

WINDOW_OF = {Target.METER_5H: "five_hour", Target.METER_7D: "seven_day", Target.METER_SCOPED: "weekly_scoped"}


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.rng = ctx.rng
        self.sim = self.cfg.get("sim", "g2-07-opus-limit")
        self.fm = self.cfg.get("fm", "fm-timestral-5m-meter")

    def fit(self, history):
        pass

    def update(self, events):
        pass

    def _child(self, name, request):
        try:
            return self.ctx.model(name).forecast(request).by_key
        except Exception as ex:  # noqa: BLE001 - one child down is not the forecast down
            self.ctx.log(f"{name} failed: {type(ex).__name__}: {ex}")
            return {}

    def forecast(self, request):
        trs = tuple(tr for tr in request.targets if tr.target in WINDOW_OF)
        if not trs:
            return Forecast({})
        from dataclasses import replace
        req = replace(request, targets=trs)
        a = self._child(self.sim, req)
        b = self._child(self.fm, req)
        weights = self.cfg.get("fm_weight", {})
        out = {}
        for tr in trs:
            pa, pb = a.get(tr.key), b.get(tr.key)
            if pa is None and pb is None:
                continue
            if pa is None or pb is None:
                out[tr.key] = TargetForecast(np.asarray((pa or pb).paths, dtype=np.float64))
                continue
            n = tr.n_paths
            w = float(weights.get(WINDOW_OF[tr.target], 0.5))
            k = int(round(w * n))
            A = np.asarray(pa.paths, dtype=np.float64)
            B = np.asarray(pb.paths, dtype=np.float64)
            ia = self.rng.choice(A.shape[0], size=n - k, replace=A.shape[0] < n - k)
            ib = self.rng.choice(B.shape[0], size=k, replace=B.shape[0] < k)
            out[tr.key] = TargetForecast(np.vstack([A[ia], B[ib]]))
        return Forecast(out)
