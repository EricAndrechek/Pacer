"""Every target, each from the ensemble that is best at it.

A router, not a forecaster: it asks its children in the order given and keeps
the first answer for each key. `g1-05-opus-ens-meter` answers the three meter
targets, `g1-05-opus-ens-hourly` the two hourly ones, and the naive models
cover `split.accounts` and `cycle.next_start`, where no ensemble has anything
to combine (one model each exists). Keeping them here means one model can be
scored on the whole board, and the preference list is the only thing to
change when a better child arrives.
"""
from __future__ import annotations

from arena.types import Forecast


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.order = [str(c) for c in (ctx.config.get("order") or getattr(ctx, "children", ()) or ())]

    def fit(self, history):
        pass

    def update(self, events):
        pass

    def forecast(self, request):
        out = {}
        wanted = {tr.key for tr in request.targets}
        for name in self.order:
            if wanted <= set(out):
                break
            try:
                fc = self.ctx.model(name).forecast(request)
            except Exception as e:  # noqa: BLE001 - fall through to the next child
                self.ctx.log(f"child {name} failed: {type(e).__name__}: {str(e)[:160]}")
                continue
            for k, tf in fc.by_key.items():
                if k in wanted and k not in out:
                    out[k] = tf
        return Forecast(out)
