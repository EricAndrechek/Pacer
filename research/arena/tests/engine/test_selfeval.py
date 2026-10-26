"""Selection, the stand-in rule, conformal bands, paths and version tags,
against research/harness/pacer_replay.py where it has the same function."""
import numpy as np
import pytest

from conftest import ramp_cycles
from kit.engine import core
from kit.engine.clock import LocalClock
from kit.engine.engine import RULE, WindowEngine
from kit.engine.params import SHIPPING, VERSIONS, Params, fnv_tag
from kit.engine.paths import outlook_paths
from kit.engine.selfeval import (
    Record, best_method, calibrators, gated_quantile, quantile, resolve, score_cycles,
)

H5 = 5 * 3600.0
D7 = 7 * 86400.0
T0 = 1_790_000_000.0


def test_version_tags_are_the_ones_the_app_recorded(pr):
    assert SHIPPING.version_tag() == "v1-c13c3f81"
    assert SHIPPING.canonical() == pr.Params().canonical()
    eight = ";".join(SHIPPING.canonical().split(";")[:8])
    assert fnv_tag(eight) == "v1-6109fa45"
    legacy = eight.replace("conformalBlockMinCycles", "shadowPromotionMinPeriods=15;conformalBlockMinCycles")
    assert fnv_tag(legacy) == "v1-4c0cc586"
    assert set(VERSIONS) == {"v1-c13c3f81", "v1-6109fa45", "v1-4c0cc586"}


def _record(seed: int, n_cycles: int, duration: float):
    raw = ramp_cycles(n_cycles, duration, T0, seed=seed, step=300.0 if duration == H5 else 1800.0)
    cycles = [core.Cycle(t, y, s, r) for t, y, s, r in raw]
    rec = Record()
    score_cycles(rec, cycles, SHIPPING, clock=LocalClock(0), prior=None, methods=core.METHOD_IDS, now=np.inf)
    return rec, cycles


def _theirs(rec: Record):
    """The record in pacer_replay's shape: method -> period key -> [(cut, |err|)]."""
    out = {}
    for m, per in rec.rows.items():
        for p, cuts in per.items():
            out.setdefault(m, {})[str(int(p))] = [(cf, abs(v - rec.truth[p])) for cf, v in cuts.items()]
    return out


@pytest.mark.parametrize("duration,weekly", [(H5, False), (D7, True)])
@pytest.mark.parametrize("params", [SHIPPING, VERSIONS["v1-6109fa45"]])
def test_best_method_matches_pacer_replay(pr, duration, weekly, params):
    rec, _ = _record(3, 12, duration)
    theirs = _theirs(rec)
    ref = pr.Params(rl_select_by_phase=params.rl_select_by_phase, rl_tie_relative=params.rl_tie_relative)
    for phase in ("early", "late", None):
        assert best_method(rec, params, weekly, phase) == pr.best_method(theirs, ref, weekly, phase)


def test_best_method_needs_two_periods_and_breaks_ties_to_the_simpler():
    rec = Record()
    for p in (60.0, 120.0):
        rec.truth[p] = 50.0
        rec.add("kalman-trend", p, 0.6, 49.0)            # error 1.0, complexity 5
        rec.add("linear-recent", p, 0.6, 48.96)          # error 1.04: within 5% of the best
    rec.truth[180.0] = 50.0
    rec.add("saturating", 180.0, 0.6, 50.0)              # perfect, but one period only
    assert best_method(rec, SHIPPING, False, "late") == "linear-recent"
    assert best_method(rec, SHIPPING, False, "early") is None     # no early cuts scored


def test_resolve_stands_in_with_the_best_recorded_model_that_fits():
    rec, cycles = _record(5, 8, H5)
    c = cycles[-1]
    partial = core.Partial(c.t, c.y, c.start + H5 * 0.4, c.start, c.reset)
    fits = core.roster(None)
    fits["never"] = lambda cyc, p: None
    mid, proj = resolve(fits, "never", partial, rec, SHIPPING, False, "early")
    assert mid in core.DEFAULT_IDS and proj is not None
    errs = {m: np.median(rec.errors(m, "early")) for m in core.DEFAULT_IDS if fits[m](partial, SHIPPING)}
    assert errs[mid] == min(errs.values())


