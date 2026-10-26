"""One small synthetic world and its written snapshot, shared by the synth
tests. Every persona (6 users) over 35 days at reduced scale: every injected
change and every era still falls inside the period, because their dates are
fractions of it."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from synth import simulate, write_snapshot
from synth_testutil import small_config


@pytest.fixture(scope="session")
def world():
    return simulate(small_config())


@pytest.fixture(scope="session")
def snap(world, tmp_path_factory) -> Path:
    out = tmp_path_factory.mktemp("arena_home") / "snapshots" / "synth-test"
    return write_snapshot(world, out, "synth-test")


@pytest.fixture(scope="session")
def manifest(snap) -> dict:
    return json.loads((snap / "manifest.json").read_text())


@pytest.fixture(scope="session")
def params(snap) -> dict:
    return json.loads((snap / "truth" / "params.json").read_text())
