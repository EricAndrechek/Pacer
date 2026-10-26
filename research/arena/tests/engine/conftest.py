import importlib.util
import os
import sys
import time
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
ARENA = HERE.parent.parent
HARNESS = ARENA.parent / "harness" / "pacer_replay.py"
sys.path.insert(0, str(HERE))


@pytest.fixture(scope="session")
def pr():
    """research/harness/pacer_replay.py, the earlier Python port the methods
    are checked against (stdlib only)."""
    if not HARNESS.is_file():
        pytest.skip("research/harness/pacer_replay.py is not in this checkout")
    spec = importlib.util.spec_from_file_location("pacer_replay_ref", HARNESS)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod                     # dataclasses look their module up
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def utc_tz():
    """pacer_replay reads the process time zone (datetime.fromtimestamp); pin
    it to UTC so its weekdays and hours match LocalClock(0)."""
    old = os.environ.get("TZ")
    os.environ["TZ"] = "UTC"
    time.tzset()
    yield
    if old is None:
        os.environ.pop("TZ", None)
    else:
        os.environ["TZ"] = old
    time.tzset()


def ramp_cycles(n: int, duration: float, start0: float, *, step: float = 300.0, seed: int = 0,
                peak: float = 60.0):
    """Hand-made cycles: a noisy, integer, non-decreasing climb read every
    `step` seconds, a different pace per cycle. [(t, y, start, reset)]."""
    rng = np.random.default_rng(seed)
    out = []
    for i in range(n):
        start = start0 + i * duration
        reset = start + duration
        t = np.arange(start + step, reset, step)
        pace = peak * rng.uniform(0.3, 1.6)
        frac = (t - start) / duration
        shape = frac ** rng.uniform(0.6, 1.8)
        y = np.minimum(100.0, np.floor(pace * shape + rng.uniform(0, 1, len(t))))
        y = np.maximum.accumulate(y)
        out.append((t, y, start, reset))
    return out
