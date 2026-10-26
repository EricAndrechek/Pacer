"""Deep 3-layer ensemble for meter forecasting.

Children (layer 2+):
- g1-01-sonnet-calibrate123: Timestral-123m with spread calibration (scale=0.60).
  Best leaderboard CRPS for five_hour (0.895) and seven_day (0.745); trivial fit().
- fm-timesfm25-meter: TimesFM-2.5. Architecture diversity; strong for five_hour.
- fm-timestral-209m-meter: Larger Timestral. Second-best raw for seven_day (0.843).
- spend-decay-1d: Spend-rate projection; handles seven_day+scoped (not five_hour).
  Best scoped model (0.500) when dominant.

Routing rationale:
- meter.scoped: Fixed weights (spend-decay-1d=0.90, FM models share 0.10).
  Rationale: spend-decay-1d (CRPS 0.500) >> FM models (0.81-0.84) >> analog (2.04).
  Backtests also underestimate spend-decay quality because scoped meter is often
  inactive early in the backtest window (cold-start). Fixed weights bypass this.
- meter.seven_day: Stack on FM models only (calibrate123+timesfm25+209m). spend-decay-1d
  excluded: it tracks Fable-scoped spend, not global 7-day API usage, and the optimizer
  gives it high weight in scope_only episodes where it happens to match.
- meter.five_hour: Stack on FM models only (calibrate123+timesfm25+209m). spend-decay-1d
  excluded because even though it can answer five_hour, its five_hour predictions are
  tuned for scoped-period patterns not the global 5h window.

Note: analog-meter (CRPS 1.49 seven_day, 2.04 scoped) was explicitly removed from
children. When included, the stack gave it 60-70% weight for seven_day despite its
poor global performance, because analog sometimes matches episode-specific patterns.
"""
from __future__ import annotations

import numpy as np

from kit.ml.combine import Combiner, stack_weights

_SPEND_DECAY_1D = "spend-decay-1d"


class Model(Combiner):
    rule = "stack"
    default_pool = "mixture"

    def weights_for(self, kind, tr, children, paths, now):
        if "weekly_scoped" in kind:
            return self._scoped_weights(children)
        # For five_hour and seven_day: exclude spend-decay-1d.
        # It tracks Fable-scoped spend rates, not global meter usage.
        fm = [c for c in children if c != _SPEND_DECAY_1D]
        if len(fm) < len(children):
            groups = self.ledger.scored(kind, before=now)
            fm_w = stack_weights(groups, fm, now, pool=self.pool_kind,
                                 half_life=self.half_life(kind),
                                 shrink=float(self.cfg.get("shrink", 0.05)))
            fm_dict = dict(zip(fm, fm_w))
            return np.array([fm_dict.get(c, 0.0) for c in children])
        # five_hour: all available (spend-decay-1d should be absent from avail,
        # but this handles it correctly even if it somehow appears)
        groups = self.ledger.scored(kind, before=now)
        return stack_weights(groups, children, now, pool=self.pool_kind,
                             half_life=self.half_life(kind),
                             shrink=float(self.cfg.get("shrink", 0.05)))

    def _scoped_weights(self, children):
        # 90% spend-decay-1d, 10% shared among FM models.
        # spend-decay-1d (CRPS 0.500) >> FM (0.81-0.84) >> analog (2.04).
        has_decay = _SPEND_DECAY_1D in children
        if not has_decay:
            return np.full(len(children), 1.0 / len(children))
        fm_children = [c for c in children if c != _SPEND_DECAY_1D]
        fm_count = len(fm_children)
        fm_w = 0.10 / max(fm_count, 1)
        w = np.array([0.90 if c == _SPEND_DECAY_1D else fm_w for c in children])
        total = w.sum()
        return w / total if total > 0 else np.full(len(children), 1.0 / len(children))
