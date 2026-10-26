"""Fixtures for the self-test suite: one ARENA_HOME holding the core's
hand-built `fx` snapshot (fast, no truth/) and a small synthetic `syn`
snapshot (with truth/, for the recovery and calibration checks)."""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

ARENA = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ARENA / "tests" / "core"))     # fixtures.build
sys.path.insert(0, str(ARENA / "tests" / "synth"))    # synth_testutil.small_config


@pytest.fixture(scope="session")
def arena_home(tmp_path_factory):
    import fixtures
    from synth import simulate, write_snapshot
    from synth_testutil import small_config

    home = tmp_path_factory.mktemp("selftest_home")
    fixtures.build(home, "fx")
    write_snapshot(simulate(small_config()), home / "snapshots" / "syn", "syn")
    prev = os.environ.get("ARENA_HOME")
    os.environ["ARENA_HOME"] = str(home)
    yield home
    if prev is None:
        os.environ.pop("ARENA_HOME", None)
    else:
        os.environ["ARENA_HOME"] = prev
