"""Path-pool mixture over children. For each target the paths of every
child that answered are pooled in fixed shares (model.toml), each child's
contribution drawn without replacement from its own paths (a point forecast
is repeated). Mixing two differently-built calibrated ensembles usually
lowers CRPS; nothing is learned here, so it cannot overfit the visible tier.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Target, TargetForecast


class Model:
    def __init__(self, ctx):
        self.ctx = ctx
        self.rng = ctx.rng
        self.shares = ctx.config.get("shares", {})
        self.children = list(ctx.children)

    def fit(self, history):
        pass

    def update(self, events):
        pass

    def forecast(self, request):
        got = {}
        for c in self.children:
            try:
                got[c] = self.ctx.model(c).forecast(request)
            except Exception as e:  # noqa: BLE001
                self.ctx.log(f"child {c} failed: {type(e).__name__}: {str(e)[:200]}")
        out = {}
        for tr in request.targets:
            shares = dict(self.shares.get(str(tr.target), {}))
            avail = {c: got[c].by_key[tr.key] for c in shares
                     if c in got and tr.key in got[c].by_key and shares[c] > 0}
            if not avail:
                # anything that answered
                anyc = [c for c in got if tr.key in got[c].by_key]
                if not anyc:
                    continue
                avail = {anyc[0]: got[anyc[0]].by_key[tr.key]}
                shares = {anyc[0]: 1.0}
            tot = sum(shares[c] for c in avail)
            n = tr.n_paths
            counts = {c: int(round(n * shares[c] / tot)) for c in avail}
            # fix rounding so the counts sum to n
            diff = n - sum(counts.values())
            first = next(iter(counts))
            counts[first] += diff
            parts = []
            for c, tf in avail.items():
                k = counts[c]
                if k <= 0:
                    continue
                p = np.asarray(tf.paths, dtype=np.float64)
                if p.shape[0] >= k:
                    idx = self.rng.choice(p.shape[0], size=k, replace=False)
                else:
                    idx = self.rng.choice(p.shape[0], size=k, replace=True)
                parts.append(p[idx])
            P = np.concatenate(parts, axis=0)
            if tr.target in (Target.METER_5H, Target.METER_7D, Target.METER_SCOPED):
                P = np.clip(P, 0.0, 100.0)
            out[tr.key] = TargetForecast(P)
        return Forecast(out)
