"""kit/fm adapters without any network or weights: series, resampling,
quantiles to paths, monotone clipping."""
from __future__ import annotations

import numpy as np
import pytest
from conftest import HOUR, MIN, T0, reading, table

from kit.fm import paths as P
from kit.fm import series as S


# --------------------------------------------------------------------------
# meter series

def _two_cycles():
    r1, r2 = T0 + 5 * HOUR, T0 + 11 * HOUR
    rows = [
        reading(T0 + 10 * MIN, "A1", "five_hour", 3, r1 + 123),
        reading(T0 + 20 * MIN, "A1", "five_hour", 7, r1 - 80),         # resets jitter by ms
        reading(T0 + 30 * MIN, "A1", "five_hour", 6, r1 + 5),          # a point down: a fall, adds 0
        reading(T0 + 40 * MIN, "A1", "five_hour", 9, r1),
        reading(T0 + 50 * MIN, "A1", "five_hour", 0, None),            # an idle blip mid-cycle
        reading(T0 + 60 * MIN, "A1", "five_hour", 10, r1 + 1),         # same cycle: adds 1, not 10
        reading(T0 + 6 * HOUR, "A1", "five_hour", 0, None),            # idle after the reset
        reading(T0 + 6 * HOUR + 10 * MIN, "A1", "five_hour", 4, r2),   # new cycle: adds its whole 4
        reading(T0 + 6 * HOUR + 20 * MIN, "A1", "five_hour", 6, r2),
        reading(T0 + 6 * HOUR + 30 * MIN, "A2", "five_hour", 50, r2),  # another account
    ]
    return table("meter_readings", rows), r1, r2


def test_cumulative_burn_across_cycles():
    r, r1, r2 = _two_cycles()
    s = S.meter_series(r, "A1", "five_hour")
    assert len(s) == 9
    assert s.cum.tolist() == [3, 7, 7, 10, 10, 11, 11, 15, 17]          # 6 -> 9 adds 3
    assert np.all(np.diff(s.cum) >= 0)
    assert s.used_now(r1) == 10.0 and s.used_now(r2) == 6.0
    assert s.used_now(r2 + 3 * HOUR) is None
    # As of an earlier now, only readings up to it.
    s_early = S.meter_series(r, "A1", "five_hour", now=T0 + 35 * MIN)
    assert s_early.cum.tolist() == [3, 7, 7]


def test_a_fall_inside_a_cycle_is_a_rebase_never_a_running_max():
    r = T0 + 5 * 24 * HOUR
    utils = [10, 40, 70, 69, 0, 2, 5, 3, 9]                  # every fall with the same reset is a re-base
    rows = [reading(T0 + k * HOUR, "A1", "weekly_scoped", u, r + 7 * k, scope_model="Fable")
            for k, u in enumerate(utils)]
    s = S.meter_series(table("meter_readings", rows), "A1", "weekly_scoped", "Fable")
    assert s.cum.tolist() == [10, 40, 70, 70, 70, 72, 75, 75, 81]
    assert s.used_now(r) == 9.0                              # as read: not 70
    assert s.cycle_util.tolist() == utils                    # no running max


def test_resample_onto_a_grid_ending_at_now_with_stale_gaps():
    times = np.array([0, 10, 20, 200], dtype=np.int64) * MIN
    vals = np.array([1.0, 2.0, 3.0, 4.0])
    grid = S.regular_grid(250 * MIN, 50 * MIN, 6)          # 0, 50, …, 250 min
    assert grid.tolist() == [i * 50 * MIN for i in range(6)]
    out = S.resample_last(times, vals, grid, stale_ms=60 * MIN)
    assert out[0] == 1.0 and out[1] == 3.0 and np.isnan(out[2]) and np.isnan(out[3])
    assert out[4] == 4.0 and out[5] == 4.0
    f = S.fill_gaps(np.array([[np.nan, 1.0, np.nan, 3.0, np.nan], [np.nan] * 5]))
    assert f.tolist() == [[1.0, 1.0, 2.0, 3.0, 3.0], [0.0] * 5]


