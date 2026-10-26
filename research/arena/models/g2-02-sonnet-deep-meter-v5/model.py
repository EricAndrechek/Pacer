"""Deep ensemble v5 — target-specific routing based on leaderboard evidence.

Leaderboard CRPS (from SCORES.md, run b58f7cb499524404 + earlier runs):

  calibrate123:     five_hour=0.895  seven_day=0.745  scoped=0.879
  fm-timesfm25:     five_hour=0.999  seven_day=1.010  scoped=0.844
  fm-209m:          five_hour=1.115  seven_day=0.843  scoped=0.835
  spend-decay-1d:                    seven_day=1.115  scoped=0.500
  pool-scoped:                                        scoped=0.508  (decay+analog)

Routing design:

meter.five_hour:
  calibrate123 + timesfm25 only (exclude 209m and decay-1d).
  209m has worse five_hour CRPS (1.115) and in visible-test episodes (often
  scope_only) gets misleadingly high backtest weight (0.816). Excluding it
  forces the optimizer to choose between the two best diverse models.

meter.seven_day:
  calibrate123 + timesfm25 + 209m. 209m (0.843) is competitive here and
  provides diversity. decay-1d excluded: tracks scoped spend, not global usage.

meter.scoped:
  spend-decay-1d at 100% weight. Leaderboard CRPS=0.500 (best single model).
  pool-scoped (decay=0.90, analog=0.10) gets 0.508 — slightly worse because
  analog (CRPS=2.036) adds noise without enough diversity to compensate.
"""
from __future__ import annotations

import numpy as np

from kit.ml.combine import Combiner, stack_weights

_SPEND_DECAY_1D = "spend-decay-1d"
_FM_209M = "fm-timestral-209m-meter"

# five_hour: exclude 209m (misleading in scope_only) and decay-1d (wrong target type)
_FIVE_HOUR_EXCLUDE = frozenset([_SPEND_DECAY_1D, _FM_209M])

# seven_day: exclude decay-1d only (scoped-spend proxy, not global usage)
_SEVEN_DAY_EXCLUDE = frozenset([_SPEND_DECAY_1D])


class Model(Combiner):
    rule = "stack"
    default_pool = "mixture"

    def weights_for(self, kind, tr, children, paths, now):
        if "weekly_scoped" in kind:
            return self._scoped_weights(children)
        if "five_hour" in kind:
            exclude = _FIVE_HOUR_EXCLUDE
        else:  # seven_day
            exclude = _SEVEN_DAY_EXCLUDE

        fm = [c for c in children if c not in exclude]
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
        # pool-scoped adds analog-meter (10%) but gets 0.508 — slightly worse
        # because analog's diversity doesn't compensate for its bad CRPS (2.036).
        if _SPEND_DECAY_1D in children:
            return np.array([1.0 if c == _SPEND_DECAY_1D else 0.0 for c in children])
        return np.full(len(children), 1.0 / len(children))
