"""Seasonal naive for the hourly targets: the value at grid hour g is the
value of the hour ending one period before it (g - period), and the last
period repeats for leads beyond it. A point forecast; the rule lives in
`kit/baselines.py`.
"""
from __future__ import annotations

from arena.types import Forecast, Target
from kit import baselines as B


class Model:
    def __init__(self, ctx):
        self.period_h = int(ctx.config["period_h"])
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        return Forecast({tr.key: B.hourly_seasonal(self.history, tr, self.period_h)
                         for tr in request.targets
                         if tr.target in (Target.SPEND_HOURLY, Target.TOKENS_HOURLY)})
