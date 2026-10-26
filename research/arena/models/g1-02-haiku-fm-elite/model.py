"""Elite foundation model ensemble with quantile pooling.

Combines the top 3 foundation models (Timestral-209M, Chronos2, Moirai2) with
a structural model for backup/diversity. Uses quantile pooling (Vincentization)
to combine quantile-based forecasts, which can preserve calibration better than
mixture pooling in some settings.
"""
from __future__ import annotations

from kit.ml.combine import Combiner, stack_weights


class Model(Combiner):
    rule = "stack"
    default_pool = "quantile"

    def weights_for(self, kind, tr, children, paths, now):
        groups = self.ledger.scored(kind, before=now)
        return stack_weights(groups, children, now, pool=self.pool_kind,
                             half_life=self.half_life(kind), shrink=float(self.cfg.get("shrink", 0.05)))
