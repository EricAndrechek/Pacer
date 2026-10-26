"""A quantile regression forest whose paths are whole past futures.

Training (from the history only, `kit.ml.walkforward`): past cutoffs with
their as-of features, each labelled with the meter's rise to eight leads
(fractions of the time then left to the reset), kept only when every lead was
already known at `now`. One multi-output random forest is fitted to the rise
vectors.

Forecast: Meinshausen's QRF weights (a training row's share of each tree's
leaf that the query falls in, averaged over trees) over the training rows,
then `n_paths` rows drawn by weight; each path is that row's own rise
trajectory, read on the grid by lead fraction. Each grid time's marginal is
the QRF quantile estimate, and the paths keep real shapes (a burst then a
plateau stays one), which per-time quantiles glued comonotonically do not.

`target = "frac"` scales an analog's rise to the query's headroom instead of
carrying it over in points.
"""
from __future__ import annotations

import numpy as np

from arena.types import TargetForecast
from kit.ml.features import F
from kit.ml.meter_model import LearnedMeterModel
from kit.ml.paths import sample_rise_paths


class Model(LearnedMeterModel):
    name = "ml-qrf"

    def train(self, ts, kind):
        from sklearn.ensemble import RandomForestRegressor
        keep = ts.complete()
        if keep.sum() < int(self.cfg.get("min_rows", 60)):
            return None
        X, Y = ts.X[keep], ts.Y[keep]
        frac = self.cfg.get("target", "delta") == "frac"
        if frac:
            Y = Y / np.maximum(ts.headroom[keep], 1.0)[:, None]
        # A weekly cycle yields dozens of near-identical cutoffs: bigger
        # leaves, or a leaf is one cycle and its future the whole forecast.
        leaf = self.cfg.get("weekly_min_samples_leaf" if kind != "five_hour" else "min_samples_leaf", 8)
        rf = RandomForestRegressor(n_estimators=int(self.cfg.get("n_estimators", 200)),
                                   min_samples_leaf=int(leaf),
                                   max_features=float(self.cfg.get("max_features", 0.4)),
                                   n_jobs=2, random_state=int(self.ctx.seed % (2 ** 31)))
        rf.fit(X, Y)
        leaves = rf.apply(X)                                   # [n, trees]
        sizes = [np.bincount(leaves[:, t]) for t in range(leaves.shape[1])]
        return {"rf": rf, "leaves": leaves, "sizes": sizes, "Y": Y, "frac": frac, "leads": ts.leads}

    def weights(self, state, row):
        q = state["rf"].apply(row[None, :])[0]                 # [trees]
        L = state["leaves"]
        w = np.zeros(L.shape[0])
        for t, leaf in enumerate(q):
            hit = L[:, t] == leaf
            n = state["sizes"][t][leaf] if leaf < len(state["sizes"][t]) else 0
            if n:
                w[hit] += 1.0 / n
        s = w.sum()
        return w / s if s > 0 else np.full(L.shape[0], 1.0 / L.shape[0])

    def predict(self, state, row, lead_X, fracs, grid_fracs, used, n_paths, rng):
        w = self.weights(state, row)
        pick = rng.choice(len(w), size=n_paths, replace=True, p=w)
        rise = state["Y"][pick]
        if state["frac"]:
            rise = rise * max(row[F["headroom"]], 0.0)
        return TargetForecast(sample_rise_paths(rise, state["leads"], grid_fracs, used))
