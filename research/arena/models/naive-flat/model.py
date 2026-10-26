"""Persistence, the floor of every board: nothing changes from now on.

- meters: the latest reading of the cycle, flat to reset;
- spend and tokens: the last whole hour's value, flat;
- cycle.next_start: an idle window stays idle (no start before the horizon).

Point forecasts (one path): the rule and nothing more. The rules live in
`kit/baselines.py`.
"""
from __future__ import annotations

from arena.types import Forecast, Target
from kit import baselines as B


class Model:
    def __init__(self, ctx):
        self.hours = int(ctx.config.get("hours", 1))
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target in B.WINDOW_OF:
                out[tr.key] = B.meter_flat(self.history, tr)
            elif tr.target is Target.CYCLE_NEXT_START:
                out[tr.key] = B.next_start_never(self.history, tr)
            elif tr.target in (Target.SPEND_HOURLY, Target.TOKENS_HOURLY):
                out[tr.key] = B.hourly_flat(self.history, tr, self.hours)
        return Forecast(out)
