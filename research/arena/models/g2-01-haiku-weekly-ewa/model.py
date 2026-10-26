"""EWA combination of Timestral variants, tuned for weekly forecasting.

Uses exponentially weighted averaging based on past CRPS, with parameters
optimized for the seven_day horizon (weekly budget windows).
"""
from __future__ import annotations

from kit.ml.combine import Combiner, ewa_weights


class Model(Combiner):
    rule = "ewa"
    default_pool = "mixture"

    def weights_for(self, kind, tr, children, paths, now):
        groups = self.ledger.scored(kind, before=now)
        return ewa_weights(groups, children, now, eta=float(self.cfg.get("eta", 0.15)),
                           half_life=self.half_life(kind))
