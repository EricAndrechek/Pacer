"""All-Timestral ensemble with learned stacking.

Combines all four Timestral model sizes (209M, 123M, 28M, 5M) to benefit from
both the accuracy of larger models and the robustness/generalization of smaller ones.
Weights are learned per target type using CRPS optimization on historical forecasts.
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
