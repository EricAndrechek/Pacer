import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

import fixtures  # noqa: E402


@pytest.fixture(scope="session")
def arena_home(tmp_path_factory):
    """A private ARENA_HOME holding the fixture snapshot `fx`."""
    home = tmp_path_factory.mktemp("arena_home")
    fixtures.build(home, "fx")
    old = os.environ.get("ARENA_HOME")
    os.environ["ARENA_HOME"] = str(home)
    yield home
    if old is None:
        os.environ.pop("ARENA_HOME", None)
    else:
        os.environ["ARENA_HOME"] = old


@pytest.fixture(scope="session")
def visible(arena_home):
    from arena.snapshot.views import SnapshotData
    return SnapshotData.load("fx", "visible")


@pytest.fixture(scope="session")
def lockbox(arena_home):
    from arena.snapshot.views import SnapshotData
    return SnapshotData.load("fx", "lockbox")
