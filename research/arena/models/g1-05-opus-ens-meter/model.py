"""A lead-banded, spread-calibrated ensemble of diverse meter children.

The children are picked to disagree: a foundation model on the meter itself,
two spend-to-meter decays (short and long memory), a burn-rate engine and a
Kalman trend. Weights are fitted per lead band, the pooled spread is
rescaled by a factor fitted on the same past forecasts, and the head of
every path is blended toward the live meter. See `ens.py`.
"""
from __future__ import annotations

from ens import BandedEnsemble


class Model(BandedEnsemble):
    pass
