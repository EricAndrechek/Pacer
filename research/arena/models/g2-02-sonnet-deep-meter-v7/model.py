"""Deep ensemble v7 — selective ensemble, scope_only-robust.

Three children: calibrate123, timesfm25, spend-decay-1d.

Target-specific strategy based on leaderboard analysis:

meter.five_hour:
  Adaptive stack: calibrate123 (0.895) + timesfm25 (0.999).
  Both have different architectures (Timestral 123M vs TimesFM 2.5/Google).
  Expected CRPS: 0.87-0.93 (small ensemble benefit from architecture diversity).

meter.seven_day:
  calibrate123 ONLY (fixed weight 1.0).
  timesfm25 (CRPS=1.010 for seven_day) is too weak:
  0.75*0.745 + 0.25*1.010 = 0.811, needs diversity >0.07 to beat 0.745.
  Fixed weight 1.0 guarantees CRPS = 0.745 (best leaderboard model).
  This is level 3 in the deep stack (calibrate123 → 123m-meter → forecast).

meter.scoped:
  spend-decay-1d ONLY (fixed weight 1.0).
  Individual leaderboard CRPS=0.500 (best single model).
  pool-scoped (decay=0.90, analog=0.10) gets 0.508 — analog hurts not helps.
"""
from __future__ import annotations

import numpy as np

from kit.ml.combine import Combiner, stack_weights

_CALIBRATE123 = "g1-01-sonnet-calibrate123"
_TIMESFM25 = "fm-timesfm25-meter"
_SPEND_DECAY_1D = "spend-decay-1d"

# Only these two for five_hour (architecture-diverse pair)
_FIVE_HOUR_ALLOWED = frozenset([_CALIBRATE123, _TIMESFM25])


class Model(Combiner):
    rule = "stack"
    default_pool = "mixture"

    def weights_for(self, kind, tr, children, paths, now):
        if "weekly_scoped" in kind:
            return self._fixed_single(children, _SPEND_DECAY_1D)
        if "seven_day" in kind:
            return self._fixed_single(children, _CALIBRATE123)
        # five_hour: stack on calibrate123+timesfm25 only
        fm = [c for c in children if c in _FIVE_HOUR_ALLOWED]
        if not fm:
            return np.full(len(children), 1.0 / len(children))
        groups = self.ledger.scored(kind, before=now)
        fm_w = stack_weights(groups, fm, now, pool=self.pool_kind,
                             half_life=self.half_life(kind),
                             shrink=float(self.cfg.get("shrink", 0.10)))
        fm_dict = dict(zip(fm, fm_w))
        return np.array([fm_dict.get(c, 0.0) for c in children])

    def _fixed_single(self, children, preferred):
        # Give all weight to preferred child; equal fallback if absent.
        if preferred in children:
            return np.array([1.0 if c == preferred else 0.0 for c in children])
        return np.full(len(children), 1.0 / len(children))
