"""The spend model's plumbing with a stub forecaster: what it is fed (the
group's hourly series, the family filter, covariate shapes, companion
variates) and what it hands back (non-negative paths on the grid, capped)."""
from __future__ import annotations

import numpy as np
import pytest
from conftest import HOUR, MIN, T0, reading, table
from test_adapters import _price, _turn

from arena.snapshot.views import HistoryView
from arena.types import Request, Scope, Target, TargetRequest
from kit.fm import spend_model

NOW = T0 + 6 * HOUR


class Stub:
    covariates = True
    multivariate = True

    def __init__(self):
        self.calls = []

    def quantiles(self, ctx, horizon, past=None, known=None):
        self.calls.append((np.array(ctx), None if past is None else np.array(past),
                           None if known is None else np.array(known), horizon))
        last = np.nan_to_num(np.asarray(ctx)[:, :, -1])                        # [B, V]
        lv = np.array([0.1, 0.5, 0.9])
        q = np.stack([last * 0.5, last, last * 50.0], axis=-1)                   # a wild top quantile
        return lv, np.repeat(q[:, :, None, :], horizon, axis=2)


@pytest.fixture
def world(monkeypatch):
    stub = Stub()
    monkeypatch.setattr(spend_model, "get_backend", lambda *a, **k: stub)
    turns = [_turn(1, NOW - 30 * MIN), _turn(2, NOW - 20 * MIN, fam="sonnet"), _turn(3, NOW - 3 * HOUR),
             _turn(4, NOW - 10 * MIN, acct="A2")]
    tables = {"turns": table("turns", turns),
              "prices": table("prices", [_price("input", 10.0, T0 - HOUR), _price("output", 50.0, T0 - HOUR)]),
              "meter_readings": table("meter_readings", [reading(NOW - k * 20 * MIN, "A1", "five_hour", 30 - k,
                                                                 NOW + 2 * HOUR) for k in range(10)]),
              "prompts": table("prompts", [dict(t_event=NOW - 25 * MIN, t_known=NOW - 25 * MIN, session_h=7)])}
    h = HistoryView(tables, NOW, Scope(("A1", "A2"), "all"))
    return stub, h


def _model(h, **cfg):
    class Ctx:
        seed, scratch = 0, "/tmp"
        rng = np.random.default_rng(0)
        config = {"backend": "stub", "weights": "x/y", "context_hours": 12, **cfg}
    m = spend_model.SpendModel(Ctx())
    m.fit(h)
    return m


def _req(*specs):
    trs = tuple(TargetRequest(k, t, acc, NOW + HOUR * np.arange(1, 5, dtype=np.int64),
                              "usd_per_hour" if t is Target.SPEND_HOURLY else "tokens_per_hour", n_paths=50, family=f)
                for k, t, acc, f in specs)
    return Request(NOW, Scope(("A1", "A2"), "all"), trs)


def test_series_covariates_and_paths(world):
    stub, h = world
    m = _model(h, covariates=["calendar", "meter", "sessions", "prompts"])
    fc = m.forecast(_req(("s", Target.SPEND_HOURLY, ("A1",), None), ("so", Target.SPEND_HOURLY, ("A1",), "opus"),
                         ("t", Target.TOKENS_HOURLY, ("A1", "A2"), None)))
    ctx, past, known, H = stub.calls[0]
    assert ctx.shape == (3, 1, 12) and H == 4
    per = (100 * 10.0 + 1000 * 50.0) / 1e6
    assert np.isclose(ctx[0, 0, -1], 2 * per) and np.isclose(ctx[0, 0, -4], per)  # opus + sonnet in the last hour
    assert np.isclose(ctx[1, 0, -1], per)                                       # the opus family alone
    assert ctx[2, 0, -1] == 3 * 1100                                           # tokens of both accounts
    assert past.shape == (3, 4, 12) and known.shape == (3, 4, 16)              # meter 5h/7d, sessions, prompts
    assert past[0, 0, -1] == 30.0 and np.isnan(past[0, 1, -1])                 # 5h meter now; no 7d readings
    assert past[0, 2, -1] == 1.0 and past[0, 3, -1] == 1.0                     # one session, one prompt
    for key in ("s", "so", "t"):
        P = fc.by_key[key].paths
        assert P.shape == (50, 4) and (P >= 0).all()
    assert fc.by_key["s"].paths.max() <= 1.5 * 2 * per + 1e-12                # capped at 1.5x the context max


def test_multivariate_companions(world):
    stub, h = world
    _model(h, multivariate="families", covariates=[]).forecast(_req(("s", Target.SPEND_HOURLY, ("A1",), None)))
    ctx = stub.calls[-1][0]
    assert ctx.shape == (1, 3, 12)                                              # total, opus, sonnet
    _model(h, multivariate="accounts", covariates=[]).forecast(_req(("s", Target.SPEND_HOURLY, ("A1",), None)))
    ctx = stub.calls[-1][0]
    assert ctx.shape == (1, 3, 12)                                              # A1 (target), then A1 and A2
    assert np.isclose(ctx[0, 2, -1], (100 * 10.0 + 1000 * 50.0) / 1e6)
