"""arena-eval: argument validation, the budget, what it runs and what it
returns. The docker backend is never started here; the selftest backend
exercises everything up to the container."""
import json
import os
import subprocess
from pathlib import Path

import pytest

from fleet import evalgate, install
from fleet.evalgate import Failed, Refused

MODEL_PY = "class Model:\n    def __init__(self, ctx): pass\n"


def make_model(models: Path, name: str, toml: str = "", py: str = MODEL_PY) -> Path:
    d = models / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "model.py").write_text(py)
    (d / "model.toml").write_text(toml or f'name = "{name}"\n')
    return d


@pytest.fixture
def gate(paths):
    """An installed gate (selftest backend), generation 1, agents alice and bob."""
    install.install_gate(paths, python=None, backend="selftest")
    install.write_gen_eval_config(paths, 1, snapshot="snap1", image="img:test", episodes=7)
    for name in ("alice", "bob"):
        d = paths.agent_dir(1, name)
        make_model(d / "models", "m1")
        install.init_budget(paths, 1, name, 3)
        install.write_wrapper(paths, 1, name)
    return paths


def call(paths, agent, *args, cwd=None):
    argv = ["--agent", f"gen1/{agent}", "--", *args]
    return evalgate.run(argv, script=paths.eval_gate, cwd=cwd or paths.agent_dir(1, agent))


def used(paths, agent="alice"):
    return json.loads((paths.agent_state(1, agent) / "budget.json").read_text())["used"]


def test_happy_path_charges_once_and_returns_scores_only(gate):
    code, out = call(gate, "alice", "models/m1")
    assert code == 0
    assert set(out) == {"model", "model_hash", "tier", "episodes", "scores", "budget_left"}
    assert out["tier"] == "leaderboard" and out["episodes"] == 7 and out["budget_left"] == 2
    assert used(gate) == 1 and used(gate, "bob") == 0
    log = (gate.agent_state(1, "alice") / "calls.jsonl").read_text()
    assert '"event": "result"' in log and '"seed"' in log
    assert not list((gate.agent_state(1, "alice") / "staged").iterdir())   # staging cleaned up


def test_budget_query_is_free(gate):
    assert call(gate, "alice", "--budget")[1] == {"budget_left": 3, "budget": 3}
    assert used(gate) == 0


def test_budget_runs_out(gate):
    for _ in range(3):
        call(gate, "alice", "models/m1")
    with pytest.raises(Refused, match="spent"):
        call(gate, "alice", "models/m1")
    assert used(gate) == 3


@pytest.mark.parametrize("args", [
    [], ["models/m1", "models/m1"], ["--agent", "gen1/bob"], ["-rf"], ["models/m1;ls"],
    ["models/$(id)"], ["models/m 1"], ["models"], ["."], ["models/nope"], ["models/m1/model.py"],
])
def test_bad_arguments_refused_and_free(gate, args):
    with pytest.raises(Refused):
        call(gate, "alice", *args)
    assert used(gate) == 0


def test_only_own_folder(gate):
    bob = gate.agent_dir(1, "bob")
    for arg in (f"{bob}/models/m1", "../bob/models/m1", "models/../../bob/models/m1"):
        with pytest.raises(Refused, match="own folder|links"):
            call(gate, "alice", arg)
    # absolute path to its own model is fine, from anywhere
    assert call(gate, "alice", str(gate.agent_dir(1, "alice") / "models" / "m1"), cwd=Path("/"))[0] == 0


def test_identity_comes_from_the_wrapper_not_the_caller(gate):
    with pytest.raises(Refused):
        evalgate.run(["models/m1"], script=gate.eval_gate, cwd=gate.agent_dir(1, "alice"))
    with pytest.raises(Refused):
        evalgate.run(["--agent", "gen1/mallory", "--", "models/m1"], script=gate.eval_gate,
                     cwd=gate.agent_dir(1, "alice"))
    with pytest.raises(Refused):
        evalgate.run(["--agent", "gen1/../alice", "--", "models/m1"], script=gate.eval_gate, cwd=Path("/"))


def test_links_refused(gate):
    a = gate.agent_dir(1, "alice")
    os.symlink(gate.agent_dir(1, "bob") / "models" / "m1", a / "models" / "linked")
    with pytest.raises(Refused):
        call(gate, "alice", "models/linked")
    make_model(a / "models", "m2")
    os.symlink(gate.home, a / "models" / "m2" / "data")
    with pytest.raises(Refused, match="link"):
        call(gate, "alice", "models/m2")
    make_model(a / "models", "m3")
    os.symlink("/etc/hosts", a / "models" / "m3" / "hosts.txt")
    with pytest.raises(Refused, match="regular"):
        call(gate, "alice", "models/m3")
    assert used(gate) == 0


