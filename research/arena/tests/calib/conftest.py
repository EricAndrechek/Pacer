"""A small synthetic snapshot for the calibration layer and the port
fixtures (generated once per session into a private ARENA_HOME)."""
from __future__ import annotations

import os
import sys
from contextlib import contextmanager
from pathlib import Path

import pytest

HERE = Path(__file__).parent
ARENA = HERE.parent.parent
sys.path.insert(0, str(HERE))


@contextmanager
def arena_home_at(home: Path):
    old = os.environ.get("ARENA_HOME")
    os.environ["ARENA_HOME"] = str(home)
    try:
        yield
    finally:
        if old is None:
            os.environ.pop("ARENA_HOME", None)
        else:
            os.environ["ARENA_HOME"] = old


@pytest.fixture(scope="session")
def calib_home(tmp_path_factory) -> Path:
    from synth import generate, load_config
    home = tmp_path_factory.mktemp("calib_arena_home")
    generate(load_config(None, seed=5, users=2, days=45, tiers="1w,1w"), "synth-calib",
             out_dir=home / "snapshots" / "synth-calib")
    return home


@pytest.fixture(scope="session")
def calib_data(calib_home):
    from arena.snapshot.views import SnapshotData
    with arena_home_at(calib_home):
        return SnapshotData.load("synth-calib", "synthetic")


@pytest.fixture(scope="session")
def calib_registry():
    from arena.registry import Registry
    return Registry([HERE / "models", ARENA / "models"])
