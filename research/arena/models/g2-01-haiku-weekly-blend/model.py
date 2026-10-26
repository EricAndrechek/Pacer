"""EWA ensemble of weekly-optimized Timestral variants.

Adaptively combines 209m (strongest), 123m, and 28m models tuned for
seven_day forecasting, using exponentially weighted averaging based on
past performance.
"""
from __future__ import annotations

from kit.ml.combine import Combiner, ewa_weights


class Model(Combiner):
    rule = "ewa"
    default_pool = "mixture"

    def weights_for(self, kind, tr, children, paths, now):
        groups = self.ledger.scored(kind, before=now)
        return ewa_weights(groups, children, now, eta=float(self.cfg.get("eta", 0.2)),
                           half_life=self.half_life(kind))
