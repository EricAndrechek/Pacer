"""Account split forecasting using FM spend models.

Combines foundation model spend forecasters (Timestral-209M and 28M) for
computing the focal account's share of group spending. Learned stacking with
mixture pooling adapts weights based on historical forecast accuracy for
different account types and spending patterns.
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
