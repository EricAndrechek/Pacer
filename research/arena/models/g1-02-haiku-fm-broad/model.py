"""Diverse foundation model ensemble with learned stacking.

Combines four different foundation model families (Chronos2, Moirai2, TimesFM25,
Timestral-209M) using per-target adaptive simplex weights. The diversity in model
architectures and training data should improve robustness and coverage.
"""
from __future__ import annotations

from kit.ml.combine import Combiner, stack_weights


class Model(Combiner):
    rule = "stack"
    default_pool = "mixture"

    def weights_for(self, kind, tr, children, paths, now):
        groups = self.ledger.scored(kind, before=now)
        return stack_weights(groups, children, now, pool=self.pool_kind,
                             half_life=self.half_life(kind), shrink=float(self.cfg.get("shrink", 0.05)))