def test_hour_bins_match_the_hourly_grid():
    now = T0 + 7 * HOUR + 17 * MIN
    t = np.array([now, now - 1, now - HOUR, now - HOUR - 1, now - 5 * HOUR, now + 1])
    b = S.hour_bins(t, now, 3)
    # bin 2 (newest) is (now-1h, now], as the truth's hour ending at a grid
    # time; (now-2h, now-1h] is bin 1; older or later: -1
    assert b.tolist() == [2, 2, 1, 1, -1, -1]
    assert S.bin_sum(t, np.ones(len(t)), now, 3).tolist() == [0.0, 2.0, 2.0]
    cal = S.calendar(np.array([T0 + HOUR, T0 + 13 * HOUR]), 0)
    assert cal.shape == (4, 2) and np.allclose(cal[0] ** 2 + cal[1] ** 2, 1)


# --------------------------------------------------------------------------
# quantiles -> paths

def test_tails_extend_outward_only():
    lv = np.round(np.arange(1, 10) / 10, 2)
    q = np.tile(np.linspace(1, 9, 9), (4, 1))                # [T=4, Q=9]
    lv2, q2 = P.extend_tails(lv, q)
    assert lv2[0] == 0.01 and lv2[-1] == 0.99 and q2.shape == (4, 11)
    assert (q2[:, 0] <= q[:, 0]).all() and (q2[:, -1] >= q[:, -1]).all()
    assert (np.diff(q2, axis=-1) >= 0).all()
    lv3, q3 = P.extend_tails(lv2, q2)                        # already wide: unchanged
    assert np.array_equal(lv3, lv2) and np.array_equal(q3, q2)


def test_comonotone_paths_from_monotone_quantiles_are_monotone():
    lv = np.array([0.1, 0.5, 0.9])
    q = np.stack([np.linspace(0, 10, 20), np.linspace(0, 20, 20), np.linspace(0, 40, 20)], axis=1)  # [20, 3]
    p = P.to_paths(lv, q, 64, "comonotone", rng=np.random.default_rng(1))
    assert p.shape == (64, 20)
    assert (np.diff(p, axis=1) >= -1e-12).all()
    # The marginal at the last time spans the band and is centred on the median.
    assert 10 <= p[:, -1].min() and p[:, -1].max() <= 40 and abs(np.median(p[:, -1]) - 20) < 2


def test_ar1_copula_has_the_requested_dependence():
    u = P.uniforms(4000, 30, "ar1", rho=0.9, rng=np.random.default_rng(0))
    z = np.clip(u, 1e-9, 1 - 1e-9)
    from scipy.special import ndtri
    c = np.corrcoef(ndtri(z[:, 10]), ndtri(z[:, 11]))[0, 1]
    c5 = np.corrcoef(ndtri(z[:, 10]), ndtri(z[:, 15]))[0, 1]
    assert abs(c - 0.9) < 0.03 and abs(c5 - 0.9 ** 5) < 0.04
    ind = P.uniforms(4000, 2, "independent", rng=np.random.default_rng(0))
    assert abs(np.corrcoef(ind[:, 0], ind[:, 1])[0, 1]) < 0.05
    with pytest.raises(ValueError):
        P.uniforms(2, 2, "nope")


def test_meter_clipping_and_burn():
    paths = np.array([[30.0, 29.0, 35.0, 120.0], [10.0, 50.0, 40.0, 60.0]])
    m = P.monotone_meter(paths, floor=31.0)
    assert m.tolist() == [[31.0, 31.0, 35.0, 100.0], [31.0, 50.0, 50.0, 60.0]]
    b = P.burn_quantiles(np.array([[5.0, 4.0], [4.0, 7.0], [9.0, 6.0]]), c_last=5.0)
    assert b.tolist() == [[0.0, 0.0], [0.0, 2.0], [2.0, 4.0]]   # non-negative, non-decreasing, sorted
    iso = P.isotonic_paths(np.array([[0.0, 3.0, 1.0, 2.0, 5.0]]))
    assert (np.diff(iso) >= 0).all() and iso[0, 0] == 0.0 and iso[0, -1] == 5.0
    assert abs(iso.sum() - 11.0) < 1e-9                     # least squares keeps the mean, no ratchet
    sub = P.samples_to_paths(np.arange(50.0)[:, None], 20, rng=np.random.default_rng(0))
    assert sub.shape == (20, 1)


