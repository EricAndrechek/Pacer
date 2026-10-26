"""Replay parity on the real snapshot: the port of the shipping rule, run in
`as_recorded` mode at moments the app recorded a rate-limit prediction,
must reproduce what it recorded. Skipped where the snapshot is absent (CI,
other machines). The full report is `uv run python -m kit.engine.parity`."""
import pytest

from arena.snapshot import arena_home, snapshot_dir
from kit.engine import parity

SNAPSHOT = "working-2026-10-24"
HOME = arena_home()          # read at collection: other tests point ARENA_HOME at fixtures later


def _have(sid: str) -> bool:
    try:
        d = snapshot_dir(sid)
    except Exception:
        return False
    return (d / "manifest.json").is_file() and (d / "labels" / "predictions_of_record.parquet").is_file()


pytestmark = pytest.mark.skipif(not _have(SNAPSHOT), reason=f"snapshot {SNAPSHOT} not on this machine")


@pytest.fixture(scope="module", autouse=True)
def real_home():
    mp = pytest.MonkeyPatch()
    mp.setenv("ARENA_HOME", str(HOME))
    yield
    mp.undo()


@pytest.fixture(scope="module")
def current(real_home):
    """The engine that ships (#311 onward), the first moments of every account."""
    return parity.classify(parity.run(SNAPSHOT, legacy_every=0, eras=("current",), max_moments=40))


def test_shipping_rule_reproduces_the_recorded_predictions(current):
    assert current.height >= 50
    valued = current.filter(current["rec_value"].is_not_null())
    within = (valued["abs_delta"] <= parity.TOLERANCE).mean()
    assert within >= 0.95, current.filter(current["cause"] != "match").head(10)
    assert (current["method"] == current["rec_method"]).mean() >= 0.95
    assert (current["used"] == current["rec_used"]).mean() >= 0.95


def test_the_recorded_method_reproduces_given_the_method(current):
    """Projection parity apart from selection: the as-of view, the cycle and
    each method's port."""
    g = current.filter(current["given_delta"].is_not_null())
    assert g.height >= 50
    assert (g["given_delta"] <= parity.TOLERANCE).mean() >= 0.95


def test_legacy_engine_is_reported_apart():
    df = parity.classify(parity.run(SNAPSHOT, accounts=["A2"], legacy_every=40, eras=("legacy",)))
    assert set(df["era"].unique()) == {"legacy"}
    g = df.filter(df["given_delta"].is_not_null())
    assert (g["given_delta"] <= parity.TOLERANCE).mean() >= 0.9
