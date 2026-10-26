"""Equal-weight median of the children (the "forecast combination
puzzle" baseline: simple combinations are hard to beat). Per grid time and
quantile level, the median over children of their quantiles; the result's
quantile curves are its paths. With two children it is their quantile
average. No backtest, nothing learned.
"""
from __future__ import annotations

from kit.ml.combine import Combiner


class Model(Combiner):
    rule = "median"
    default_pool = "median"
    uses_backtest = False
