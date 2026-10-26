"""A deterministic stand-in child for parity tests of the combiners: the
meter now plus A_i * shape_i(f) * mult_p, f the lead as a share of the
window, mult_p = (p + 0.5) / n * 2 per path. Only +, *, /, sqrt and min, so
the Swift twin (EnsembleParityTests.Stub) reproduces it bit for bit."""
import numpy as np

from arena.types import Forecast, TargetForecast
from kit import baselines as B

A = [10.0, 25.0, 5.0, 0.0, 40.0, 15.0]


class Model:
    def __init__(self, ctx):
        self.i = int(ctx.config["stub"])
        self.h = None

    def fit(self, history):
        self.h = history

    def update(self, events):
        self.h = self.h.extend(events)

    def forecast(self, request):
        out = {}
        for tr in request.targets:
            if tr.target not in B.WINDOW_OF:
                continue
            latest = float(B.meter_now(self.h, tr).latest)
            win = 5 * 3_600_000 if B.WINDOW_OF[tr.target] == "five_hour" else 7 * 86_400_000
            n = int(tr.n_paths)
            lead = (np.asarray(tr.grid, dtype=np.int64) - int(request.now)).astype(np.float64)
            f = lead / float(win)
            k = self.i % 3
            shape = f if k == 0 else (np.sqrt(f) if k == 1 else f * f)
            mult = (np.arange(n, dtype=np.float64) + 0.5) / n * 2.0
            paths = np.minimum(latest + (A[self.i] * shape)[None, :] * mult[:, None], 100.0)
            out[tr.key] = TargetForecast(paths)
        return Forecast(out)
