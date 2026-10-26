import numpy as np

from arena.types import Forecast, Target, TargetForecast


class Model:
    def __init__(self, ctx):
        self.ctx = ctx

    def _check(self, view, now):
        for name in view.tables:
            df = view.table(name)
            if df.height and df["t_known"].dt.epoch("ms").max() > now:
                raise AssertionError(f"LEAK {name}")
            if any(c.startswith("_") for c in df.columns):
                raise AssertionError(f"internal column in {name}")

    def fit(self, history):
        import os
        print("spy: fit at", history.now)          # stdout: must go to stderr in a worker
        self.ctx.log(f"env ARENA_HOME={'ARENA_HOME' in os.environ} cwd_is_scratch={os.path.realpath(os.getcwd()) == os.path.realpath(self.ctx.scratch)}")
        self._check(history, history.now)
        self.h = history

    def update(self, events):
        self._check(events, events.until)
        self.h = self.h.extend(events)
        self._check(self.h, self.h.now)

    def forecast(self, request):
        assert request.now == self.h.now, (request.now, self.h.now)
        out = {}
        for tr in request.targets:
            assert (tr.grid > request.now).all()
            if tr.target is Target.CYCLE_NEXT_START:
                out[tr.key] = TargetForecast(np.full((3, 1), np.nan))
            else:
                out[tr.key] = TargetForecast.point(np.zeros(len(tr.grid)), 2)
        return Forecast(out)
