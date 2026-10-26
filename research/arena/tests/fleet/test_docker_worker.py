"""The hidden-tier isolation, for real: the runner on the host, each model
worker in its own Docker container started through ARENA_WORKER_CMD with no
data mounted (fleet/evalgate.py `worker_command`).

A probe model looks for the data every way it can from inside its worker:
ARENA_HOME in its environment, the snapshot's host paths and ARENA_HOME
itself (handed to it in its config, as if it had guessed them), the old
`/arena-home` mount point, any snapshot-shaped file anywhere on the
container's filesystem, and the network. It must find nothing. The same probe
run with the default worker (a host subprocess) finds the snapshot, which
proves the probe would have seen a leak.

Needs Docker and builds the worker image from this tree when it is missing
(once; the dependency layer is cached). Skipped when Docker is unreachable.
"""
from __future__ import annotations

import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

import pytest

ARENA = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ARENA / "tests" / "core"))

PROBE = textwrap.dedent('''
    import json, os, socket
    from pathlib import Path

    import numpy as np

    from arena.types import Forecast, TargetForecast

    SKIP = {"/proc", "/sys", "/dev", "/usr", "/lib", "/bin", "/sbin", "/etc", "/var/lib", "/opt/arena-src"}
    SNAPSHOT_FILES = (".parquet", "manifest.json", "salt", ".duckdb")


    class Model:
        def __init__(self, ctx):
            self.ctx = ctx

        def fit(self, history):
            cfg = self.ctx.config
            found = {"env": sorted(k for k in os.environ if k.startswith("ARENA") and
                                   k not in ("ARENA_WORKER", "ARENA_WORKER_SCRATCH")),
                     "env_values": [k for k, v in os.environ.items() if cfg["marker"] in v],
                     "paths": [], "files": [], "net": [], "walked": 0, "uid": os.getuid()}
            for p in cfg["paths"] + ["/arena-home"]:
                P = Path(p)
                try:
                    if P.is_dir() and any(P.iterdir()):
                        found["paths"].append(p)
                    elif P.is_file():
                        P.read_bytes()
                        found["paths"].append(p)
                except OSError:
                    pass
            # The whole filesystem, in a container only (on a host this would
            # walk the Mac); ARENA_WORKER_SCRATCH is set by the Docker launcher.
            for root, dirs, files in os.walk("/") if os.environ.get("ARENA_WORKER_SCRATCH") else ():
                dirs[:] = [d for d in dirs if os.path.join(root, d) not in SKIP]
                found["walked"] += 1
                for f in files:
                    if f.endswith(SNAPSHOT_FILES) or cfg["marker"] in f:
                        found["files"].append(os.path.join(root, f))
                if len(found["files"]) >= 5:
                    break
            for host, port in (("1.1.1.1", 53), ("8.8.8.8", 443), ("host.docker.internal", 80),
                               ("pypi.org", 443)):
                try:
                    socket.create_connection((host, port), timeout=2).close()
                    found["net"].append(host)
                except OSError:
                    pass
            self.ctx.log("PROBE " + json.dumps(found))

        def forecast(self, request):
            return Forecast({tr.key: TargetForecast.point(np.zeros(len(tr.grid))) for tr in request.targets})
''')


def _docker() -> str | None:
    docker = shutil.which("docker")
    if not docker:
        return None
    r = subprocess.run([docker, "info", "--format", "{{.ServerVersion}}"], capture_output=True, text=True)
    return docker if r.returncode == 0 else None


DOCKER = _docker()
pytestmark = pytest.mark.skipif(DOCKER is None, reason="Docker is not reachable")


@pytest.fixture(scope="module")
def image():
    from fleet.image import build_image
    return build_image(ARENA, docker=DOCKER)


@pytest.fixture
def world(tmp_path, monkeypatch):
    """An ARENA_HOME with the core fixture snapshot plus a marker file in its
    holdout, and a probe model in a folder Docker can share (under /tmp, not
    pytest's /private/var/folders)."""
    import fixtures
    home = tmp_path / "home"
    fixtures.build(home, "fx")
    marker = "MARKER" + secrets.token_hex(8)
    snap = home / "snapshots" / "fx"
    (snap / "holdout" / f"{marker}.txt").write_text(marker)
    monkeypatch.setenv("ARENA_HOME", str(home))
    models = Path(tempfile.mkdtemp(prefix="arena-dockertest-", dir="/tmp")) / "models"
    probe = models / "probe"
    probe.mkdir(parents=True)
    (probe / "model.py").write_text(PROBE)
    paths = [str(home), str(snap), str(snap / "holdout"), str(snap / "holdout" / f"{marker}.txt"),
             str(Path(os.path.realpath(snap)))]
    (probe / "model.toml").write_text(
        'name = "probe"\ntargets = ["meter.five_hour", "spend.hourly"]\n'
        f"[config]\nmarker = {json.dumps(marker)}\npaths = {json.dumps(paths)}\n")
    yield {"home": home, "models": models, "marker": marker}
    shutil.rmtree(models.parent, ignore_errors=True)


def _probe(world, worker_cmd=None, kill_cmd=None):
    from arena.cache import ChildCache
    from arena.registry import Registry
    from arena.runner import RunConfig, Runner
    from arena.snapshot.views import SnapshotData
    data = SnapshotData.load("fx", "leaderboard")
    cfg = RunConfig(tier="leaderboard", episodes=1, seed=5, checkpoint_cap=2, in_process=False,
                    worker_cmd=worker_cmd, worker_kill_cmd=kill_cmd, keep_logs=True)
    out = Runner(data, cfg, cache=ChildCache(enabled=False)).run([Registry([world["models"]]).load("probe")])
    probes = [json.loads(lg["message"][len("PROBE "):]) for lg in out.logs if lg["message"].startswith("PROBE ")]
    return out, probes


def test_docker_worker_finds_no_data_and_no_network(world, image):
    from fleet import evalgate
    prefix = "arena-test-" + secrets.token_hex(4)
    cfg = {**evalgate.DEFAULTS, "docker": DOCKER, "image": image}
    worker = evalgate.worker_command(cfg, models=world["models"], env=None, prefix=prefix)
    try:
        out, probes = _probe(world, tuple(worker), tuple(evalgate.kill_command(cfg)))
    finally:
        subprocess.run([DOCKER, "ps", "-aq", "--filter", f"name=^{prefix}-"], capture_output=True)
    assert not out.failures, [f["message"][-600:] for f in out.failures]
    assert probes, "the probe never ran"
    for p in probes:
        assert p["walked"] > 10 and p["uid"] == 65534, p          # it ran in the container, as nobody
        assert {k: p[k] for k in ("env", "env_values", "paths", "files", "net")} == \
            {"env": [], "env_values": [], "paths": [], "files": [], "net": []}, p
    left = subprocess.run([DOCKER, "ps", "-aq", "--filter", f"name=^{prefix}-"], capture_output=True, text=True)
    assert left.stdout.strip() == ""                       # --rm: every worker container is gone


def test_the_probe_sees_a_leak_when_there_is_one(world):
    """Control: a host-subprocess worker can read the snapshot, so the
    probe's empty report in Docker means there was nothing to find."""
    out, probes = _probe(world)
    assert not out.failures and probes
    assert any(world["marker"] in p for p in probes[0]["paths"])
