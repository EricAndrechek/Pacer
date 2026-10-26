import math

import numpy as np
import pytest

from arena.scoring import InvalidForecast, interpolate_paths, lead_bin, score_checkpoint
from arena.types import (Forecast, Request, Scope, Target, TargetForecast, TargetRequest,
                         TargetTruth, Truth)

NOW = 1_000_000_000_000
S = 1000


def mk(grid_s, paths, times_s, values, *, target=Target.METER_5H, reset_s=None, horizon_s=None,
       hit=None, ttl=math.nan, extras=None, units="pct"):
    grid = np.array([NOW + g * S for g in grid_s], dtype=np.int64)
    hz = NOW + (horizon_s if horizon_s is not None else grid_s[-1]) * S
    reset = None if reset_s is None else NOW + reset_s * S
    req = TargetRequest("k", target, ("A1",), grid, units, reset_at=reset)
    r = Request(NOW, Scope(("A1",)), (req,))
    f = Forecast({"k": TargetForecast(np.array(paths, dtype=float), extras or {})})
    t = Truth({"k": TargetTruth(np.array([NOW + x * S for x in times_s], dtype=np.int64),
                                np.array(values, dtype=float), hz, reset, hit, ttl)})
    return r, f, t


def get(rows, metric, lead=None):
    m = [r.value for r in rows if r.metric == metric and r.lead_s == lead]
    return m[0] if m else None


def test_crps_fair_hand_computed():
    # ensemble {0, 2}, obs 1: fair CRPS = mean|x-y| - 1/(2*M*(M-1))*sum|xi-xj|
    # = 1 - (1/(2*2*1))*(2*2) = 0. Naive estimator would give 1 - 0.5 = 0.5.
    r, f, t = mk([100], [[0.0], [2.0]], [100], [1.0])
    assert get(score_checkpoint(r, f, t), "crps") == pytest.approx(0.0)
    # ensemble {0,1,3}, obs 0: mean|x-y| = 4/3; pairs sum (ordered) = 2*(1+3+2)=12
    # fair = 4/3 - 12/(2*3*2) = 4/3 - 1 = 1/3
    r, f, t = mk([100], [[0.0], [1.0], [3.0]], [100], [0.0])
    assert get(score_checkpoint(r, f, t), "crps") == pytest.approx(1 / 3)


def test_single_path_crps_is_ae():
    r, f, t = mk([100, 200], [[10, 20]], [100, 200], [13, 15])
    rows = score_checkpoint(r, f, t)
    assert get(rows, "crps") == pytest.approx(4.0)
    assert get(rows, "ae_point") == pytest.approx(4.0)


def test_interpolation_and_edges():
    p = np.array([[10.0, 20.0, 40.0]])
    g = np.array([100, 200, 300])
    out = interpolate_paths(p, g, np.array([50, 100, 150, 250, 300]))
    assert out[0].tolist() == [10, 10, 15, 30, 40]
    # truth after the last grid point is dropped, not extrapolated
    r, f, t = mk([100, 200], [[10, 20]], [150, 999], [15, 0])
    rows = score_checkpoint(r, f, t)
    assert get(rows, "ae_point") == pytest.approx(0.0)
    assert get(rows, "next_reading_ae") == pytest.approx(0.0)
    # all truth beyond grid: nothing to score
    r, f, t = mk([100, 200], [[10, 20]], [999], [0])
    assert score_checkpoint(r, f, t) == []


def test_empty_truth_no_rows():
    r, f, t = mk([100], [[1.0]], [], [])
    assert score_checkpoint(r, f, t) == []


def test_nan_raises():
    r, f, t = mk([100, 200], [[1.0, math.nan]], [100], [1.0])
    with pytest.raises(InvalidForecast):
        score_checkpoint(r, f, t)


