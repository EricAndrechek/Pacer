"""Simple weighted combination of Timestral models for weekly forecasting.
Combines 123m (best), 209m, and 28m variants via fixed weighted averaging.
Focuses on meter.seven_day target for weekly-level predictions.
"""
from __future__ import annotations

import numpy as np
from kit.ml.combine import Combiner


class Model(Combiner):
    rule = "fixed_weights"
    default_pool = "mixture"

    def __init__(self, ctx):
        super().__init__(ctx)
        self.weights_map = {
            "meter.seven_day": np.array([0.5, 0.3, 0.2])
        }

    def weights_for(self, kind, tr, children, paths, now):
        if kind not in self.weights_map:
            return np.full(len(children), 1.0 / len(children))
        w = self.weights_map[kind]
        return w / w.sum()
