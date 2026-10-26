"""Fixtures for the learned models and combiners: the `synth-default`
snapshot (seed 1, the generator's defaults: what `arena synth --out
synth-default --seed 1` writes), generated into a private ARENA_HOME.

ARENA_HOME is set only while a snapshot loads and is restored at once:
other areas' session fixtures set it for their own snapshots, and a
session-long change here would point their tests at this one."""
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
def synth_home(tmp_path_factory) -> Path:
    from synth import generate, load_config
    home = tmp_path_factory.mktemp("ml_arena_home")
    generate(load_config(None, seed=1), "synth-default", out_dir=home / "snapshots" / "synth-default")
    return home


@pytest.fixture(scope="session")
def synth_visible(synth_home):
    from arena.snapshot.views import SnapshotData
    with arena_home_at(synth_home):
        return SnapshotData.load("synth-default", "visible")


@pytest.fixture(scope="session")
def synth_full(synth_home):
    """Every tier's rows: room to look past a moment inside the visible tier."""
    from arena.snapshot.views import SnapshotData
    with arena_home_at(synth_home):
        return SnapshotData.load("synth-default", "prospective")


@pytest.fixture(scope="session")
def registry():
    from arena.registry import Registry
    return Registry([HERE / "models", ARENA / "models"])
