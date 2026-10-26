"""The method ports against research/harness/pacer_replay.py on small
hand-made cycles, and the places this port follows Swift where pacer_replay
does not."""
import math

import numpy as np
import pytest

from conftest import ramp_cycles
from kit.engine import core
from kit.engine.clock import LocalClock
from kit.engine.params import Params
from kit.engine.selfeval import Record, score_cycles

P = Params()
H5 = 5 * 3600.0
D7 = 7 * 86400.0
T0 = 1_790_000_000.0
PAIRS = [("linear-recent", core.linear_recent, "linear_recent"),
         ("recent-rate", core.recent_rate, "recent_rate"),
         ("recency-weighted", core.recency_weighted, "recency_weighted"),
         ("damped-acceleration", core.damped_acceleration, "damped_acceleration"),
         ("saturating", core.saturating, "saturating"),
         ("kalman-trend", core.kalman_trend, "kalman_trend")]


def _theirs(pr, t, y, now, start, reset):
    seen = [(float(a), float(b)) for a, b in zip(t, y) if a <= now]
    return pr.Partial(seen, now, start, reset)


@pytest.mark.parametrize("duration", [H5, D7])
def test_every_method_matches_pacer_replay(pr, duration):
    rng = np.random.default_rng(11)
    checked = 0
    for trial in range(150):
        start = T0 + trial * duration
        reset = start + duration
        n = int(rng.integers(3, 60))
        t = np.sort(start + rng.uniform(30, duration * 0.95, n))
        y = np.minimum(100.0, np.cumsum(rng.choice([0, 0, 1, 2, 5], n)).astype(float))
        now = start + duration * rng.uniform(0.1, 0.95)
        ours = core.Partial(t, y, now, start, reset)
        if not len(ours.t):
            continue
        theirs = _theirs(pr, t, y, now, start, reset)
        for name, mine, ref in PAIRS:
            a, b = mine(ours, P), getattr(pr, ref)(theirs, pr.Params())
            assert (a is None) == (b is None), (name, trial)
            if a is None:
                continue
            checked += 1
            for at in (now, now + 600, reset):
                assert float(a(at)) == pytest.approx(b(at), rel=1e-9, abs=1e-7), (name, trial, at)
            assert core.displayed_at_reset(a, ours) == pytest.approx(
                pr.displayed_at_reset(b, theirs), rel=1e-9, abs=1e-7)
    assert checked > 300


def test_record_scoring_reproduces_the_swift_parity_fixture(pr):
    """pacer_replay's fixture is what Swift's RLDisplayedParityTests pins: the
    displayed value of six methods at every cut of four shaped cycles."""
    fx = pr.parity_fixture()
    rec = Record()
    cycles = []
    for c in fx["cycles"]:
        t = np.array([s[0] for s in c["samples"]])
        y = np.array([s[1] for s in c["samples"]])
        cycles.append(core.Cycle(t, y, c["cycleStart"], c["resetsAt"]))
    methods = tuple(m for m in core.DEFAULT_IDS)
    score_cycles(rec, cycles, P, clock=LocalClock(0), prior=None, methods=methods, now=math.inf)
    periods = [cyc.period for cyc in cycles]
    for row in fx["rows"]:
        cut = float(row["bucket"].split("|")[0][4:])
        got = rec.rows[row["method"]][periods[row["cycle"]]][cut]
        assert got == pytest.approx(row["predicted"], abs=1e-9), row
        assert rec.truth[periods[row["cycle"]]] == pytest.approx(row["truth"])


