"""The runner: as-of at the protocol layer, children and their cache,
timeouts, errors, determinism, and example-linear end to end."""
import json
from pathlib import Path

import polars as pl
import pyarrow as pa
import pytest

import fixtures as fx
from arena.cache import ChildCache
from arena.registry import Registry
from arena.runner import LeakError, RunConfig, Runner, Timeouts, assert_as_of, summarize
from arena.snapshot.schema import DATA_TABLES
from arena.snapshot.views import EpisodeView
from arena.types import ScoreRow

HERE = Path(__file__).parent
REG = Registry([HERE / "models", HERE.parent.parent / "models"])


def stub_scorer(request, forecast, truth):
    """Scoring is built in parallel: a stub that checks the seam's shapes."""
    rows = []
    for tr in request.targets:
        tt = truth.by_key[tr.key]
        tf = forecast.by_key[tr.key]
        assert tf.paths.shape[1] == len(tr.grid)
        assert len(tt.times) == len(tt.values) and len(tt.times) > 0
        assert (tt.times > request.now).all()
        rows.append(ScoreRow(tr.key, str(tr.target), "stub_n", None, float(len(tt.times))))
    return rows


class Tap:
    """Sees every message the runner sends to any worker and checks the
    as-of rule there, independently of the runner's own assertion."""

    def __init__(self):
        self.fits, self.updates, self.roles = 0, 0, set()

    def __call__(self, role, msg):
        self.roles.add(role)
        if msg.type in ("fit", "update"):
            now = msg.header["now"] if msg.type == "fit" else msg.header["until"]
            assert set(msg.arrow) <= set(DATA_TABLES), set(msg.arrow) - set(DATA_TABLES)
            for name, t in msg.arrow.items():
                assert not any(c.startswith("_") for c in t.column_names)
                if t.num_rows:
                    tk = t.column("t_known").cast(pa.int64()).to_numpy()
                    assert tk.max() <= now, (name, int(tk.max()), now)
            self.fits += msg.type == "fit"
            self.updates += msg.type == "update"


def _run(data, models, *, scorer=stub_scorer, cache=None, **kw):
    cfg = RunConfig(**{"episodes": 4, "seed": 7, "in_process": True, "checkpoint_cap": 6, **kw})
    r = Runner(data, cfg, scorer=scorer, cache=cache or ChildCache(enabled=False))
    tap = Tap()
    r.tap = tap
    return r, r.run([REG.load(m) for m in models]), tap


@pytest.mark.parametrize("in_process", [True, False])
def test_no_future_row_reaches_a_worker(visible, in_process):
    r, out, tap = _run(visible, ["spy"], in_process=in_process, episodes=7)
    assert tap.fits >= 7 and tap.updates > 0
    assert not out.failures, out.failures[:3]
    assert out.scores
    if not in_process:
        # a worker process gets none of the runner's environment, and runs in its scratch dir
        assert {lg["message"] for lg in out.logs} == {"env ARENA_HOME=False cwd_is_scratch=True"}


def test_longrun_streams_one_episode_per_account(lockbox):
    r, out, tap = _run(lockbox, ["spy"], longrun=True, longrun_every=3 * fx.HOUR, scorer=stub_scorer)
    assert [e.scope.accounts for e in out.episodes] == [("A1",), ("A2",)]
    assert all(e.longrun and e.horizon_end == lockbox.tier.end for e in out.episodes)
    assert not out.failures, out.failures[:2]
    targets = {s["target"] for s in out.scores}
    assert {"meter.five_hour", "spend.hourly", "cycle.next_start"} <= targets
    cps = {s["checkpoint_t"] for s in out.scores}
    assert len(cps) > 10


def test_as_recorded_mode_holds_too(lockbox):
    r, out, tap = _run(lockbox, ["spy"], mode="as_recorded", episodes=7)
    assert not out.failures, out.failures[:3]
    assert tap.updates > 0


def test_runner_refuses_a_leaky_view(visible, monkeypatch):
    real = EpisodeView.history

    def leaky(self, now):
        out = real(self, now)
        out["turns"] = pl.concat([out["turns"], real(self, now + 10 * fx.DAY)["turns"].tail(1)])
        return out

    monkeypatch.setattr(EpisodeView, "history", leaky)
    with pytest.raises(LeakError):
        _run(visible, ["spy"], episodes=1)


def test_assert_as_of_rules():
    t = pa.table({"t_known": pa.array([1, 5], pa.timestamp("ms", tz="UTC"))})
    assert_as_of({"turns": t}, 5)
    with pytest.raises(LeakError):
        assert_as_of({"turns": t}, 4)
    with pytest.raises(LeakError):
        assert_as_of({"cycles": t}, 9)
    with pytest.raises(LeakError):
        assert_as_of({"turns": t.append_column("_vis", pa.array([1, 2]))}, 9)


