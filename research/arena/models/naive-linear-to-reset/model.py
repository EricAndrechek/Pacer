"""The pace so far, extended: a straight line from 0 at the cycle's nominal
start (reset - window) through the latest reading, to reset, never below the
reading or above 100. The "on pace for X %" anyone would draw. A point
forecast; the rule lives in `kit/baselines.py`.
"""
from __future__ import annotations

from arena.types import Forecast
from kit import baselines as B


class Model:
    def __init__(self, ctx):
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        return Forecast({tr.key: B.meter_linear(self.history, tr)
                         for tr in request.targets if tr.target in B.WINDOW_OF})