def test_models_dir_link_refused(gate):
    a = gate.agent_dir(1, "alice")
    import shutil
    shutil.rmtree(a / "models")
    os.symlink(gate.agent_dir(1, "bob") / "models", a / "models")
    with pytest.raises(Refused):
        call(gate, "alice", "models/m1")


def test_model_toml_rules(gate):
    m = gate.agent_dir(1, "alice") / "models"
    make_model(m, "urldep", 'deps = ["foo @ https://evil.example/x.whl"]\n')
    make_model(m, "optdep", 'deps = ["--index-url=https://evil.example"]\n')
    make_model(m, "badw", 'weights = ["../../etc"]\n')
    make_model(m, "nochild", 'children = ["ghost"]\n')
    make_model(m, "badtoml", "deps = [\n")
    for name in ("urldep", "optdep", "badw", "nochild", "badtoml"):
        with pytest.raises(Refused):
            call(gate, "alice", f"models/{name}")
    (m / "m1" / "model.toml").unlink()
    with pytest.raises(Refused, match="model.toml"):
        call(gate, "alice", "models/m1")
    assert used(gate) == 0


def test_children_are_staged_with_the_model(gate, monkeypatch):
    m = gate.agent_dir(1, "alice") / "models"
    make_model(m, "base")
    make_model(m, "combo", 'children = ["base"]\ndeps = ["lightgbm>=4"]\nweights = ["org/repo@abc"]\n')
    tree = evalgate.resolve_tree(m / "combo")
    assert set(tree) == {"combo", "base"}
    spec = evalgate.env_spec(tree, "img:test")
    assert spec == {"image": "img:test", "deps": ["lightgbm>=4"], "weights": ["org/repo@abc"]}
    assert evalgate.env_key(spec) and evalgate.env_key(evalgate.env_spec({"x": tree["base"]}, "img")) is None


def test_one_call_at_a_time_per_agent(gate):
    with evalgate.locked(gate.agent_state(1, "alice") / "eval.lock"):
        with pytest.raises(Refused, match="still running"):
            call(gate, "alice", "models/m1")
    assert used(gate) == 0


def test_refund_only_when_failure_reveals_nothing(gate, monkeypatch):
    cfg_path = gate.eval_config
    cfg = json.loads(cfg_path.read_text())
    cfg_path.chmod(0o644)
    cfg_path.write_text(json.dumps({**cfg, "backend": "docker"}))
    gen_cfg = gate.state / "gen1" / "eval.json"
    gen_cfg.chmod(0o644)
    gen_cfg.write_text(json.dumps({**json.loads(gen_cfg.read_text()), "runner_python": "/py/bin/python",
                                   "harness": "/fleet/templates/gen1"}))
    monkeypatch.setattr(evalgate, "fleet_slot", lambda *a, **k: _nullslot())
    monkeypatch.setattr(evalgate, "ensure_env", lambda *a, **k: (_ for _ in ()).throw(Failed("pip failed (not charged)", refund=True)))
    with pytest.raises(Failed):
        call(gate, "alice", "models/m1")
    assert used(gate) == 0
    monkeypatch.setattr(evalgate, "ensure_env", lambda *a, **k: None)
    monkeypatch.setattr(evalgate, "run_scoring", lambda *a, **k: (_ for _ in ()).throw(Failed("scoring failed")))
    with pytest.raises(Failed):
        call(gate, "alice", "models/m1")
    assert used(gate) == 1
    seen = {}
    monkeypatch.setattr(evalgate, "run_scoring", lambda cfg, cmd, name, log, **k: seen.setdefault("cmd", cmd) and
                        'noise\n{"scores": {"meter.five_hour": {"crps": 3.14159, "secret": "x"}}, "debug": "leak"}\n')
    code, out = call(gate, "alice", "models/m1")
    assert out["scores"] == {"meter.five_hour": {"crps": 3.14}}
    assert "debug" not in json.dumps(out)
    cmd = seen["cmd"]
    assert cmd[cmd.index("--seed") + 1].isdigit() and "--episodes" in cmd


class _nullslot:
    def __enter__(self):
        return 0

    def __exit__(self, *a):
        return False


