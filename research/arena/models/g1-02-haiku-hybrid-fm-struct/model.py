"""Hybrid FM + structural ensemble with learned stacking.

Combines direct meter forecasts from foundation models with structural models
that forecast spend and convert it to meter readings. This hybrid approach
provides complementary views: FMs focus on meter patterns directly, while
structural models capture spend patterns and account behavior.
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
