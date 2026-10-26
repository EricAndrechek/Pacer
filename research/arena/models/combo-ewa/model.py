"""Online exponentially weighted averaging (EWA) of the children.

Each child's forecasts over the parent's past (`ctx.backtest`, made without
hindsight) and its forecasts during this episode are scored against the
readings known now (`kit.ml.combine.Ledger`); the weight of child i is
proportional to exp(-eta × Σ_k d_k ℓ_ik), where ℓ_ik is its CRPS on forecast
k relative to the children's mean there, weighted by the share of its span
the truth covers so far, and d_k halves every `half_life_n` newer forecasts
of the kind (forgetting by evidence, not by the clock). As truth arrives
(`update`), the losses grow and the weights move. The children's paths are pooled with those weights
(`pool`: a linear pool by default).
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