def test_filter_scores_drops_everything_but_numbers():
    out = evalgate.filter_scores(
        '{"scores": {"meter.five_hour": {"crps": 1.23456, "ae_point": 0.000123456, "note": "hi", '
        '"Bad Key": 1, "nan": NaN}, "spend.hourly": 12345.678, "evil key with spaces": 1, '
        '"x": "text", "meter.seven_day": {"crps": null}}}', 3)
    assert out == {"meter.five_hour": {"crps": 1.23, "ae_point": 0.000123}, "spend.hourly": 12300.0,
                   "meter.seven_day": {"crps": None}}
    # core's `arena eval --json`: scores under "targets", beside counts we never pass on
    core = ('{"episodes": 40, "failures": {"timeout": 2}, "model": "abc", "seed": 7, "tier": "leaderboard", '
            '"targets": {"meter.five_hour": {"crps": 2.345678, "cover80": 0.81}}}')
    assert evalgate.filter_scores(core, 3) == {"meter.five_hour": {"crps": 2.35, "cover80": 0.81}}
    with pytest.raises(Failed):
        evalgate.filter_scores('{"seed": 7, "episodes": 3}', 3)
    with pytest.raises(Failed):
        evalgate.filter_scores("Traceback: something /Users/x/secret", 3)
    with pytest.raises(Failed):
        evalgate.filter_scores('{"scores": {"BAD": "x"}}', 3)


def test_worker_command_is_offline_capped_and_mounts_no_data(gate):
    """Each worker's container: no network, capped, read-only, unprivileged,
    the staged models and env read-only, and no data mount of any kind."""
    cfg = {**evalgate.DEFAULTS, "arena_home": str(gate.home), "fleet_root": str(gate.root), "image": "img:t"}
    cmd = evalgate.worker_command(cfg, models=Path("/st/models"), env=Path("/envs/k"), prefix="arena-eval-1-x")
    s = " ".join(cmd)
    for frag in ("run -i --rm", "--pull never", "--name arena-eval-1-x-{id}", "--network none", "--cpus 2",
                 "--memory 4g", "--memory-swap 4g", "--read-only", "--tmpfs /tmp:", "--cap-drop ALL",
                 "no-new-privileges", "--user 65534:65534", "--log-driver none", "/st/models:/st/models:ro",
                 "/envs/k:/env:ro", "HF_HUB_OFFLINE=1", "TMPDIR=/tmp", "ARENA_WORKER_SCRATCH=/tmp",
                 "/env/bin/python -m arena.worker"):
        assert frag in s, frag
    for var in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS", "NUMEXPR_NUM_THREADS",
                "POLARS_MAX_THREADS"):
        assert f"{var}=2" in cmd
    mounts = [cmd[i + 1] for i, a in enumerate(cmd) if a == "-v"]
    assert mounts == ["/st/models:/st/models:ro", "/envs/k:/env:ro"]
    assert "ARENA_HOME" not in s and "snapshots" not in s and str(gate.home) not in s


def test_runner_runs_on_the_host_from_the_pinned_harness(gate, monkeypatch):
    cfg = {**evalgate.DEFAULTS, "arena_home": str(gate.home), "fleet_root": str(gate.root), "image": "img:t",
           "tier": "leaderboard", "runner_python": "/fleet/state/gen1/runner-env/bin/python",
           "harness": "/fleet/templates/gen1", "docker": "/opt/bin/docker", "docker_host": "unix:///d.sock"}
    cmd = evalgate.runner_command(cfg, snapshot="snap1", model_dir=Path("/st/models/m1"), episodes=5, seed=42)
    assert cmd[:3] == ["/fleet/state/gen1/runner-env/bin/python", "-I", "-c"] and cmd[4] == "/fleet/templates/gen1"
    s = " ".join(cmd[5:])
    for frag in ("eval /st/models/m1", "--tier leaderboard", "--seed 42", "--episodes 5", "--snapshot snap1",
                 "--threads 2", "--sig 3", "--json", "--no-cache"):
        assert frag in s, frag
    assert "--record" not in cmd
    # the environment comes from the gate's config, never from the caller's
    monkeypatch.setenv("DOCKER_HOST", "unix:///agent/fake-daemon.sock")
    monkeypatch.setenv("PATH", "/agent/bin")
    worker = evalgate.worker_command(cfg, models=Path("/st/models"), env=None, prefix="p")
    env = evalgate.runner_env(cfg, worker=worker, tmp=Path("/st/tmp"))
    assert env["DOCKER_HOST"] == "unix:///d.sock" and "/agent" not in env["PATH"]
    assert env["PATH"].split(":")[0] == "/opt/bin"
    assert env["ARENA_HOME"] == str(gate.home) and json.loads(env["ARENA_WORKER_CMD"]) == worker
    assert json.loads(env["ARENA_WORKER_KILL_CMD"]) == ["/opt/bin/docker", "kill", "{id}"]
    assert set(env) <= {"PATH", "HOME", "LANG", "DOCKER_CONFIG", "DOCKER_HOST", "TMPDIR", "ARENA_HOME",
                        "ARENA_WORKER_CMD", "ARENA_WORKER_KILL_CMD", "PYTHONDONTWRITEBYTECODE"}
    with pytest.raises(RuntimeError):
        evalgate.runner_command({**cfg, "runner_python": None}, snapshot="s", model_dir=Path("/m"), episodes=1, seed=1)


