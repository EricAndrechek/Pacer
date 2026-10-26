"""Simple clean median ensemble of top FMs.

Combines three top foundation models (Timestral-209M, Chronos2, Moirai2) with
simple equal-weight median of their quantiles. No learning, no complexity,
just the robust average of the best models.
"""
from __future__ import annotations

from kit.ml.combine import Combiner


class Model(Combiner):
    rule = "median"
    default_pool = "median"
    uses_backtest = False
