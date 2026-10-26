"""Climatology for hourly spend: each grid hour takes the same hour of the
week from every whole past week in the history (newest `weeks` of them, or
all). Each past week is one path, so the middle path is the profile's median
and the spread is the weeks' own. Under two weeks of history it falls back to
a point (the one week, or a day profile). The rule lives in
`kit/baselines.py`.
"""
from __future__ import annotations

from arena.types import Forecast, Target
from kit import baselines as B


class Model:
    def __init__(self, ctx):
        w = int(ctx.config.get("weeks", 0))
        self.weeks = w if w > 0 else None
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        return Forecast({tr.key: B.hourly_profile(self.history, tr, self.weeks)
                         for tr in request.targets if tr.target is Target.SPEND_HOURLY})
