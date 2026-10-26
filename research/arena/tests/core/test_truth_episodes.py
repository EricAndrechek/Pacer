"""Truth construction, cycle segmentation and the episode sampler."""
import numpy as np
import polars as pl
import pytest

import fixtures as fx
from arena.episodes import (
    GRID_HEAD, GRID_STEP, METER_TARGETS, SamplerConfig, TargetSpec, TierIndex, build_request, grid_for,
    sample_episodes, specs_at,
    target_key,
)
from arena.pricing import price_turns
from arena.runner import build_truth
from arena.snapshot.cycles import current_cycle, meter_frame, segment, window_ms
from arena.types import Scope, Target


@pytest.fixture(scope="module")
def index(lockbox):
    return TierIndex(lockbox)


def _raw_meter(data, acct, kind, cap=None):
    return meter_frame(data.tables["meter_readings"], acct, kind, cap)


def test_segment_uses_half_a_window_not_equality(lockbox):
    f = _raw_meter(lockbox, "A1", "five_hour")
    seg = segment(f, window_ms("five_hour"))
    act = seg.filter(pl.col("active"))
    # every reset inside one cycle is within half a window of the cycle's median
    assert ((act["reset"] - act["cycle_reset"]).abs() < window_ms("five_hour") / 2).all()
    # resets jitter, so == would split a cycle into many
    per_cycle = act.group_by("cycle").agg(pl.col("reset").n_unique().alias("distinct"))
    assert per_cycle["distinct"].max() > 1
    assert seg.filter(~pl.col("active"))["cycle"].null_count() == seg.filter(~pl.col("active")).height


def test_current_cycle_as_known(lockbox):
    v = lockbox.view(Scope(("A1",)))
    now = fx.T0 + 9 * fx.HOUR + 40 * fx.MIN          # inside A1's first block
    c = current_cycle(v.history(now)["meter_readings"], now, "A1", "five_hour")
    assert c is not None and c.reset_at > now and c.last_t <= now
    assert abs(c.reset_at - (fx.T0 + 14 * fx.HOUR)) < 1000
    assert current_cycle(v.history(fx.T0 + 2 * fx.HOUR)["meter_readings"], fx.T0 + 2 * fx.HOUR, "A1",
                         "five_hour") is None          # idle before the first turn


def test_meter_truth_stops_at_reset_and_never_interpolates(lockbox, index):
    m = index.meter("A1", Target.METER_5H)
    raw = _raw_meter(lockbox, "A1", "five_hour")
    pairs = set(zip(raw["t_event"].to_list(), raw["util"].to_list()))
    checked = 0
    for now in range(fx.T0 + 9 * fx.HOUR, fx.T0 + 6 * fx.DAY, 7 * fx.HOUR + 13 * fx.MIN):
        c = m.cycle_at(now)
        if c is None:
            continue
        spec = TargetSpec(target_key(Target.METER_5H, ("A1",)), Target.METER_5H, ("A1",), c.reset_at,
                          reset_at=c.reset_at)
        tt = build_truth(index, spec, now, grid_for(spec, now))
        assert (tt.times > now).all() and (tt.times <= c.reset_at).all()
        assert all((int(t), float(v)) in pairs for t, v in zip(tt.times, tt.values))   # real readings only
        assert (np.diff(tt.values) >= 0).all()                     # this fixture's meters never fall
        # the next cycle's readings exist but are not in this truth
        later = raw.filter((pl.col("t_event") > c.reset_at) & pl.col("active"))
        assert later.height > 0
        checked += 1
        if tt.hit_limit:
            assert tt.values.max() >= 100 and tt.time_to_limit == float(tt.times[tt.values >= 100][0])
    assert checked >= 3


def test_hourly_truth_matches_a_hand_sum(lockbox, index):
    now = fx.T0 + 9 * fx.HOUR + 5 * fx.MIN
    spec = TargetSpec(target_key(Target.SPEND_HOURLY, ("A1", "A2")), Target.SPEND_HOURLY, ("A1", "A2"),
                      now + fx.DAY)
    grid = grid_for(spec, now)
    assert (np.diff(grid) == fx.HOUR).all() and grid[0] == now + fx.HOUR
    tt = build_truth(index, spec, now, grid)
    priced = price_turns(lockbox.tables["turns"], lockbox.tables["prices"], output="best")
    t = priced["t_event"].dt.epoch("ms").to_numpy()
    c = priced["cost_usd"].to_numpy()
    for g, v in zip(tt.times, tt.values):
        sel = (t > g - fx.HOUR) & (t <= g)
        assert np.isclose(v, np.nansum(c[sel]))
    tok = TargetSpec(target_key(Target.TOKENS_HOURLY, ("A1",), family="opus"), Target.TOKENS_HOURLY, ("A1",),
                     now + fx.DAY, family="opus")
    assert build_truth(index, tok, now, grid).values.sum() > 0
    split = TargetSpec(target_key(Target.SPLIT, ("A1",)), Target.SPLIT, ("A1",), now + fx.DAY, group=("A1", "A2"))
    sv = build_truth(index, split, now, grid).values
    assert ((sv >= 0) & (sv <= 1)).all() and len(sv) > 0


def test_next_start_truth(index):
    m = index.meter("A2", Target.METER_5H)
    now = fx.T0 + 2 * fx.DAY + 2 * fx.HOUR            # A2 idle between its night block and its 11:00 block
    assert m.cycle_at(now) is None
    since = m.last_reset_before(now)
    spec = TargetSpec(target_key(Target.CYCLE_NEXT_START, ("A2",)), Target.CYCLE_NEXT_START, ("A2",),
                      now + fx.DAY, idle_since=since)
    tt = build_truth(index, spec, now, grid_for(spec, now))
    assert tt.next_start == tt.values[0]
    assert fx.T0 + 2 * fx.DAY + 11 * fx.HOUR <= tt.next_start < fx.T0 + 2 * fx.DAY + 11 * fx.HOUR + 20 * fx.MIN


