"""The calibration layer (kit/calib.py): its pieces on synthetic records with
a known answer, then end to end (in-process harness and the runner)."""
from __future__ import annotations

import numpy as np
import polars as pl
import pytest
from scipy.stats import norm

from kit import calib as C

LEADS_7D = (600.0, 20_000.0, 100_000.0, 400_000.0)


def _records(n_origins: int, per: int, sd_child: float, sd_truth: float, seed: int = 0, leads=LEADS_7D):
    """Records whose child forecast is N(m, sd_child²) and whose truth is
    drawn from N(m, sd_truth²), at each lead, per origin."""
    rng = np.random.default_rng(seed)
    z = norm.ppf(C.level_grid(C.M_LEVELS))
    q, y, lead, origin = [], [], [], []
    for o in range(n_origins):
        for L in leads:
            for _ in range(per):
                m = rng.uniform(20, 60)
                q.append(m + sd_child * z)
                y.append(m + rng.normal(0, sd_truth))
                lead.append(L)
                origin.append(o)
    return np.array(q), np.array(y), np.array(lead), np.array(origin)


def _gauss_paths(n: int, G: int, sd: float, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    return 40.0 + sd * rng.standard_normal((n, G))


# ---------------------------------------------------------------------------
# Known answers
# ---------------------------------------------------------------------------

def _scale(q, y, origin, floor=None, whole=None):
    n = len(y)
    floor = np.full(n, -np.inf) if floor is None else floor
    whole = np.zeros(n, bool) if whole is None else whole
    return C.fit_scale(q, y, C.origin_weights(origin), floor, whole)


def test_scale_fit_finds_the_over_wide_factor():
    q, y, lead, origin = _records(60, 6, sd_child=3.0, sd_truth=1.0)
    s = _scale(q, y, origin)
    assert np.allclose(s, 1 / 3, rtol=0.15), s
    q, y, lead, origin = _records(60, 6, sd_child=1.0, sd_truth=2.0, seed=1)    # too narrow: widen
    assert np.allclose(_scale(q, y, origin), 2.0, rtol=0.15)


def test_pit_fit_finds_the_childs_level():
    q, y, lead, origin = _records(60, 6, sd_child=3.0, sd_truth=1.0)
    h_lo, h_hi = C.fit_pit_sides(q, y, C.origin_weights(origin))
    want = 2 * norm.cdf(norm.ppf((1 + C.KNOTS) / 2) / 3) - 1          # the N(0,3²) level covering c of N(0,1)
    assert np.allclose(h_lo, want, atol=0.06) and np.allclose(h_hi, want, atol=0.06), (h_lo, h_hi, want)


def test_calibrated_child_needs_no_change():
    q, y, lead, origin = _records(60, 6, sd_child=2.0, sd_truth=2.0, seed=4)
    assert np.allclose(_scale(q, y, origin), 1.0, rtol=0.15)
    for h in C.fit_pit_sides(q, y, C.origin_weights(origin)):
        assert np.allclose(h, C.KNOTS, atol=0.07)


def test_the_fit_models_the_clip_at_the_floor():
    """A child whose lower half sits on the reading (its floor) and whose
    truth often stays there: scaling pushes no mass below the floor, so the
    fit sees the clip `apply` will do and does not widen without bound."""
    rng = np.random.default_rng(9)
    z = norm.ppf(C.level_grid(C.M_LEVELS))
    q = np.repeat(np.maximum(30.0 + 6.0 * z, 30.0)[None, :], 600, axis=0)
    y = np.maximum(30.0 + 2.0 * rng.standard_normal(600), 30.0)
    origin = np.repeat(np.arange(100), 6)
    s = _scale(q, y, origin, floor=np.full(600, 30.0))
    assert (s < 1.0).all() and (s > 1 / C.S_MAX).all(), s


def test_ties_at_the_reading_are_neutral():
    """An idle forecast flat at the reading whose truth sits on it says
    nothing about the spread: it must not drag the scale toward 0."""
    q, y, lead, origin = _records(40, 6, sd_child=1.0, sd_truth=1.0, seed=2)
    flat_q = np.full((len(y), C.M_LEVELS), 30.0)
    qq = np.vstack([q, flat_q])
    yy = np.concatenate([y, np.full(len(y), 30.0)])
    oo = np.concatenate([origin, origin + 1000])
    assert np.allclose(_scale(qq, yy, oo), 1.0, rtol=0.2)


@pytest.mark.parametrize("method", C.METHODS)
def test_an_over_wide_child_is_fixed(method):
    """Fit on one sample of origins, apply to fresh paths: the calibrated
    80 % range covers about 80 % of fresh truths (the child's: ~99 %), and
    the CRPS falls."""
    q, y, lead, origin = _records(60, 4, sd_child=3.0, sd_truth=1.0, seed=7)
    fit = C.fit_kind("seven_day", q, y, lead, origin, method)
    G, n = 4, 400
    grid_now = 0
    grid = np.array([600_000, 20_000_000, 100_000_000, 400_000_000])        # one grid time per lead bin
    P = _gauss_paths(n, G, 3.0, seed=11)
    V = C.apply(fit, P, grid, grid_now, round_whole=False)
    truth = 40.0 + np.random.default_rng(12).standard_normal((3000, G))

    def cover(X, c=0.8):
        lo, hi = np.quantile(X, (1 - c) / 2, axis=0), np.quantile(X, (1 + c) / 2, axis=0)
        return float(((truth >= lo) & (truth <= hi)).mean())

    def crps(X):
        return float(np.mean([np.abs(X[:, j][:, None] - truth[:, j][None, :]).mean()
                              - 0.5 * np.abs(X[:, j][:, None] - X[:, j][None, :]).mean() for j in range(G)]))
    assert cover(P) > 0.97
    assert abs(cover(V) - 0.8) < 0.06, (method, cover(V))
    assert crps(V) < crps(P) * 0.9


# ---------------------------------------------------------------------------
# Shrinkage, the median, coherence
# ---------------------------------------------------------------------------

def test_few_origins_shrink_toward_no_change():
    few = _records(4, 6, sd_child=3.0, sd_truth=1.0, seed=3)
    many = _records(60, 6, sd_child=3.0, sd_truth=1.0, seed=3)
    f_few, f_many = C.fit_kind("seven_day", *few, "scale"), C.fit_kind("seven_day", *many, "scale")
    s_few, s_many = np.asarray(f_few.s), np.asarray(f_many.s)
    assert (np.abs(np.log(s_few)) < np.abs(np.log(s_many))).all()
    assert (s_few < 1).all()
    tiny = _records(2, 6, sd_child=3.0, sd_truth=1.0, seed=3)
    assert C.fit_kind("seven_day", *tiny, "scale").is_identity()          # below min_origins: no change
    p_few, p_many = C.fit_kind("seven_day", *few, "pit"), C.fit_kind("seven_day", *many, "pit")
    for side in ("h_lo", "h_hi"):
        h_few, h_many = np.asarray(getattr(p_few, side)), np.asarray(getattr(p_many, side))
        assert (np.abs(h_few - C.KNOTS) < np.abs(h_many - C.KNOTS)).all()


def test_an_empty_lead_bin_takes_the_pooled_value():
    q, y, lead, origin = _records(30, 6, sd_child=3.0, sd_truth=1.0, seed=5, leads=(600.0, 20_000.0))
    fit = C.fit_kind("seven_day", q, y, lead, origin, "scale")
    assert fit.n_bin[2] == 0 and fit.n_bin[3] == 0
    pooled_like = np.asarray(fit.s[2])
    assert np.allclose(fit.s[3], pooled_like) and (pooled_like < 1).all()


def _random_fit(method: str, seed: int) -> C.KindFit:
    rng = np.random.default_rng(seed)
    f = C.KindFit.identity("seven_day", method)
    f.s = np.exp(rng.uniform(-1, 0.7, size=(4, 3))).tolist()
    f.h_lo = np.sort(rng.uniform(0.1, 0.99, size=(4, 3)), axis=1).tolist()
    f.h_hi = np.sort(rng.uniform(0.1, 0.99, size=(4, 3)), axis=1).tolist()
    return f


@pytest.mark.parametrize("method", C.METHODS)
def test_the_median_is_unchanged(method):
    grid = np.array([60_000, 3_600_000, 50_000_000, 300_000_000, 600_000_000])
    for seed in range(5):
        P = _gauss_paths(200, len(grid), 5.0, seed)                     # not monotone: no repair
        V = C.apply(_random_fit(method, seed), P, grid, 0, round_whole=False)
        assert np.allclose(np.median(V, axis=0), np.median(P, axis=0), atol=1e-9), method
        Pi = np.rint(P)                                                   # whole points: rounded back
        Vi = C.apply(_random_fit(method, seed), Pi, grid, 0, round_whole=True)
        assert np.all(Vi == np.rint(Vi))
        assert np.abs(np.median(Vi, axis=0) - np.median(Pi, axis=0)).max() <= 0.5


@pytest.mark.parametrize("method", C.METHODS)
def test_paths_stay_coherent(method):
    """Monotone, clipped, whole-point children give monotone, clipped,
    whole-point paths; every path keeps its rank in every column (before a
    monotone repair, which works path by path)."""
    rng = np.random.default_rng(1)
    grid = np.arange(1, 41) * 1_800_000
    inc = rng.poisson(0.6, size=(200, len(grid))) * (rng.random((200, 1)) < 0.7)
    P = np.minimum(30.0 + np.cumsum(inc, axis=1), 100.0)
    V = C.apply(_random_fit(method, 3), P, grid, 0)
    assert (np.diff(V, axis=1) >= 0).all()
    assert V.min() >= P.min() and V.max() <= 100.0 and np.all(V == np.rint(V))
    # Without the monotone repair (a child whose paths are not monotone) every
    # path keeps its rank in every column.
    Q = _gauss_paths(200, len(grid), 5.0, 4)
    Vs = C.apply(_random_fit(method, 3), Q, grid, 0, round_whole=False)
    for j in (0, 10, 39):
        a, b = Q[:, j], Vs[:, j]
        assert ((a[:, None] < a[None, :]) <= (b[:, None] <= b[None, :] + 1e-6)).all()


def test_identity_leaves_paths_alone():
    P = _gauss_paths(50, 3, 2.0, 0)
    assert C.apply(C.KindFit.identity("five_hour", "both"), P, np.array([1, 2, 3]) * 60_000, 0) is not None
    assert np.array_equal(C.apply(C.KindFit.identity("five_hour", "both"), P, np.array([1, 2, 3]) * 60_000, 0), P)
    assert np.array_equal(C.apply(None, P, np.array([1, 2, 3]) * 60_000, 0), P)


def test_fit_round_trips_through_json():
    f = C.fit_kind("five_hour", *_records(20, 4, 3.0, 1.0, leads=(300.0, 3600.0, 12000.0)), "both")
    g = C.KindFit.from_json(f.to_json())
    a1, a2 = f.at([100.0, 5000.0, 20000.0]), g.at([100.0, 5000.0, 20000.0])
    assert all(np.allclose(a1[k], a2[k]) for k in C.SIDES)


# ---------------------------------------------------------------------------
# No lookahead
# ---------------------------------------------------------------------------

def _frame(times, utils, reset, known_lag=1000):
    """A meter_frame (integer-ms clocks), as MeterIndex reads one."""
    times = np.asarray(times, dtype=np.int64)
    return pl.DataFrame({"t_event": times, "t_known": times + known_lag, "reset": [int(reset)] * len(times),
                         "util": np.asarray(utils, dtype=np.float64), "active": [True] * len(times)})


class _Meters:
    def __init__(self, idx):
        self.idx = idx

    def get(self, account, window, cap):
        return self.idx


def test_records_use_only_the_past():
    """A stored forecast is scored only on readings up to now, and only if
    it was made before now."""
    from arena.snapshot.cycles import MeterIndex
    from arena.types import Forecast, Request, Scope, Target, TargetForecast, TargetRequest
    H = 3_600_000
    reset = 100 * H
    times = np.arange(1, 90) * H
    frame = _frame(times, np.minimum(np.arange(1, 90) * 1.0, 100.0), reset)
    idx = MeterIndex(frame, "A1", "seven_day")
    store = C.Store(per_bin=1000)
    for origin in (10 * H, 60 * H):
        grid = np.arange(origin + H, reset + 1, H)
        req = Request(origin, Scope(("A1",)), (TargetRequest("k", Target.METER_7D, ("A1",), grid, "pct",
                                                            reset_at=reset),))
        store.add(req, Forecast({"k": TargetForecast(np.tile(np.linspace(0, 100, len(grid)), (20, 1)))}))
    now = 40 * H
    q, y, lead, origin, floor, whole = store.records(_Meters(idx), now)["seven_day"]
    assert set(origin.tolist()) == {10 * H}                               # the later forecast is not used
    assert (origin + lead * 1000 <= now).all()
    assert len(y) == 30 and y.min() == 11.0 and y.max() == 40.0          # the readings at 11 h .. 40 h


def test_the_fit_is_the_same_without_the_future(calib_data, calib_registry):
    """The wrapper's map at a moment is the same whether or not the snapshot
    holds anything after it: it learns only from the past."""
    from arena.cli_portfix import Local
    from arena.snapshot.views import SnapshotData
    from arena.types import Scope
    info = calib_registry.load("caltest-calib-wide")
    data = calib_data
    acct = data.accounts()[0]
    now = int(data.tier.start + 20 * 86_400_000)
    cut = SnapshotData({n: (df.filter(pl.col("t_known").dt.epoch("ms") <= now) if "t_known" in df.columns else df)
                        for n, df in data.tables.items()},
                       snapshot_id=data.snapshot_id, tier=data.tier, manifest=data.manifest)
    fits = []
    for d in (data, cut):
        local = Local(d)
        view = d.view(Scope((acct,), "scope_only"), "current_code", now - 12 * 86_400_000)
        m = local.instance(info, view, now)
        fits.append({k: f.to_json() for k, f in m.calibrate(now).items()})
    assert fits[0] and fits[0] == fits[1]
    assert any(f["n"] >= 3 for f in fits[0].values())


# ---------------------------------------------------------------------------
# End to end through the runner
# ---------------------------------------------------------------------------

def test_runner_narrows_an_over_wide_child(calib_data, calib_registry):
    from arena.cache import ChildCache
    from arena.runner import RunConfig, Runner
    wide = calib_registry.load("caltest-wide")
    cal = calib_registry.load("caltest-calib-wide")
    cfg = RunConfig(episodes=4, seed=4, in_process=True, checkpoint_cap=3, targets=("meter.seven_day",))
    out = Runner(calib_data, cfg, cache=ChildCache(enabled=False)).run([wide, cal])
    assert not out.failures, out.failures[:3]
    by: dict = {}
    for s in out.scores:
        if s["lead_s"] is None and s["metric"] in ("crps", "cover80"):
            by.setdefault((s["model_hash"], s["metric"]), []).append(s["value"])
    cw, cc = np.mean(by[(wide.hash, "cover80")]), np.mean(by[(cal.hash, "cover80")])
    assert abs(cc - 0.8) < abs(cw - 0.8), (cw, cc)
    assert np.mean(by[(cal.hash, "crps")]) < np.mean(by[(wide.hash, "crps")])
    assert any("calib seven_day" in lg["message"] for lg in out.logs)
