"""Recent shares for `split.accounts`: an account's share of its group's
spend (the request's scope) over the last day, or the last week when the
group spent nothing that day, or equal shares; flat over the horizon. A point
forecast; the rule lives in `kit/baselines.py`.
"""
from __future__ import annotations

from arena.types import Forecast, Target
from kit import baselines as B


class Model:
    def __init__(self, ctx):
        self.hours = tuple(int(h) for h in ctx.config.get("hours", (24, 168)))
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        group = tuple(request.scope.accounts)
        return Forecast({tr.key: B.split_recent(self.history, tr, group, self.hours)
                         for tr in request.targets if tr.target is Target.SPLIT})
