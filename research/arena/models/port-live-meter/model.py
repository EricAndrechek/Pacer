"""What the app shows now, as a forecast: the live meter (#318), flat to
reset.

The centre of every path is `kit.spend.live_value` (LiveMeter.estimate →
LiveMeterValue.shownPercent: the latest reading plus the spend since it at
the fitted points per dollar, floored to whole points with the carry, shown
to a tenth). Where the app shows no live value (no fit, a weak fit, a reading
over an hour old) it shows the reading, and so does this. Nothing here
forecasts what happens next: the path is flat, which is the claim the app
makes by showing one number. `next_reading_ae` is its natural test; the long
leads score how far "what the app shows" is from the reset.

The spread is the fit's own error at this much spend: the residuals (rise −
rate × spend) of the `neighbours` intervals of the 14-day fit whose converted
spend was nearest what has been spent since the reading, so a quiet moment
gets the near-zero spread of quiet intervals and a busy one the scatter of
busy ones. Each path is one residual, constant over the path, kept between
the latest reading (a meter never falls within its cycle) and 100.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, TargetForecast
from kit import baselines as B
from kit import spend


class Model:
    def __init__(self, ctx):
        self.k = int(ctx.config.get("neighbours", 400))
        self.rng = ctx.rng
        self.log = ctx.log
        self.history = None

    def fit(self, history):
        self.history = history

    def update(self, events):
        self.history = self.history.extend(events)

    def forecast(self, request):
        return Forecast({tr.key: self._meter(tr) for tr in request.targets if tr.target in B.WINDOW_OF})

    def _meter(self, tr):
        h = self.history
        m = B.meter_now(h, tr)
        acct = tr.accounts[0]
        live = spend.live_detail(h, acct, m.window_kind, m.scope_model)
        centre = live.shown if live is not None else m.latest
        added = live.added if live is not None else 0.0
        d = spend.fit_details(h, acct, m.window_kind, m.scope_model)
        n = len(tr.grid)
        if d is None or len(d.residuals) == 0:
            return TargetForecast.point(np.full(n, centre))
        order = np.argsort(d.fitted, kind="stable")
        fitted, resid = d.fitted[order], d.residuals[order]
        i = int(np.searchsorted(fitted, added))
        lo = max(0, min(i - self.k // 2, len(fitted) - self.k))
        near = resid[lo:lo + self.k]
        draws = self.rng.choice(near, size=tr.n_paths, replace=True)
        values = np.clip(centre + np.sort(draws), m.latest, 100.0)
        return TargetForecast(np.repeat(values[:, None], n, axis=1))
