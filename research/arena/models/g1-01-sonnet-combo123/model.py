"""Exponentially weighted averaging of fm-timestral-123m-meter and
fm-timestral-209m-meter.

These two foundation model variants have complementary strengths:
- timestral-123m: stronger overall, smaller context size
- timestral-209m: larger model, different calibration

The EWA combiner adapts online as meter readings arrive, giving more weight
to whichever child has been more accurate recently.
"""
from __future__ import annotations

from kit.ml.combine import Combiner, ewa_weights


class Model(Combiner):
    rule = "ewa"
    default_pool = "mixture"

    def weights_for(self, kind, tr, children, paths, now):
        groups = self.ledger.scored(kind, before=now)
        return ewa_weights(groups, children, now, eta=float(self.cfg.get("eta", 0.3)),
                           half_life=self.half_life(kind))
