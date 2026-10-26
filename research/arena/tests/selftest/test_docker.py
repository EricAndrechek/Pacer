"""The leak probe on the real Docker worker path: a model in a container with
no network and no data mounted must find nothing — on BOTH worker paths the
one `arena selftest --docker` check exercises. Skipped without Docker.

This complements tests/fleet/test_docker_worker.py (which drives the probe
directly); here it is reached through the self-test harness, which also
asserts the probe gained no score over a constant."""
from __future__ import annotations

import shutil
import subprocess

import pytest

from arena.selftest import SelfTest


def _docker() -> str | None:
    docker = shutil.which("docker")
    if not docker:
        return None
    r = subprocess.run([docker, "info", "--format", "{{.ServerVersion}}"], capture_output=True, text=True)
    return docker if r.returncode == 0 else None


DOCKER = _docker()
pytestmark = pytest.mark.skipif(DOCKER is None, reason="Docker is not reachable")


def _dangling() -> int:
    r = subprocess.run([DOCKER, "volume", "ls", "-qf", "dangling=true"], capture_output=True, text=True)
    return len(r.stdout.split())


def test_leak_probe_passes_on_the_docker_worker(arena_home):
    before = _dangling()
    st = SelfTest("syn", tier="visible", seed=1, episodes=6, docker=True)
    r = st.check_leak_probes()
    assert r.passed, r.detail
    assert "docker:" in r.detail and "found nothing" in r.detail
    # --rm leaves no containers, and no anonymous volume piled up.
    left = subprocess.run([DOCKER, "ps", "-aq", "--filter", "name=^arena-selftest-"],
                          capture_output=True, text=True)
    assert left.stdout.strip() == ""
    assert _dangling() <= before + 1