def test_interp_times_along_axis_zero():
    v = np.array([[0.0, 0.0], [10.0, 20.0]])
    out = P.interp_times(np.array([0, 10]), np.array([5, 10, 20]), v)
    assert out.tolist() == [[5.0, 10.0], [10.0, 20.0], [10.0, 20.0]]


# --------------------------------------------------------------------------
# hourly series and the price cache

def _turn(cid, t, acct="A1", fam="opus", out=1000, session=7):
    return dict(t_event=t, t_known=t + 1000, t_known_src="history", call_id=cid, account=acct, model="claude-opus-4",
                model_family=fam, input=100, output=out, cache_read=0, cache_write_5m=0, cache_write_1h=0,
                output_reliable=True, session_h=session, tz_offset_min=-240)


def _price(part, rate, t_known):
    return dict(t_event=T0 - 86_400_000, t_known=t_known, t_known_src="history", model="claude-opus-4", part=part,
                rate_per_mtok=rate, source="curated", t_effective_from=T0 - 86_400_000, is_correction=False)


def test_turnframe_prices_as_of_now_once_per_turn(monkeypatch):
    from arena.snapshot.views import HistoryView
    from arena.types import Scope
    import kit.spend as KS
    calls = []
    real = KS._price_turns                    # PriceCache lives in kit.spend now
    monkeypatch.setattr(KS, "_price_turns", lambda t, *a, **k: calls.append(t.height) or real(t, *a, **k))
    now = T0 + 3 * HOUR
    turns = table("turns", [_turn(1, T0 + 30 * MIN), _turn(2, T0 + 2 * HOUR + 5 * MIN, session=8),
                            _turn(3, T0 + 2 * HOUR + 50 * MIN, acct="A2")])
    prices = table("prices", [_price("input", 10.0, T0 - HOUR), _price("output", 50.0, T0 - HOUR),
                              _price("output", 500.0, now + HOUR)])            # not known yet at now
    h = HistoryView({"turns": turns, "prices": prices}, now, Scope(("A1", "A2"), "all"))
    cache = S.PriceCache()
    tf = S.TurnFrame(h, 4, cache=cache)
    per_turn = (100 * 10.0 + 1000 * 50.0) / 1e6
    assert np.allclose(tf.hourly(("A1",)), [0.0, per_turn, 0.0, per_turn])        # bins end at now-3h … now
    assert np.allclose(tf.hourly(("A1", "A2"))[-1], 2 * per_turn)
    assert tf.sessions_per_hour(("A1",)).tolist() == [0.0, 1.0, 0.0, 1.0]
    assert calls == [3]
    S.TurnFrame(h, 4, cache=cache)
    assert calls == [3]                                                         # nothing re-priced
    upgraded = table("turns", [_turn(1, T0 + 30 * MIN, out=2000), _turn(2, T0 + 2 * HOUR + 5 * MIN, session=8),
                               _turn(3, T0 + 2 * HOUR + 50 * MIN, acct="A2")])
    h2 = HistoryView({"turns": upgraded, "prices": prices}, now, Scope(("A1", "A2"), "all"))
    tf2 = S.TurnFrame(h2, 4, cache=cache)
    assert calls == [3, 1]                                                      # only the upgraded turn
    assert np.isclose(tf2.hourly(("A1",))[1], (100 * 10.0 + 2000 * 50.0) / 1e6)
    h3 = HistoryView({"turns": upgraded, "prices": prices}, now + 2 * HOUR, Scope(("A1", "A2"), "all"))
    S.TurnFrame(h3, 6, cache=cache)
    assert calls[-1] == 3                                                       # a new rate is known: all again
