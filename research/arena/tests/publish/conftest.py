"""A private ARENA_HOME with core's fixture snapshot `fx` (T_train T0+8d,
T_leaderboard_end T0+10d, T_end T0+12d) and `fx-old`, the same data frozen
at T0+10d: a model written against `fx-old` is scored prospectively on `fx`
after that moment."""
import json
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent / "core"))

import fixtures  # noqa: E402


@pytest.fixture(scope="session")
def arena_home(tmp_path_factory):
    home = tmp_path_factory.mktemp("arena_home_publish")
    fixtures.build(home, "fx")
    fixtures.build(home, "fx-old")
    f = home / "snapshots" / "fx-old" / "manifest.json"
    m = json.loads(f.read_text())
    m["T_end"] = fixtures.T_LB
    f.write_text(json.dumps(m, indent=1))
    old = os.environ.get("ARENA_HOME")
    os.environ["ARENA_HOME"] = str(home)
    yield home
    if old is None:
        os.environ.pop("ARENA_HOME", None)
    else:
        os.environ["ARENA_HOME"] = old
