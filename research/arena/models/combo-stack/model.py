"""Per-target stacking of the children.

For each target kind, the weights on the simplex that minimize the
discounted mean CRPS of the pooled forecast itself over every past forecast
the children made (`ctx.backtest` origins and this episode's checkpoints,
each scored on the readings known now). For a mixture pool the CRPS is
Σ w_i E|X_i - y| - ½ Σ w_i w_j E|X_i - X_j|: a convex quadratic in the
weights, solved exactly; for a quantile pool, the CRPS of the averaged
sorted samples. Refitted at every forecast as truth arrives.
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
