"""Online exponentially weighted averaging of foundation models.

Combines top foundation models (Timestral-209M, Chronos2, Moirai2) using
exponentially weighted averaging based on recent forecast performance.
Weights are updated as truth arrives, giving more recent performance higher weight.
Faster adaptation than stacking, suitable for changing conditions.
"""
from __future__ import annotations

from kit.ml.combine import Combiner, ewa_weights


class Model(Combiner):
    rule = "ewa"
    default_pool = "mixture"
    uses_backtest = False

    def weights_for(self, kind, tr, children, paths, now):
        groups = self.ledger.scored(kind, before=now)
        return ewa_weights(groups, children, pool=self.pool_kind,
                          half_life=self.half_life(kind))
