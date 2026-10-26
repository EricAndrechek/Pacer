import numpy as np

from arena.types import Forecast, TargetForecast


class Model:
    """Fails in every way a forecast can, one checkpoint at a time."""

    def __init__(self, ctx):
        self.n = 0

    def fit(self, history):
        pass

    def forecast(self, request):
        self.n += 1
        k = self.n % 4
        if k == 1:
            raise ValueError("broken on purpose")
        out = {}
        for tr in request.targets:
            g = len(tr.grid)
            if k == 2:
                out[tr.key] = TargetForecast(np.zeros((3, g + 1)))          # wrong shape
            elif k == 3:
                out[tr.key] = TargetForecast(np.full((3, g), np.inf))       # not finite
            else:
                out[tr.key] = TargetForecast.point(np.zeros(g), 2)          # fine
        return Forecast(out)
