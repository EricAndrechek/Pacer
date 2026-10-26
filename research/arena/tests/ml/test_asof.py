"""Features and walk-forward sets use only what was known at their moment.

The method: build at `now` from the harness's own as-of history, then build
again from a LATER history (more rows, the future included) with the same
`now` / `asof`, and require identical output. Then corrupt everything the
later history knows after `now` and require identical output again: a
label or feature that reads the future would move."""
from __future__ import annotations

import numpy as np
import polars as pl
import pytest

from arena.pricing import price_turns
from arena.snapshot.views import HistoryView
from arena.types import Scope
from kit.ml.data import DAY_MS, HOUR_MS, AsOfData
from kit.ml.features import FEATURE_NAMES, FeatureBuilder
from kit.ml.walkforward import build_trainset

KINDS = (("five_hour", None), ("seven_day", None), ("weekly_scoped", "Fable"))


def _history(data, scope, at):
    v = data.view(scope)
    return HistoryView(v.history(at), at, scope)


def _corrupt(h: HistoryView, after: int) -> HistoryView:
    """The same history with every row known after `after` scrambled:
    readings at 100 %, turns 1000x bigger, prompts moved."""
    t = {n: h.table(n) for n in h.tables}
    late = pl.col("t_known").dt.epoch("ms") > after
    t["meter_readings"] = t["meter_readings"].with_columns(
        pl.when(late).then(pl.lit(100.0)).otherwise(pl.col("util_pct")).alias("util_pct"))
    for c in ("input", "output", "cache_read"):
        t["turns"] = t["turns"].with_columns(pl.when(late).then(pl.col(c) * 1000).otherwise(pl.col(c)).alias(c))
    return HistoryView(t, h.now, h.scope, h.mode, h.start)


@pytest.fixture(scope="module")
def setting(synth_full):
    accts = synth_full.accounts()
    now = synth_full.tier.start + 40 * DAY_MS + 7 * HOUR_MS + 1234
    later = now + 3 * DAY_MS
    out = {}
    for view in ("all", "scope_only"):
        scope = Scope((accts[0],), view)
        h_now = _history(synth_full, scope, now)
        h_late = _history(synth_full, scope, later)
        out[view] = (now, h_now, h_late, AsOfData.from_history(h_now), AsOfData.from_history(h_late),
                     AsOfData.from_history(_corrupt(h_late, now)))
    return out


@pytest.mark.parametrize("view", ["all", "scope_only"])
def test_features_ignore_later_rows(setting, view):
    now, h_now, h_late, d_now, d_late, d_bad = setting[view]
    assert h_late.table("turns").height > h_now.table("turns").height      # the later history really is bigger
    seen = 0
    for kind, cap in KINDS:
        b_now, b_late, b_bad = FeatureBuilder(d_now, kind), FeatureBuilder(d_late, kind), FeatureBuilder(d_bad, kind)
        for s in d_now.series_of(kind, cap):
            s_late = d_late.meter(s.account, kind, cap)
            s_bad = d_bad.meter(s.account, kind, cap)
            for asof in (now, now - 3 * HOUR_MS - 17, now - 2 * DAY_MS):
                r = b_now.row(s, asof)
                if r is None:
                    assert b_late.row(s_late, asof) is None
                    continue
                seen += 1
                assert np.array_equal(r, b_late.row(s_late, asof)), (kind, s.account, asof)
                assert np.array_equal(r, b_bad.row(s_bad, asof)), (kind, s.account, asof)
                assert r.shape == (len(FEATURE_NAMES),) and np.isfinite(r).all()
    assert seen >= 3


def test_features_move_with_their_moment(setting):
    now, _, _, d_now, _, _ = setting["all"]
    b = FeatureBuilder(d_now, "seven_day")
    s = d_now.series_of("seven_day")[0]
    a, c = b.row(s, now), b.row(s, now - DAY_MS)
    assert a is not None and c is not None and not np.array_equal(a, c)


def test_turns_priced_with_rates_known_by_their_own_t_known(setting):
    """Each turn's cost is the price as of its own t_known (never a rate
    the catalog published later), so a feature at t sees only known rates."""
    _, h_now, _, d_now, _, _ = setting["all"]
    turns = h_now.table("turns").filter(pl.col("model") != "<synthetic>").sort("t_known").gather_every(997)
    prices = h_now.table("prices")
    for row in turns.iter_slices(1):
        tk = int(row["t_known"].dt.epoch("ms")[0])
        want = price_turns(row, prices, as_of=tk)["cost_usd"][0]
        acct = row["account"][0]
        T = d_now.turns[acct]
        i = np.flatnonzero((T.te == int(row["t_event"].dt.epoch("ms")[0])) & (T.tk == tk))
        assert len(i) >= 1
        got = T.cost[i]
        assert (want is None and np.isnan(got).any()) or (np.abs(got - (want or 0)) < 1e-12).any()


@pytest.mark.parametrize("view", ["all", "scope_only"])
def test_walkforward_ignores_later_and_corrupted_rows(setting, view):
    now, _, _, d_now, d_late, d_bad = setting[view]
    for kind, cap in KINDS:
        a = build_trainset(d_now, FeatureBuilder(d_now, kind), kind, cap, now, max_rows=400)
        b = build_trainset(d_late, FeatureBuilder(d_late, kind), kind, cap, now, max_rows=400)
        c = build_trainset(d_bad, FeatureBuilder(d_bad, kind), kind, cap, now, max_rows=400)
        assert len(a) > 20, kind
        for other in (b, c):
            assert np.array_equal(a.t, other.t) and np.array_equal(a.reset, other.reset)
            assert np.array_equal(a.X, other.X)
            assert np.array_equal(a.Y, other.Y, equal_nan=True)
            assert np.array_equal(a.lead_X, other.lead_X)


def test_walkforward_labels_are_known_at_now(setting):
    now, _, _, d_now, _, _ = setting["all"]
    for kind, cap in KINDS:
        ts = build_trainset(d_now, FeatureBuilder(d_now, kind), kind, cap, now, max_rows=400)
        known = np.isfinite(ts.Y)
        assert known.any()
        assert (ts.t < now).all()
        assert (ts.tau[known] <= now).all()
        # A lead whose time is still ahead of now is never labelled.
        assert not known[ts.tau > now].any()
        # Rises are rises: never negative, never past the headroom.
        assert (ts.Y[known] >= 0).all()
        assert (ts.Y[known] <= ts.headroom[np.nonzero(known)[0]] + 1e-9).all()
