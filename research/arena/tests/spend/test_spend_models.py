"""Every model of the spend area runs end to end on a small synthetic world
(the synth generator's defaults, fewer users and days), through the real
runner and scorer, with no failures; and the naive rules give their
hand-checkable answers."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from arena.cache import ChildCache
from arena.registry import Registry
from arena.runner import RunConfig, Runner
from arena.snapshot.views import SnapshotData
from arena.types import Target, TargetRequest
from kit import baselines as B
from spend_helpers import HOUR, MIN, T0, history, reading, turn

MODELS_DIR = Path(__file__).resolve().parents[2] / "models"
REG = Registry([MODELS_DIR])
OURS = ("port-live-meter", "spend-decay-30m", "spend-decay-1h", "spend-decay-6h", "spend-decay-1d",
        "naive-flat", "naive-linear-to-reset", "naive-seasonal-day", "naive-seasonal-week",
        "naive-diurnal-spend", "naive-split")


@pytest.fixture(scope="module")
def synth_visible(tmp_path_factory):
    from synth import SynthConfig, simulate, write_snapshot
    import os
    home = tmp_path_factory.mktemp("arena_home_spend")
    cfg = SynthConfig().merged(dict(seed=5, users=3, days=40, tiers="5d,5d", scale=0.5))
    write_snapshot(simulate(cfg), home / "snapshots" / "synth-spend", "synth-spend")
    old = os.environ.get("ARENA_HOME")
    os.environ["ARENA_HOME"] = str(home)
    try:
        yield SnapshotData.load("synth-spend", "visible")
    finally:
        if old is None:
            os.environ.pop("ARENA_HOME", None)
        else:
            os.environ["ARENA_HOME"] = old


def test_every_model_folder_loads():
    for name in OURS:
        info = REG.load(name)
        assert info.name == name and info.targets


@pytest.mark.parametrize("name", OURS)
def test_model_runs_on_synth(synth_visible, name):
    info = REG.load(name)
    cfg = RunConfig(episodes=4, seed=2, in_process=True, checkpoint_cap=4, n_paths=50)
    out = Runner(synth_visible, cfg, cache=ChildCache(enabled=False)).run([info])
    assert not out.failures, out.failures[:3]
    assert out.scores, f"{name} was scored on nothing"
    crps = [s["value"] for s in out.scores if s["metric"] == "crps" and s["lead_s"] is None]
    assert crps and all(np.isfinite(crps))


# ---------------------------------------------------------------------------
# The naive rules, by hand
# ---------------------------------------------------------------------------

def _req(target, grid, accounts=("A1",), reset=None, family=None):
    return TargetRequest(key="k", target=target, accounts=accounts, grid=np.asarray(grid, dtype=np.int64),
                         units="pct", reset_at=reset, family=family)


def test_meter_flat_and_linear():
    reset = T0 + 5 * HOUR
    reads = [reading("A1", T0 + HOUR, 10, reset), reading("A1", T0 + 2 * HOUR, 20, reset + 7)]
    h = history(T0 + 2 * HOUR + 10 * MIN, readings=reads)
    grid = [T0 + 3 * HOUR, T0 + 4 * HOUR, reset]
    flat = B.meter_flat(h, _req(Target.METER_5H, grid, reset=reset))
    assert flat.paths.tolist() == [[20, 20, 20]]
    # 20 points in the 2 h since the cycle's start (reset - 5 h = T0): 10 an hour.
    lin = B.meter_linear(h, _req(Target.METER_5H, grid, reset=reset))
    assert lin.paths[0].tolist() == pytest.approx([30, 40, 50])


def test_hourly_seasonal_and_split():
    now = T0 + 48 * HOUR
    t = [turn("A1", now - 23 * HOUR - 30 * MIN, "opus", 3.0),       # in the hour ending now - 23 h
         turn("A1", now - 30 * MIN, "opus", 1.0),
         turn("A2", now - 30 * MIN, "sonnet", 3.0)]
    h = history(now, turns=t, accounts=("A1", "A2"), view="all")
    grid = now + HOUR * np.arange(1, 27)
    day = B.hourly_seasonal(h, _req(Target.SPEND_HOURLY, grid), 24)
    v = day.paths[0]
    assert v[0] == pytest.approx(3.0)            # now + 1 h ← now - 23 h
    assert v[23] == pytest.approx(1.0)           # now + 24 h ← now
    assert v[24] == pytest.approx(3.0)           # now + 25 h ← now + 1 h ← now - 23 h
    assert v[[1, 2, 22, 25]].tolist() == [0, 0, 0, 0]
    share = B.split_recent(h, _req(Target.SPLIT, grid[:3]), ("A1", "A2"))
    assert share.paths[0].tolist() == pytest.approx([4 / 7] * 3)


def test_hourly_profile_paths_are_past_weeks():
    now = T0 + 21 * 24 * HOUR
    week = 7 * 24 * HOUR
    t = [turn("A1", now - k * week + HOUR - 30 * MIN, "opus", float(k)) for k in (1, 2, 3)]
    h = history(now, turns=t)
    h.start = now - 3 * week                      # an episode with three whole weeks of history
    f = B.hourly_profile(h, _req(Target.SPEND_HOURLY, now + HOUR * np.arange(1, 4)))
    assert sorted(f.paths[:, 0].tolist()) == [1.0, 2.0, 3.0]
    assert f.paths[:, 1:].sum() == 0