def test_child_sees_exactly_the_parents_view(visible):
    r, out, tap = _run(visible, ["parent"], episodes=4, max_backtest_points=3)
    assert not out.failures, [f["message"][-400:] for f in out.failures[:2]]
    assert any("child ok" in lg["message"] for lg in out.logs)
    assert any(lg["message"].startswith("backtest items=") and not lg["message"].endswith("=0")
               for lg in out.logs)
    assert any("/childm" in role for role in tap.roles)
    # parent's paths are the child's + 1, scored through the stub
    assert out.scores


def test_child_cache_hits_across_runs(visible, tmp_path):
    cache = ChildCache(tmp_path / "children")
    r1, out1, _ = _run(visible, ["parent"], cache=cache, episodes=3, max_backtest_points=2, seed=3)
    assert cache.misses > 0 and not out1.failures
    spawned1 = r1._spawned
    cache2 = ChildCache(tmp_path / "children")          # a new run: from disk
    r2, out2, _ = _run(visible, ["parent"], cache=cache2, episodes=3, max_backtest_points=2, seed=3)
    assert cache2.hits > 0 and cache2.misses == 0
    assert r2._spawned < spawned1                        # no child workers the second time
    v1 = sorted((s["episode_id"], s["checkpoint_t"], s["target_key"], s["value"]) for s in out1.scores)
    v2 = sorted((s["episode_id"], s["checkpoint_t"], s["target_key"], s["value"]) for s in out2.scores)
    assert v1 == v2


def test_timeout_is_a_reported_miss(visible):
    for in_process in (False, True):
        cfg = dict(in_process=in_process, episodes=2, timeouts=Timeouts(start=60, fit=60, update=60, forecast=0.4))
        r, out, _ = _run(visible, ["sleeper"], **cfg)
        kinds = [f["kind"] for f in out.failures]
        assert kinds.count("timeout") == len(out.episodes) == 2, kinds   # one per episode; the run goes on
        assert not out.scores


def test_model_errors_never_kill_the_protocol(visible):
    r, out, _ = _run(visible, ["broken"], episodes=3, checkpoint_cap=8, in_process=False)
    kinds = {f["kind"] for f in out.failures}
    assert {"error", "invalid_forecast"} <= kinds, kinds
    assert "crash" not in kinds and "timeout" not in kinds
    assert out.scores                                  # the good checkpoints still count
    assert any("broken on purpose" in f["message"] for f in out.failures)


def test_deterministic_given_the_seed(visible):
    def scores(seed):
        _, out, _ = _run(visible, ["example-linear"], scorer=None, seed=seed, episodes=5)
        return [(s["episode_id"], s["checkpoint_t"], s["target_key"], s["metric"], s["value"]) for s in out.scores], \
            [e.fingerprint() for e in out.episodes]
    a, ea = scores(11)
    b, eb = scores(11)
    c, ec = scores(12)
    assert a == b and ea == eb
    assert ea != ec


def test_example_linear_end_to_end_subprocess(visible):
    _, out, _ = _run(visible, ["example-linear"], scorer=None, in_process=False, episodes=4)
    assert not out.failures
    s = summarize(out)
    assert s["targets"] and s["episodes"] == 4


def test_read_only_cache_degrades_to_memory(visible, tmp_path):
    ro = tmp_path / "ro"
    ro.mkdir()
    ro.chmod(0o500)
    try:
        cache = ChildCache(ro / "children")
        r, out, _ = _run(visible, ["parent"], cache=cache, episodes=2, max_backtest_points=1, seed=9)
        assert not out.failures and not cache.writable
    finally:
        ro.chmod(0o700)


def test_scorer_invalid_forecast_is_a_failure_row(visible, monkeypatch):
    class InvalidForecast(ValueError):
        pass

    def picky(request, forecast, truth):
        raise InvalidForecast("NaN in a path")

    import arena.runner as runner_mod
    monkeypatch.setattr(runner_mod, "invalid_forecast_error", lambda: InvalidForecast)
    _, out, _ = _run(visible, ["example-linear"], scorer=picky, episodes=2)
    assert out.failures and {f["kind"] for f in out.failures} == {"invalid_forecast"}
    assert not out.scores


def _launcher(tmp_path):
    """A worker command that logs how it was started, then becomes the default
    worker: what a Docker launcher does, minus Docker."""
    log = tmp_path / "launches.log"
    sh = tmp_path / "launch.sh"
    sh.write_text(f'#!/bin/sh\necho "$1 $2 $ARENA_HOME" >> {log}\nshift 2\nexec "$@"\n')
    sh.chmod(0o755)
    return log, sh