def test_sampler_is_seeded_and_respects_the_tier(index):
    cfg = SamplerConfig(episodes=21, seed=5, checkpoint_cap=10)
    a = sample_episodes(index, cfg)
    b = sample_episodes(index, cfg)
    assert [e.fingerprint() for e in a] == [e.fingerprint() for e in b]
    assert len(a) > 0
    tier = index.tier
    for e in a:
        assert tier.start < e.cutoff <= tier.end and e.horizon_end <= tier.end
        assert e.history_start <= e.cutoff
        cps = e.checkpoints
        assert cps[0] == e.cutoff and list(cps) == sorted(set(cps)) and len(cps) <= 10
        assert all(c < e.horizon_end for c in cps)
        for s in e.targets:
            if s.target in METER_TARGETS:
                c = index.meter(s.accounts[0], s.target, s.cap).cycle_at(e.cutoff)
                assert c is not None and c.reset_at == s.reset_at          # active, as known at the cutoff
        for i, now in enumerate(cps):
            for s in specs_at(e, now, index, cfg):
                g = grid_for(s, now)
                assert (g > now).all() and (np.diff(g) > 0).all()
                if s.target in METER_TARGETS:
                    assert g[-1] == s.reset_at
                    step = GRID_STEP[s.target]
                    head = [now + h for h in GRID_HEAD[s.target] if now + h < s.reset_at]
                    assert list(g[:len(head)]) == head                         # the dense head
                    body = g[len(head):-1]
                    assert ((body - now) % step == 0).all() and (np.diff(body) == step).all()
    meter_eps = [e for e in a if e.primary.startswith("meter")]
    assert all(len(e.scope.accounts) == 1 for e in meter_eps)


def test_visible_tier_episodes_end_before_t_train(visible):
    idx = TierIndex(visible)
    for e in sample_episodes(idx, SamplerConfig(episodes=14, seed=2)):
        assert e.horizon_end <= fx.T_TRAIN


def test_meter_grids_have_a_dense_head_then_regular_steps():
    from arena.episodes import grid_for
    from arena.types import Target
    now, M = 1_000_000_000_000, 60_000
    five = TargetSpec("k", Target.METER_5H, ("A1",), now + 5 * 60 * M, reset_at=now + 5 * 60 * M)
    g = (grid_for(five, now) - now) // 1000
    assert list(g[:8]) == [30, 60, 120, 180, 300, 600, 900, 1200]
    assert g[-1] == 5 * 3600 and (np.diff(g[4:]) == 300).all()
    week = TargetSpec("w", Target.METER_7D, ("A1",), now + 7 * 1440 * M, reset_at=now + 7 * 1440 * M)
    g = (grid_for(week, now) - now) // M
    assert list(g[:6]) == [1, 5, 15, 30, 60, 90] and g[-1] == 7 * 1440
    # Near the reset the head is cut there and ends on the reset itself.
    near = TargetSpec("n", Target.METER_5H, ("A1",), now + 100_000, reset_at=now + 100_000)
    assert list(grid_for(near, now) - now) == [30_000, 60_000, 100_000]


def test_meter_truth_keeps_a_fall_under_the_same_reset():
    """An allowance re-based mid-cycle: the meter falls with its reset
    unchanged. Truth is every reading as read (no running max), the limit was
    still hit, and the value at reset is the last reading."""
    from arena.scoring import score_checkpoint
    from arena.snapshot.cycles import MeterIndex
    from arena.types import Forecast, Request, TargetForecast, Truth

    t0, reset = fx.T0, fx.T0 + 7 * fx.DAY
    te = [t0 + k * fx.HOUR for k in range(1, 7)]
    util = [40.0, 80.0, 100.0, 1.0, 5.0, 9.0]
    frame = pl.DataFrame({"t_event": te, "t_known": te, "reset": [reset + k for k in range(6)],
                          "util": util, "active": [True] * 6})
    m = MeterIndex(frame, "A1", "seven_day")

    class _Index:
        def meter(self, account, target, cap=None):
            return m

    spec = TargetSpec(target_key(Target.METER_7D, ("A1",)), Target.METER_7D, ("A1",), reset, reset_at=reset)
    grid = grid_for(spec, t0)
    tt = build_truth(_Index(), spec, t0, grid)
    assert tt.values.tolist() == util and tt.times.tolist() == te
    assert tt.hit_limit is True and tt.time_to_limit == float(te[2])

    tr = build_request(Scope(("A1",)), t0, [spec], 1).targets[0]
    req = Request(t0, Scope(("A1",)), (tr,))
    # A path through the readings, falling with them, scores ~0 and calls the
    # hit; a path that holds its maximum (a running max) misses the fall.
    follow = np.interp(grid, np.array(te, float), np.array(util))
    rows = {r.metric: r.value for r in score_checkpoint(
        req, Forecast({tr.key: TargetForecast.point(follow)}), Truth({tr.key: tt}))}
    assert rows["ae_reset"] < 1e-9 and rows["brier_hit"] == 0.0 and rows["crps"] < 1.0
    held = np.maximum.accumulate(follow)
    rows = {r.metric: r.value for r in score_checkpoint(
        req, Forecast({tr.key: TargetForecast.point(held)}), Truth({tr.key: tt}))}
    assert rows["ae_reset"] == pytest.approx(91.0) and rows["brier_hit"] == 0.0
