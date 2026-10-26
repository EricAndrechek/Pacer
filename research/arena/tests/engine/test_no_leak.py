"""Point in time: the engine reads only the History it is handed. The old
harness built the activity grid from the whole store; here changing anything
known after `now` must change nothing the engine says at `now`. Plus the
port-engine-* models end to end through the runner on the core fixture."""
import sys
from pathlib import Path

import numpy as np
import polars as pl
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "core"))

import fixtures as fx  # noqa: E402  (tests/core/fixtures.py)
from arena.registry import Registry  # noqa: E402
from arena.runner import RunConfig, Runner  # noqa: E402
from arena.cache import ChildCache  # noqa: E402
from arena.snapshot.views import HistoryView, SnapshotData  # noqa: E402
from arena.types import Scope  # noqa: E402
from kit.engine.clock import LocalClock  # noqa: E402
from kit.engine.engine import RULE  # noqa: E402
from kit.engine.model import EngineState  # noqa: E402
from kit.engine.series import activity_grid  # noqa: E402

MODELS = HERE.parent.parent / "models"
NOW = fx.T0 + 7 * fx.DAY + 10 * fx.HOUR + 7 * fx.MIN       # A1 mid-block: live 5-hour and 7-day cycles


@pytest.fixture(scope="module")
def fx_data(tmp_path_factory):
    home = tmp_path_factory.mktemp("engine_home")
    mp = pytest.MonkeyPatch()
    mp.setenv("ARENA_HOME", str(home))
    fx.build(home, "fx-engine")
    data = SnapshotData.load("fx-engine", "lockbox")
    yield data
    mp.undo()


def _outlooks(data: SnapshotData, now_ms: int, mode: str = "current_code"):
    scope = Scope(("A1",), "scope_only")
    hv = HistoryView(data.view(scope, mode).history(now_ms), now_ms, scope, mode)
    st = EngineState(RULE)
    out = {}
    for kind, cap in (("five_hour", None), ("seven_day", None), ("weekly_scoped", "Fable")):
        o = st.outlook(hv, "A1", kind, cap, now_ms / 1000.0)
        out[kind] = None if o is None else (o.method, o.value, tuple(o.residuals), o.selection)
    eng = st.engines[("A1", "seven_day", None)]
    grid = activity_grid(hv.table("turns"), "A1", now_ms / 1000.0, eng.clock)
    return out, grid, {k: sorted(e.record.scored) for k, e in st.engines.items()}


def _perturb_future(data: SnapshotData, now_ms: int) -> SnapshotData:
    """Every row known after now rewritten: readings pinned at 100, turns
    moved to other hours and tripled. Nothing known by now changes."""
    t = {n: df for n, df in data.tables.items()}
    tk = lambda: pl.col("t_known").dt.epoch("ms") > now_ms
    r = t["meter_readings"]
    t["meter_readings"] = r.with_columns(pl.when(tk()).then(100.0).otherwise(pl.col("util_pct")).alias("util_pct"))
    turns = t["turns"]
    fut = turns.filter(tk())
    shifted = [fut.with_columns((pl.col("t_event") + pl.duration(hours=h)).alias("t_event"),
                                (pl.col("t_known") + pl.duration(hours=h)).alias("t_known"),
                                (pl.col("call_id") + 10_000_000 * h).alias("call_id")) for h in (3, 7, 11)]
    t["turns"] = pl.concat([turns, *shifted], how="vertical_relaxed")
    return SnapshotData(t, snapshot_id="fx-engine-perturbed", tier=data.tier, manifest=data.manifest)


@pytest.mark.parametrize("mode", ["current_code", "as_recorded"])
def test_nothing_known_after_now_changes_the_outlook(fx_data, mode):
    a, grid_a, rec_a = _outlooks(fx_data, NOW, mode)
    assert a["five_hour"] is not None and a["seven_day"] is not None
    b, grid_b, rec_b = _outlooks(_perturb_future(fx_data, NOW), NOW, mode)
    assert a == b
    np.testing.assert_array_equal(grid_a, grid_b)
    assert rec_a == rec_b
    assert all(p <= NOW / 1000.0 for ps in rec_a.values() for p in ps)


def test_activity_grid_reads_only_complete_days_before_now():
    clock = LocalClock(0)
    now = fx.T0 / 1000.0 + 3 * 86400 + 15 * 3600
    rows = [(fx.T0 + d * fx.DAY + 9 * fx.HOUR, "A1") for d in range(3)]
    def frame(extra):
        rs = rows + extra
        return pl.DataFrame({
            "t_event": pl.Series([x for x, _ in rs]).cast(pl.Datetime("ms", "UTC")),
            "account": [a for _, a in rs], "model": ["claude-opus-4-5"] * len(rs),
            "input": [10] * len(rs), "output": [5] * len(rs), "cache_read": [0] * len(rs),
            "cache_write_5m": [0] * len(rs), "cache_write_1h": [0] * len(rs),
            "tz_offset_min": pl.Series([0] * len(rs), dtype=pl.Int16)})
    g = activity_grid(frame([]), "A1", now, clock)
    wd, hr = clock.weekday_hour(np.array([fx.T0 / 1000.0 + 9 * 3600]))
    assert g[wd[0], hr[0]] == 1.0 and g.sum() == 3.0
    today = [(fx.T0 + 3 * fx.DAY + 2 * fx.HOUR, "A1"), (fx.T0 + 3 * fx.DAY + 14 * fx.HOUR, "A1")]
    np.testing.assert_array_equal(activity_grid(frame(today), "A1", now, clock), g)
    other = [(fx.T0 + fx.DAY + 20 * fx.HOUR, "A2")]
    np.testing.assert_array_equal(activity_grid(frame(other), "A1", now, clock), g)


def test_port_engine_models_run_through_the_runner(fx_data):
    reg = Registry([MODELS])
    names = ["port-engine-rule", "port-engine-diurnal-rate", "port-engine-recent-rate"]
    infos = [reg.load(n) for n in names]
    visible = SnapshotData.load("fx-engine", "visible")
    cfg = RunConfig(episodes=4, seed=3, in_process=True, checkpoint_cap=4)
    out = Runner(visible, cfg, cache=ChildCache(enabled=False)).run(infos)
    assert not out.failures, out.failures[:3]
    scored = {(s["model"], s["target_key"].split(":")[0]) for s in out.scores}
    assert {m for m, _ in scored} == set(names)
    assert {"meter.five_hour", "meter.seven_day"} <= {t for _, t in scored}
