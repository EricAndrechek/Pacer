"""Simplex-weighted stacking of fm-timestral-123m-meter and fm-timesfm25-meter.

These two are the best individual meter models from different model families
(Mistral's Timestral vs Google's TimesFM). Their errors are likely partially
independent, so a careful mixture should reduce variance.

Weights are updated using the `stack_weights` function which minimizes the
combined CRPS over past forecasts (those made without seeing what followed,
via ctx.backtest). High shrinkage (0.1) keeps weights close to equal when
little evidence exists; as forecasts accumulate, weights adapt.
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
                             shrink=float(self.cfg.get("shrink", 0.1)))
