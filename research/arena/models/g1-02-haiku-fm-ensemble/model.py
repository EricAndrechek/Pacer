"""Median ensemble of foundation models.

Combines top-performing foundation models (Timestral 209M, 28M, Chronos2, Moirai2)
with equal-weight median combination of their quantiles at each grid time.
"""
from __future__ import annotations

from kit.ml.combine import Combiner


class Model(Combiner):
    rule = "median"
    default_pool = "median"
    uses_backtest = False
