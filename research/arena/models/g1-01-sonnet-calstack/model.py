"""Stack of calibrated timestral-123m + timesfm25.

g1-01-sonnet-calibrate123 wraps fm-timestral-123m-meter with a learned
spread-scale calibration. fm-timesfm25-meter is from a different architecture
(Google TimesFM vs Mistral Timestral). Their errors should be partially
independent, allowing a CRPS-minimizing stack to outperform either alone.
"""
from __future__ import annotations

from kit.ml.combine import Combiner, stack_weights


class Model(Combiner):
    rule = "stack"
    default_pool = "mixture"

    def weights_for(self, kind, tr, children, paths, now):
        groups = self.ledger.scored(kind, before=now)
        return stack_weights(groups, children, now,
                             pool=self.pool_kind,
                             half_life=self.half_life(kind),
                             shrink=float(self.cfg.get("shrink", 0.15)))
