import time

import numpy as np

from arena.types import Forecast, TargetForecast


class Model:
    def __init__(self, ctx):
        self.sleep = float(ctx.config.get("sleep_s", 2.0))

    def fit(self, history):
        pass

    def forecast(self, request):
        time.sleep(self.sleep)
        return Forecast({tr.key: TargetForecast.point(np.zeros(len(tr.grid))) for tr in request.targets})