def test_coverage():
    paths = [[v] for v in range(101)]          # 0..100 at one time
    r, f, t = mk([100], paths, [100], [50.0])
    rows = score_checkpoint(r, f, t)
    assert get(rows, "cover50") == get(rows, "cover80") == get(rows, "cover95") == 1.0
    r, f, t = mk([100], paths, [100], [10.0])   # outside 50% (25..75), inside 80% (10..90)
    rows = score_checkpoint(r, f, t)
    assert get(rows, "cover50") == 0.0 and get(rows, "cover80") == 1.0


def test_energy_variogram_need_two_times():
    r, f, t = mk([100, 200], [[1, 2], [3, 4]], [100], [1.0])
    rows = score_checkpoint(r, f, t)
    assert get(rows, "energy") is None and get(rows, "variogram") is None
    r, f, t = mk([100, 200], [[1, 2], [3, 4]], [100, 200], [1.0, 2.0])
    rows = score_checkpoint(r, f, t)
    assert get(rows, "energy") is not None and get(rows, "variogram") is not None


def test_brier_and_time_to_limit():
    # 4 paths, 1 reaches 100 before reset at 300s; truth hit it at 200s
    paths = [[10, 100, 100], [10, 20, 30], [10, 20, 30], [10, 20, 30]]
    r, f, t = mk([100, 200, 300], paths, [100, 200, 300], [10, 100, 100], reset_s=300,
                 horizon_s=300, hit=True, ttl=NOW + 200 * S, extras={"p_hit_limit": 0.5})
    rows = score_checkpoint(r, f, t)
    assert get(rows, "brier_hit") == pytest.approx((0.25 - 1) ** 2)
    assert get(rows, "brier_hit_direct") == pytest.approx(0.25)
    h = lambda s: s / 3600
    # path hours: [200s, cap, cap, cap] with cap = 300s; obs = 200s
    ens = np.array([h(200), h(300), h(300), h(300)])
    exp = np.mean(np.abs(ens - h(200))) - np.sum(np.abs(ens[:, None] - ens[None])) / (2 * 4 * 3)
    assert get(rows, "crps_ttl") == pytest.approx(exp)
    assert get(rows, "ae_reset") == pytest.approx(70.0)  # median at 300s is 30, truth 100


def test_ttl_no_hit_is_horizon():
    r, f, t = mk([100, 200], [[10, 20]], [100, 200], [10, 20], reset_s=200, hit=False)
    rows = score_checkpoint(r, f, t)
    assert get(rows, "crps_ttl") == pytest.approx(0.0)
    assert get(rows, "brier_hit") == pytest.approx(0.0)


def test_no_reset_no_ae_reset():
    r, f, t = mk([100, 200], [[10, 20]], [100, 200], [10, 20])
    assert get(score_checkpoint(r, f, t), "ae_reset") is None


def test_lead_bins():
    assert lead_bin(10) == 300 and lead_bin(300) == 300 and lead_bin(301) == 1800
    assert lead_bin(1e9) == 604800
    r, f, t = mk([100, 4000], [[0, 0]], [100, 200, 4000], [1, 2, 3])
    rows = score_checkpoint(r, f, t)
    assert get(rows, "ae_point", 300.0) == pytest.approx(1.5)
    assert get(rows, "ae_point", 7200.0) == pytest.approx(3.0)
    assert get(rows, "ae_point", 1800.0) is None
    assert get(rows, "ae_point") == pytest.approx(2.0)


def test_next_start():
    # paths hold start times (ms); one NaN = no start before the horizon (10h)
    hz = 10 * 3600
    starts = [NOW + 3600 * S, NOW + 3600 * S, math.nan]
    r, f, t = mk([hz], [[s] for s in starts], [], [], target=Target.CYCLE_NEXT_START,
                 horizon_s=hz, units="epoch_ms")
    t.by_key["k"].next_start = NOW + 3600 * S
    rows = score_checkpoint(r, f, t)
    ens = np.array([1.0, 1.0, 10.0])
    exp = np.mean(np.abs(ens - 1)) - np.sum(np.abs(ens[:, None] - ens[None])) / (2 * 3 * 2)
    assert get(rows, "crps") == pytest.approx(exp)
    assert get(rows, "ae_point") == pytest.approx(0.0)
    t.by_key["k"].next_start = math.nan
    assert get(score_checkpoint(r, f, t), "ae_point") == pytest.approx(9.0)


