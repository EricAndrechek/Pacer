import numpy as np

from arena.types import Forecast, TargetForecast


def fingerprint(view):
    rows, tk = 0, 0
    for name in ("turns", "meter_readings"):
        df = view.table(name)
        rows += df.height
        if df.height:
            tk += int(df["t_known"].dt.epoch("ms").sum() // 1000)
    return float(rows), float(tk % (2 ** 40))


class Model:
    """Answers with a fingerprint of the view it was given."""

    def __init__(self, ctx):
        pass

    def fit(self, history):
        self.h = history

    def forecast(self, request):
        rows, tk = fingerprint(self.h)
        return Forecast({tr.key: TargetForecast(np.full((2, len(tr.grid)), rows),
                                                {"fp_rows": rows, "fp_tk": tk, "now": float(self.h.now)})
                         for tr in request.targets})