def test_worker_command_starts_every_worker_children_included(visible, tmp_path, monkeypatch):
    import sys
    from arena.runner import parse_command
    log, sh = _launcher(tmp_path)
    monkeypatch.setenv("ARENA_HOME", "/must/not/reach/the/worker")
    cmd = (str(sh), "{id}", "{model_dir}", sys.executable, "-m", "arena.worker")
    r, out, tap = _run(visible, ["parent"], episodes=2, max_backtest_points=2, in_process=False, worker_cmd=cmd)
    assert not out.failures, [f["message"][-400:] for f in out.failures[:2]]
    lines = [ln.split(" ") for ln in log.read_text().splitlines()]
    assert len(lines) == r._spawned and any(ln[1].endswith("/childm") for ln in lines)
    assert len({ln[0] for ln in lines}) == len(lines)                 # one id per worker
    assert all(len(ln) < 3 or not ln[2] for ln in lines)               # nothing of the runner's env
    # the same command from the environment, as JSON or a shell string
    monkeypatch.setenv("ARENA_WORKER_CMD", json.dumps(list(cmd)))
    r2, out2, _ = _run(visible, ["example-linear"], episodes=1, in_process=False, scorer=None)
    assert not out2.failures and r2.custom_worker
    assert parse_command("docker run -i --name 'a b' img") == ("docker", "run", "-i", "--name", "a b", "img")
    with pytest.raises(ValueError):
        _run(visible, ["example-linear"], episodes=1, in_process=True)


def test_kill_command_runs_when_a_worker_is_killed(visible, tmp_path):
    import sys
    log, sh = _launcher(tmp_path)
    killed = tmp_path / "killed.log"
    cmd = (str(sh), "{id}", "{model_dir}", sys.executable, "-m", "arena.worker")
    kill = ("/bin/sh", "-c", f'echo "$0" >> {killed}', "{id}")
    _, out, _ = _run(visible, ["sleeper"], episodes=1, in_process=False, worker_cmd=cmd, worker_kill_cmd=kill,
                     timeouts=Timeouts(start=60, fit=60, update=60, forecast=0.4))
    assert [f["kind"] for f in out.failures] == ["timeout"]
    ids = [ln.split(" ")[0] for ln in log.read_text().splitlines()]
    assert killed.read_text().split() == ids[:1]


def test_history_carries_the_device_tz_offset_as_known(visible):
    """`History.tz_offset_min`: the latest known turn's offset, any account,
    sent with every fit and update and kept by `extend`."""
    r, out, tap = _run(visible, ["spy"], episodes=3)
    seen = []

    def watch(role, msg):
        if msg.type in ("fit", "update"):
            now = msg.header["now"] if msg.type == "fit" else msg.header["until"]
            seen.append((now, msg.header.get("tz_offset_min")))
    r.tap = watch
    r.run([REG.load("spy")], episodes=out.episodes)
    assert seen and all(tz == r.index.tz_offset_at(now) for now, tz in seen)
    assert {tz for _, tz in seen} == {-240}                       # the fixture's offset
    first_turn = int(visible.tables["turns"]["t_known"].dt.epoch("ms").min())
    assert r.index.tz_offset_at(first_turn - 1) is None
    from arena.snapshot.views import EventsView, HistoryView
    from arena.types import Scope
    h = HistoryView({}, 0, Scope(("A1",)), tz_offset_min=-240)
    assert h.extend(EventsView({}, 0, 10)).tz_offset_min == -240
    assert h.extend(EventsView({}, 0, 10, tz_offset_min=60)).tz_offset_min == 60


@pytest.mark.parametrize("in_process", [True, False])
def test_jobs_give_the_same_rows_for_any_n(visible, tmp_path, in_process):
    """(model, episode) units in job processes: the same score, failure and
    forecast rows, in the same order, for one job or several."""
    models = [REG.load(m) for m in ("example-linear", "parent", "broken")]

    def run(jobs: int):
        cfg = RunConfig(episodes=5, seed=4, in_process=in_process, checkpoint_cap=5, jobs=jobs,
                        max_backtest_points=2, archive="quantiles")
        r = Runner(visible, cfg, cache=ChildCache(tmp_path / f"cache-{jobs}"))
        out = r.run(models)
        strip = lambda rows: [{k: v for k, v in x.items() if k != "run_id"} for x in rows]  # noqa: E731
        return (strip(out.scores), strip(out.failures), out.forecasts,
                [(t["model"], t["episode_id"]) for t in out.timings])

    one, three = run(1), run(3)
    assert one[0] and one[1]                       # scores, and broken's failures
    assert one == three