def test_build_command_mounts_no_data(gate):
    cfg = {**evalgate.DEFAULTS, "arena_home": str(gate.home), "fleet_root": str(gate.root)}
    cmd = evalgate.build_command(cfg, {"image": "img", "deps": ["six"], "weights": []}, Path("/envs/k.building"), "b")
    mounts = [cmd[i + 1] for i, a in enumerate(cmd) if a == "-v"]
    assert "--rm" in cmd and not any("snapshots" in m or str(gate.home) in m.split(":")[0] for m in mounts)


def test_installed_gate_runs_through_the_wrapper(gate):
    """The real install: a pinned interpreter in -I mode, the wrapper exec'ing it."""
    head = gate.eval_gate.read_text().splitlines()[0]
    assert head.startswith("#!/") and head.endswith(" -I")
    assert oct(gate.eval_gate.stat().st_mode & 0o777) == "0o555"
    w = gate.eval_wrapper(1, "alice")
    assert w.read_text() == f'#!/bin/sh\nexec {gate.eval_gate} --agent gen1/alice -- "$@"\n'
    r = subprocess.run([str(w), "models/m1"], cwd=gate.agent_dir(1, "alice"), capture_output=True, text=True,
                       env={"PATH": "/usr/bin:/bin", "PYTHONPATH": "/nonexistent"})
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout)["scores"] == {"selftest": {"ok": 1.0}}
    r = subprocess.run([str(w), "../bob/models/m1"], cwd=gate.agent_dir(1, "alice"), capture_output=True, text=True)
    assert r.returncode == 2 and "refused" in r.stderr and r.stdout == ""
    assert used(gate) == 1 and used(gate, "bob") == 0


def test_internal_errors_show_no_detail(gate, monkeypatch, capsys):
    monkeypatch.setattr(evalgate, "stage", lambda *a: (_ for _ in ()).throw(RuntimeError(f"{gate.home}/secret")))
    rc = evalgate.main(["--agent", "gen1/alice", "--", str(gate.agent_dir(1, "alice") / "models" / "m1")],
                       script=gate.eval_gate)
    err = capsys.readouterr().err
    assert rc == 3 and str(gate.home) not in err
    assert used(gate) == 0
    assert "secret" in (gate.state / "eval-errors.log").read_text()


def test_model_hash_is_stable_and_content_addressed(tmp_path):
    a = make_model(tmp_path / "a", "m")
    b = make_model(tmp_path / "b", "m")
    (a / "__pycache__").mkdir()
    (a / "__pycache__" / "x.pyc").write_bytes(b"junk")
    assert evalgate.model_hash(a) == evalgate.model_hash(b)
    (b / "model.py").write_text(MODEL_PY + "# changed\n")
    assert evalgate.model_hash(a) != evalgate.model_hash(b)


def test_hash_matches_cores_registry(tmp_path):
    """Restated from core's arena/registry.py content_hash; if core is merged,
    compare against it directly."""
    import hashlib
    d = make_model(tmp_path, "m", py="x = 1\n")
    (d / "sub").mkdir()
    (d / "sub" / "a.py").write_text("y = 2\n")
    (d / ".venv").mkdir()
    (d / ".venv" / "junk.py").write_text("ignored\n")
    h = hashlib.sha256()
    for rel in ("model.py", "model.toml", "sub/a.py"):
        data = (d / rel).read_bytes()
        h.update(rel.encode() + b"\0" + len(data).to_bytes(8, "big") + data)
    assert evalgate.model_hash(d) == h.hexdigest()
    try:
        from arena.registry import ARENA_ROOT, code_hash, content_hash, folder_hash
    except ImportError:
        return
    assert folder_hash(d) == evalgate.model_hash(d)
    # The identity covers the shared code: the gate's restatement over the
    # harness root agrees with core's.
    assert evalgate.code_hash(ARENA_ROOT) == code_hash(ARENA_ROOT)
    assert content_hash(d) == evalgate.model_hash(d, harness=ARENA_ROOT)
    assert content_hash(d) != folder_hash(d)


def test_child_with_hash_prefix(tmp_path):
    m = tmp_path / "models"
    make_model(m, "base")
    make_model(m, "combo", 'children = ["base@abc123"]\n')
    assert set(evalgate.resolve_tree(m / "combo")) == {"combo", "base"}
