"""Learned stacking of foundation model spend forecasters.

Combines Timestral spend models at different scales (209M, 28M, 5M) with
per-target adaptive simplex weights optimized for CRPS. Weights adapt as
truth arrives to emphasize models that perform well on current data.
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
