"""Fixed-scale calibration of fm-timestral-123m-meter.

fm-timestral-123m has cover50=0.862 (ideal: 0.50) and cover80=0.955.
Its intervals are too wide. Applying a fixed scale of 0.60 brings
the expected cover50 from 0.86 toward 0.50 without any training cost.

The scale is applied: path_adj = median + 0.60 * (path - median)

No backtesting required - this is a pure analytical calibration based
on the known bias of the child model on the visible tier.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast

METER_TARGETS = {Target.METER_5H, Target.METER_7D, Target.METER_SCOPED}


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.child = str(self.cfg.get("child", "fm-timestral-123m-meter"))
        self.scale = float(self.cfg.get("scale", 0.60))

    def fit(self, history):
        pass

    def update(self, events):
        pass

    def forecast(self, request):
        try:
            child_fc = self.ctx.model(self.child).forecast(request)
        except Exception as e:
            self.ctx.log(f"child failed: {type(e).__name__}: {str(e)[:200]}")
            return Forecast({})

        s = self.scale
        out = {}
        for tr in request.targets:
            if tr.target not in METER_TARGETS:
                continue
            tf = child_fc.by_key.get(tr.key)
            if tf is None:
                continue
            if abs(s - 1.0) < 1e-6:
                out[tr.key] = tf
                continue
            paths = np.asarray(tf.paths, dtype=np.float64)
            med = np.median(paths, axis=0)
            paths_adj = med[None, :] + s * (paths - med[None, :])
            paths_adj = np.clip(paths_adj, 0.0, 100.0)
            out[tr.key] = TargetForecast(paths_adj)

        return Forecast(out)
