"""Deep ensemble v8 — optimal target-expert routing.

Evidence from leaderboard:
  meter.five_hour  → calibrate123 (0.895, best; calstack mixture=0.8981, worse)
  meter.seven_day  → calibrate123 (0.745, best; no ensemble beats it)
  meter.scoped     → spend-decay-1d (0.500, best; pool-scoped=0.508, worse)

Fixed single-child routing: no adaptive weighting.
Eliminates scope_only backtest bias (visible test heavily scope_only,
which misleads stack_weights into giving weight to worse models).
"""
from __future__ import annotations

import numpy as np

from kit.ml.combine import Combiner

_CALIBRATE123 = "g1-01-sonnet-calibrate123"
_SPEND_DECAY_1D = "spend-decay-1d"


class Model(Combiner):
    rule = "stack"
    default_pool = "mixture"

    def weights_for(self, kind, tr, children, paths, now):
        if "weekly_scoped" in kind:
            return self._fixed_single(children, _SPEND_DECAY_1D)
        # five_hour and seven_day both route to calibrate123
        return self._fixed_single(children, _CALIBRATE123)

    def _fixed_single(self, children, preferred):
        if preferred in children:
            return np.array([1.0 if c == preferred else 0.0 for c in children])
        return np.full(len(children), 1.0 / len(children))
