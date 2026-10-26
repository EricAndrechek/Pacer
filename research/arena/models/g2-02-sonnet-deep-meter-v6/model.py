"""Deep ensemble v6 — conservative routing, scope_only-robust.

Problem: visible-test episodes are predominantly scope_only (low global usage).
In scope_only, fm-timestral-209m outperforms calibrate123 for BOTH five_hour and
seven_day in backtest, getting 0.79-0.82 weight despite worse leaderboard CRPS:
  calibrate123: five_hour=0.895  seven_day=0.745   (BEST)
  fm-timesfm25: five_hour=0.999  seven_day=1.010
  fm-209m:      five_hour=1.115  seven_day=0.843

Solution: exclude 209m from both five_hour and seven_day stacks.
Use only calibrate123+timesfm25 for both. The two models have:
- Different architectures (Timestral 123M vs TimesFM 2.5/Google)
- Maximum CRPS diversity relative to their quality tier
- Scope_only-robust: even in scope_only, timesfm25 is close to calibrate123

Routing:
  five_hour: calibrate123+timesfm25 stack (exclude 209m, decay-1d)
  seven_day: calibrate123+timesfm25 stack (exclude 209m, decay-1d)
  scoped:    spend-decay-1d=1.0 (best single-model, CRPS=0.500)

Expected CRPS:
  five_hour: 0.87-0.93 (mixture of two best diverse models)
  seven_day: 0.73-0.80 (mixture of two best diverse models)
  scoped:    ~0.500 (pure decay-1d)
"""
from __future__ import annotations

import numpy as np

from kit.ml.combine import Combiner, stack_weights

_SPEND_DECAY_1D = "spend-decay-1d"
_FM_209M = "fm-timestral-209m-meter"

# Both five_hour and seven_day: use only calibrate123+timesfm25
# Exclude 209m (scope_only bias) and decay-1d (wrong target type)
_FM_EXCLUDE = frozenset([_SPEND_DECAY_1D, _FM_209M])


class Model(Combiner):
    rule = "stack"
    default_pool = "mixture"

    def weights_for(self, kind, tr, children, paths, now):
        if "weekly_scoped" in kind:
            return self._scoped_weights(children)

        # five_hour and seven_day: use only calibrate123+timesfm25
        fm = [c for c in children if c not in _FM_EXCLUDE]
        if not fm:
            return np.full(len(children), 1.0 / len(children))

        groups = self.ledger.scored(kind, before=now)
        fm_w = stack_weights(groups, fm, now, pool=self.pool_kind,
                             half_life=self.half_life(kind),
                             shrink=float(self.cfg.get("shrink", 0.10)))
        fm_dict = dict(zip(fm, fm_w))
        return np.array([fm_dict.get(c, 0.0) for c in children])

    def _scoped_weights(self, children):
        # spend-decay-1d alone is the best scoped model (CRPS=0.500).
        if _SPEND_DECAY_1D in children:
            return np.array([1.0 if c == _SPEND_DECAY_1D else 0.0 for c in children])
        return np.full(len(children), 1.0 / len(children))
