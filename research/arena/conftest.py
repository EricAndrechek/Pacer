"""CI hook: with ARENA_CI=1 the tests that build or run Docker images are skipped
(a hosted runner has a Docker daemon, but those tests take minutes and test the
sandbox, not the code under review). Local runs are unaffected: they skip on
their own when Docker is unreachable."""
import os

import pytest


def pytest_collection_modifyitems(config, items):
    if os.environ.get("ARENA_CI") != "1":
        return
    skip = pytest.mark.skip(reason="ARENA_CI=1: Docker-dependent test")
    for item in items:
        if "docker" in item.path.name.lower():
            item.add_marker(skip)