def test_segment_matches_pacer_replay(pr):
    rows = []
    for t, y, start, reset in ramp_cycles(4, H5, T0, seed=2):
        jitter = np.random.default_rng(int(start)).uniform(-0.4, 0.4, len(t))
        rows += [(float(a), float(b), reset + float(j)) for a, b, j in zip(t, y, jitter)]
    # An off-schedule reset inside the third group: a drop of 40 points to 2.
    t3 = [i for i, r in enumerate(rows) if abs(r[2] - (T0 + 3 * H5)) < 60]
    k = t3[len(t3) // 2]
    rows[k] = (rows[k][0], 2.0, rows[k][2])
    rows[k - 1] = (rows[k - 1][0], 42.0, rows[k - 1][2])
    rows.sort()
    t = np.array([r[0] for r in rows])
    y = np.array([r[1] for r in rows])
    r = np.array([r[2] for r in rows])
    cycles, _ = core.segment_all(t, y, r, H5)
    theirs = pr.segment(rows, H5)
    assert len(cycles) == len(theirs)
    for a, b in zip(cycles, theirs):
        assert a.start == pytest.approx(b.cycle_start) and a.reset == pytest.approx(b.resets_at)
        assert list(a.t) == [s[0] for s in b.samples] and list(a.y) == [s[1] for s in b.samples]
    assert any(c.start != c.reset - H5 for c in cycles)          # the split re-anchored a start


def test_partial_prepends_the_opening_zero():
    c = core.Partial(np.array([T0 + 600, T0 + 900]), np.array([3.0, 4.0]), T0 + 1000, T0, T0 + H5)
    assert list(c.y) == [0.0, 3.0, 4.0] and c.t[0] == T0
    off = core.Partial(np.array([T0 + 600, T0 + 900]), np.array([3.0, 4.0]), T0 + 1000, T0, T0 + H5,
                       zero_anchor=False)
    assert list(off.y) == [3.0, 4.0]


def test_displayed_value_is_anchored_and_clamped():
    c = core.Partial(np.array([T0 + 600, T0 + 1200, T0 + 1800]), np.array([10.0, 20.0, 50.0]),
                     T0 + 1800, T0, T0 + H5)
    under = lambda t: 5.0 + 0 * np.asarray(t, dtype=float)         # sits under the reading
    assert core.displayed_at_reset(under, c) == 50.0
    over = lambda t: 50.0 + (np.asarray(t, dtype=float) - c.now) # runs far past 100
    assert core.displayed_at_reset(over, c) == 100.0
    path = core.displayed_path(over, c, np.array([c.now + 10, c.now + 30, c.reset]))
    assert np.all(np.diff(path) >= 0) and path[-1] == 100.0


def test_diurnal_table_and_fit_match_pacer_replay(pr, utc_tz):
    raw = ramp_cycles(5, D7, T0, step=1800.0, seed=4)
    cycles = [core.Cycle(t, y, s, r) for t, y, s, r in raw]
    prior = np.random.default_rng(5).uniform(0, 1, (7, 24))
    clock = LocalClock(0)
    ours = core.diurnal_rate_table(cycles[:-1], prior, clock)
    theirs = pr.diurnal_rate_table([pr.Cycle([(float(a), float(b)) for a, b in zip(c.t, c.y)], c.start, c.reset)
                                    for c in cycles[:-1]], prior.tolist())
    np.testing.assert_allclose(ours, np.array(theirs), rtol=1e-12)
    t, y, start, reset = raw[-1]
    for cf in (0.3, 0.5, 0.8):
        now = start + D7 * cf
        mine = core.Diurnal(ours, clock)(core.Partial(t, y, now, start, reset), P)
        ref = pr.diurnal_fit(theirs)(_theirs(pr, t, y, now, start, reset), pr.Params())
        assert mine is not None and ref is not None
        for at in (now + 3600, reset):
            assert float(mine(at)) == pytest.approx(ref(at), rel=1e-9)


def test_diurnal_declines_before_five_percent_of_expected_activity():
    """Swift's DiurnalBurnModel.minObservedShare, which pacer_replay lacks:
    3% used three hours into a 7-day window is no basis for a level."""
    table = np.ones((7, 24))
    d = core.Diurnal(table, LocalClock(0))
    t = np.array([T0 + 3600, T0 + 7200, T0 + 3 * 3600])
    y = np.array([1.0, 2.0, 3.0])
    assert d(core.Partial(t, y, T0 + 3 * 3600, T0, T0 + D7), P) is None
    later = core.Partial(np.append(t, T0 + 20 * 3600), np.append(y, 9.0), T0 + 20 * 3600, T0, T0 + D7)
    assert d(later, P) is not None


def test_trend_singularity_test_is_relative_like_swift():
    """TrendEstimator's epsilon scales with the design; readings stacked at
    one instant are degenerate however many there are."""
    t = np.full(5, T0 + 3600.0)
    c = core.Partial(t, np.arange(5.0), T0 + 4000, T0, T0 + H5, zero_anchor=False)
    assert core.recency_weighted(c, P) is None


def test_engine_clock_uses_the_device_offset_while_no_turn_says():
    from arena.snapshot.views import HistoryView
    from arena.types import Scope
    from kit.engine.model import EngineState
    st = EngineState()
    h = HistoryView({}, 10_000, Scope(("A1",)), tz_offset_min=-240)
    assert st.clock(h, "A1", 10.0).offset_s == -240 * 60.0
    assert st.clock(HistoryView({}, 10_000, Scope(("A1",))), "A1", 10.0).offset_s == 0.0
