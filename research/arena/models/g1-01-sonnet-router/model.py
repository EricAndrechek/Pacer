"""Target-aware router with ML-guided delegation and fallback.

Primary routing:
- five_hour, scoped → g1-01-sonnet-cqr (LightGBM, crps~0.66 when data ≥20 cycles)
- seven_day → g1-01-sonnet-calibrate123 (calibrated timestral-123m)

Fallback (when CQR lacks sufficient training data):
- five_hour, scoped → g1-01-sonnet-calibrate123

This gives best-of-both-worlds: CQR's strong ML predictions when data is rich,
calibrated FM predictions when data is sparse.
"""
from __future__ import annotations

from arena.types import Forecast, Target


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.cfg = dict(ctx.config)
        self.child_ml = str(self.cfg.get("ml_child", "g1-01-sonnet-cqr"))
        self.child_fm = str(self.cfg.get("fm_child", "g1-01-sonnet-calibrate123"))
        # Targets handled by ML model (with FM fallback)
        self._ml_targets = {Target.METER_5H, Target.METER_SCOPED}
        # Targets always handled by FM model
        self._fm_targets = {Target.METER_7D}

    def fit(self, history):
        pass

    def update(self, events):
        pass

    def forecast(self, request):
        ml_fc: Forecast | None = None
        fm_fc: Forecast | None = None

        ml_needed = any(tr.target in self._ml_targets for tr in request.targets)
        fm_needed = any(tr.target in self._fm_targets | self._ml_targets for tr in request.targets)

        if ml_needed:
            try:
                ml_fc = self.ctx.model(self.child_ml).forecast(request)
            except Exception as e:
                self.ctx.log(f"{self.child_ml} failed: {type(e).__name__}: {str(e)[:200]}")

        if fm_needed:
            try:
                fm_fc = self.ctx.model(self.child_fm).forecast(request)
            except Exception as e:
                self.ctx.log(f"{self.child_fm} failed: {type(e).__name__}: {str(e)[:200]}")

        out = {}
        for tr in request.targets:
            if tr.target in self._ml_targets:
                # Try ML first, fall back to FM
                if ml_fc is not None:
                    tf = ml_fc.by_key.get(tr.key)
                    if tf is not None:
                        out[tr.key] = tf
                        continue
                if fm_fc is not None:
                    tf = fm_fc.by_key.get(tr.key)
                    if tf is not None:
                        out[tr.key] = tf
            elif tr.target in self._fm_targets:
                if fm_fc is not None:
                    tf = fm_fc.by_key.get(tr.key)
                    if tf is not None:
                        out[tr.key] = tf

        return Forecast(out)
