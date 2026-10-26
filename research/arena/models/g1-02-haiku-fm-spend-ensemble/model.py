"""Median ensemble of foundation model spend forecasters.

Combines Timestral 209M, 28M, and 5M models' spend/tokens forecasts
with equal-weight median combination of their quantiles at each grid time.
"""
from __future__ import annotations

from kit.ml.combine import Combiner


class Model(Combiner):
    rule = "median"
    default_pool = "median"
    uses_backtest = False
