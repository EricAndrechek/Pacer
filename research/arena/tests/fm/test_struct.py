"""The structural model with a fake child: spend paths become meter paths
through the conversion, from the live value, capped at 100, never falling,
with one child call per forecast; and the fallbacks."""
from __future__ import annotations

import numpy as np
import pytest
from conftest import HOUR, MIN, T0, reading, table

from arena.snapshot.views import HistoryView
from arena.types import Forecast, Request, Scope, Target, TargetForecast, TargetRequest
from kit import spend as spend_api
from kit.fm.struct_model import StructModel
from kit.spend import Conversion

NOW = T0 + 2 * HOUR
RESET = T0 + 5 * HOUR


class FakeChild:
    """$k per hour on path k (k = 0 … n-1), whatever is asked."""

    def __init__(self):
        self.requests = []

    def forecast(self, request):
        self.requests.append(request)
        out = {}
        for tr in request.targets:
            n = tr.n_paths
            out[tr.key] = TargetForecast(np.repeat(np.arange(n, dtype=float)[:, None], len(tr.grid), axis=1))
        return Forecast(out)


class Ctx:
    def __init__(self, child, config):
        self.child, self.config = child, config
        self.seed, self.rng, self.scratch = 0, np.random.default_rng(0), "/tmp"
        self.logs = []

    def model(self, name):
        assert name == self.config["child"]
        if isinstance(self.child, Exception):
            raise self.child
        return self.child

    def log(self, m):
        self.logs.append(m)


def _history():
    rows = [reading(T0 + k * 10 * MIN, "A1", "five_hour", 10 + k, RESET) for k in range(12)]   # 10 … 21 by now
    return HistoryView({"meter_readings": table("meter_readings", rows)}, NOW, Scope(("A1",)))


def _request(n_paths=5):
    grid = np.append(np.arange(NOW + 5 * MIN, RESET, 5 * MIN, dtype=np.int64), np.int64(RESET))
    tr = TargetRequest("meter.five_hour:A1", Target.METER_5H, ("A1",), grid, "pct", n_paths=n_paths, reset_at=RESET)
    return Request(NOW, Scope(("A1",)), (tr,)), grid


@pytest.fixture
def conv(monkeypatch):
    c = Conversion(points_per_usd={"opus": 2.0, "sonnet": 1.0}, weak=False, r2=0.9, fitted_through=T0)
    monkeypatch.setattr(spend_api, "fit_conversion", lambda *a, **k: c)
    monkeypatch.setattr(spend_api, "live_value", lambda *a, **k: 21.5)
    return c


def _model(child, **cfg):
    m = StructModel(Ctx(child, {"child": "fm-x-spend", "child_paths": 5, **cfg}))
    m.fit(_history())
    return m


def test_spend_paths_become_meter_paths_by_family(conv):
    child = FakeChild()
    m = _model(child, spend_by="family", family_dependence="independent")
    req, grid = _request()
    fc = m.forecast(req)
    assert len(child.requests) == 1                                  # one child call per forecast
    sub = child.requests[0]
    assert {(t.family, t.target) for t in sub.targets} == {("opus", Target.SPEND_HOURLY), ("sonnet", Target.SPEND_HOURLY)}
    assert all(len(t.grid) == 3 and t.grid[0] == NOW + HOUR for t in sub.targets)   # hourly to the reset
    P = fc.by_key["meter.five_hour:A1"].paths
    assert P.shape == (5, len(grid))
    hours = (grid - NOW) / HOUR
    for k in range(5):                                               # $k/h in each family: 3k points/h
        expect = np.minimum(21.5 + 3.0 * k * hours, 100.0)
        assert np.allclose(P[k], expect)
    assert (np.diff(P, axis=1) >= 0).all() and P.max() <= 100.0 and P.min() >= 21.5


def test_total_spend_at_one_blended_rate(conv, monkeypatch):
    child = FakeChild()
    m = _model(child, spend_by="total")
    monkeypatch.setattr(m, "_blend", lambda acct, rates: 1.5)
    req, grid = _request()
    P = m.forecast(req).by_key["meter.five_hour:A1"].paths
    (t,) = child.requests[0].targets
    assert t.family is None and t.accounts == ("A1",)
    hours = (grid - NOW) / HOUR
    assert np.allclose(np.sort(P[:, -1]), np.minimum(21.5 + 1.5 * np.arange(5) * hours[-1], 100.0))


def test_start_is_the_reading_without_a_live_value(conv, monkeypatch):
    monkeypatch.setattr(spend_api, "live_value", lambda *a, **k: None)
    P = _model(FakeChild(), spend_by="total").forecast(_request()[0]).by_key["meter.five_hour:A1"].paths
    assert P.min() == 21.0                                           # the latest reading of the cycle


def test_no_conversion_or_a_failing_child_leaves_the_meter_flat(monkeypatch, conv):
    m = _model(RuntimeError("child exploded"))
    P = m.forecast(_request()[0]).by_key["meter.five_hour:A1"].paths
    assert np.allclose(P, 21.5) and any("child exploded" in s for s in m.ctx.logs)
    monkeypatch.setattr(spend_api, "fit_conversion", lambda *a, **k: None)
    child = FakeChild()
    m = _model(child, weak="fit")
    P = m.forecast(_request()[0]).by_key["meter.five_hour:A1"].paths
    assert np.allclose(P, 21.0) and not child.requests              # nothing to convert: no child call