def _pit(rows):
    return np.array([get(rows, f"pit_b{b}") for b in range(10)])


def test_pit_histogram():
    """pit_b0..pit_b9: the share of a checkpoint's truth points per PIT decile.
    Sums to 1; flat for a calibrated ensemble; U-shaped when too narrow; ties
    (integer readings, integer paths) spread instead of piling in the middle."""
    rng = np.random.default_rng(3)
    T = 600                                 # (energy and variogram scores are O(T^2): keep it small)
    grid = list(range(1, T + 1))
    paths = rng.normal(50, 10, size=(400, T))
    truth = rng.normal(50, 10, size=T)
    r, f, t = mk(grid, paths, grid, truth)
    h = _pit(score_checkpoint(r, f, t))
    assert np.isclose(h.sum(), 1.0) and np.abs(h - 0.1).max() < 0.05
    r, f, t = mk(grid, paths * 0.3 + 35, grid, truth)            # far too narrow
    h = _pit(score_checkpoint(r, f, t))
    assert h[0] + h[9] > 0.5 and h[4] + h[5] < 0.1
    # integers: readings and paths both whole percents
    r, f, t = mk(grid, np.round(paths / 10), grid, np.round(truth / 10))
    rows = score_checkpoint(r, f, t)
    h = _pit(rows)
    assert np.abs(h - 0.1).max() < 0.05
    assert np.array_equal(h, _pit(score_checkpoint(r, f, t)))      # seeded: a rerun scores the same
    # a single truth point lands in exactly one bin
    r, f, t = mk([100], [[v] for v in range(101)], [100], [5.0])
    h = _pit(score_checkpoint(r, f, t))
    assert h.sum() == 1.0 and h[0] == 1.0


def test_energy_and_variogram_on_a_long_path_use_an_even_subset():
    """A 7-day meter has ~2,000 readings; the variogram score over all of them
    would hold [paths, T, T]. Both whole-path scores use at most 128 evenly
    spaced truth points, first and last included."""
    import resource
    import scoringrules as sr
    from arena.scoring.checkpoint import MULTIVARIATE_MAX_POINTS, even_subset
    rng = np.random.default_rng(0)
    T = 2016
    grid = list(range(1, T + 1))
    paths = rng.normal(50, 5, size=(200, T))
    truth = rng.normal(50, 5, size=T)
    before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    rows = score_checkpoint(*mk(grid, paths, grid, truth))
    grown = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss - before
    assert grown < 1.5 * 2**30            # bytes on macOS, KiB on Linux: either way far below 12 GB
    sel = even_subset(T)
    assert len(sel) == MULTIVARIATE_MAX_POINTS and sel[0] == 0 and sel[-1] == T - 1
    assert np.isclose(get(rows, "variogram"), float(sr.vs_ensemble(truth[sel], paths[:, sel], m_axis=0, v_axis=1)))
    assert np.isclose(get(rows, "energy"), float(sr.es_ensemble(truth[sel], paths[:, sel], m_axis=0, v_axis=1)))
    assert list(even_subset(5)) == [0, 1, 2, 3, 4]


def test_crps_is_the_fair_estimator_without_pairs():
    """The PWM estimator used for CRPS equals scoringrules' fair estimator,
    ties included, without its [T, M, M] memory."""
    import scoringrules as sr
    from arena.scoring.checkpoint import _crps
    rng = np.random.default_rng(1)
    ens = rng.normal(size=(300, 50))
    ens[:, :20] = np.round(ens[:, :20], 1)
    obs = rng.normal(size=300)
    assert np.allclose(_crps(obs, ens), sr.crps_ensemble(obs, ens, m_axis=-1, estimator="fair"), atol=1e-12)
