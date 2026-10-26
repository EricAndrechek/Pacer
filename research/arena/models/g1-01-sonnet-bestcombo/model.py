"""EWA combination using the best available meter models.

Children:
- fm-timestral-123m-meter: best individual model (crps=0.988, 0.812, 0.799)
- fm-timestral-209m-meter: second best (crps=1.115, 0.835, 0.843)
- ml-qrf: ML model with complementary error structure (different inductive bias)

The EWA weights adapt online as readings arrive. With the best individual
model as a child, the combo should match or beat it while also benefiting
from the diversity of the other models.

Key advantage over existing combo-ewa (which uses weaker children like
struct-timestral-28m): by using the two top FM models, the starting quality
is much higher. Even with equal weights, the ensemble average should be
competitive with the best individual.
"""
from __future__ import annotations

from kit.ml.combine import Combiner, ewa_weights


class Model(Combiner):
    rule = "ewa"
    default_pool = "mixture"

    def weights_for(self, kind, tr, children, paths, now):
        groups = self.ledger.scored(kind, before=now)
        return ewa_weights(groups, children, now, eta=float(self.cfg.get("eta", 0.5)),
                           half_life=self.half_life(kind))
