"""Learned stacking of foundation models with CRPS optimization.

Combines top foundation models (Timestral 209M, Chronos2, Moirai2) using
per-target adaptive simplex weights that minimize CRPS over backtested forecasts.
Weights are refitted as truth arrives, with shrinkage toward equal weights.
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
