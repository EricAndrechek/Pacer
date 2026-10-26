"""FFORMA-style combination (Montero-Manso et al., 2020): weights predicted
from features.

Training rows are the children's past forecasts (`ctx.backtest` origins and
this episode's checkpoints) once their truth has started to arrive, pooled
over every target kind. Each row's features are the as-of features at its
origin (`kit.ml.features`: phase, used, burn, converted spend, activity left,
time of day, idle time, past phase rise), the children's disagreement there,
and the kind; its target is each child's CRPS relative to the children's
mean. The map is softmax(W x), fitted by FFORMA's loss (the expected
relative loss under the weights) with an L2 penalty; at forecast time the
features at now give the weights.
"""
from __future__ import annotations

import numpy as np

from kit.ml.combine import Combiner, FformaWeights, discount, relative_losses


class Model(Combiner):
    rule = "fforma"
    default_pool = "mixture"

    def __init__(self, ctx):
        super().__init__(ctx)
        self._x: dict = {}
        self._builders: dict = {}
        self._fit_key = None
        self.meta = None

    def update(self, events):
        super().update(events)
        self._builders = {}

    def _kinds(self):
        return sorted({g.kind for g in self.ledger.groups.values()})

    def _features(self, g):
        k = (g.origin, g.key)
        if k not in self._x:
            qs = [e.q for e in g.entries.values()]
            self._x[k] = self.meta.features(self.data, self._builders, g.kind, g.target, g.account, g.cap,
                                            g.origin, g.reset, FformaWeights.spread(qs))
        return self._x[k]

    def _train(self, now):
        kinds = self._kinds()
        key = (now, tuple(kinds))
        if self._fit_key == key:
            return
        self._fit_key = key
        if self.meta is None or self.meta.kinds != kinds:
            self.meta = FformaWeights(self.children, kinds, lam=float(self.cfg.get("lam", 1.0)),
                                      half_life=float(self.cfg.get("half_life_n", 48)))
            self._x = {}
        groups = [g for g in self.ledger.groups.values() if len(g.y) and g.origin < now]
        R = relative_losses(groups, self.children)
        rows, keep = [], []
        for i, g in enumerate(groups):
            x = self._features(g) if np.isfinite(R[i]).all() else None
            if x is not None:
                rows.append(x)
                keep.append(i)
        if len(keep) < int(self.cfg.get("min_groups", 8)):
            self.meta.W = None
            return
        d = discount([groups[i] for i in keep], now, self.meta.half_life)
        self.meta.fit(np.asarray(rows), R[keep], d)

    def weights_for(self, kind, tr, children, paths, now):
        if self.meta is None or self._fit_key is None or self._fit_key[0] != now:
            self._train(now)
        qs = [np.sort(p, axis=0) for p in paths]
        x = self.meta.features(self.data, self._builders, kind, tr.target, tr.accounts[0], tr.cap, now,
                               tr.reset_at, FformaWeights.spread(qs)) if kind in self.meta.kinds else None
        w_all = self.meta.weights(x)
        w = np.array([w_all[self.children.index(c)] for c in children])
        return w / w.sum() if w.sum() > 0 else np.full(len(children), 1.0 / len(children))