def test_gated_quantile_matches_pacer_replay(pr):
    rs = np.sort(np.random.default_rng(1).normal(0, 5, 23))
    for p in (0.1, 0.25, 0.5, 0.75, 0.9):
        assert gated_quantile(rs, p, 8) == pr.gated_quantile([(1.0, float(r)) for r in rs], p, 8)
    assert gated_quantile(rs[:7], 0.1, 8) is None
    assert quantile(rs, 0.0) == rs[0] and quantile(rs, 1.0) == rs[-1]


@pytest.mark.parametrize("n_cycles", [12, 45])           # per-cycle blocks below 40 cycles, cuts above
def test_calibrators_match_pacer_replay_without_a_record(pr, utc_tz, n_cycles):
    """With no record the Swift calibrators are the history walk, which is
    pacer_replay's `collect_residuals` in the shipping (auto) mode."""
    raw = ramp_cycles(n_cycles, H5, T0, seed=9)
    cycles = [core.Cycle(t, y, s, r) for t, y, s, r in raw]
    ours = calibrators("linear-recent", core.linear_recent, cycles, Record(), H5, LocalClock(0), SHIPPING)
    theirs = pr.collect_residuals(pr.linear_recent, pr.Params(),
                                  [pr.Cycle([(float(a), float(b)) for a, b in zip(c.t, c.y)], c.start, c.reset)
                                   for c in cycles], mode="auto")
    assert set(ours) == set(theirs)
    for k in ours:
        np.testing.assert_allclose(ours[k], np.sort([r for _, r in theirs[k]]), atol=1e-9)


def test_record_rows_override_the_history_walk():
    raw = ramp_cycles(10, H5, T0, seed=12)
    cycles = [core.Cycle(t, y, s, r) for t, y, s, r in raw]
    rec = Record()
    target = cycles[0].period
    rec.truth[target] = cycles[0].final
    for cf in core.RL_CUT_FRACTIONS:
        rec.add("linear-recent", target, cf, cycles[0].final - 77.0)   # residual 77 everywhere
    cal = calibrators("linear-recent", core.linear_recent, cycles, rec, H5, LocalClock(0), SHIPPING)
    assert 77.0 in cal["pooled"]                       # one block median per cycle (10 < 40 cycles)
    assert np.sum(cal["pooled"] == 77.0) == 1


def test_engine_outlook_and_paths_are_well_formed():
    raw = ramp_cycles(30, H5, T0, seed=21)
    t = np.concatenate([c[0] for c in raw])
    y = np.concatenate([c[1] for c in raw])
    r = np.concatenate([np.full(len(c[0]), c[3]) for c in raw])
    now = raw[-1][2] + H5 * 0.6
    m = t <= now
    eng = WindowEngine(H5, LocalClock(0), method=RULE)
    o = eng.observe(t[m], y[m], r[m], now, np.full((7, 24), 0.5))
    assert o is not None and o.method in core.METHOD_IDS and o.selection == "record"
    assert len(o.residuals) >= SHIPPING.conformal_min_residuals
    grid = np.append(np.arange(now + 300, o.reset, 300.0), o.reset)
    paths = outlook_paths(o, grid, 200, SHIPPING)
    assert paths.shape == (200, len(grid))
    assert np.all(np.diff(paths, axis=1) >= -1e-12)
    assert paths.min() >= o.used_now - 1e-9 and paths.max() <= 100.0
    lo, hi = np.quantile(paths[:, -1], [0.05, 0.95])
    assert lo <= o.value <= hi
    # Scored once: a second look at the same moment adds nothing.
    n = len(eng.record.scored)
    eng.observe(t[m], y[m], r[m], now, np.full((7, 24), 0.5))
    assert len(eng.record.scored) == n
    assert all(p <= now for p in eng.record.scored)


def test_gated_band_gives_a_single_path():
    raw = ramp_cycles(2, H5, T0, seed=8)
    t, y, s, reset = raw[-1]
    now = s + H5 * 0.5
    m = t <= now
    eng = WindowEngine(H5, LocalClock(0), method="linear-recent")
    o = eng.observe(t[m], y[m], np.full(m.sum(), reset), now, None)
    grid = np.append(np.arange(now + 300, reset, 300.0), reset)
    paths = outlook_paths(o, grid, 50, SHIPPING)
    assert np.all(paths == paths[0])                   # fewer than 8 residuals: no band
