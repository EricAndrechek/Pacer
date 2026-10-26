"""The prospective tier: `--after <ISO time | snapshot id>` scores frozen
models only at cutoffs after that moment, on a newer snapshot."""
import datetime as dt
import duckdb
import pytest

import fixtures
from arena.cli import main
from arena.episodes import SamplerConfig, TierIndex, sample_episodes
from arena.snapshot.views import SnapshotData, ms, resolve_after

def _iso(ms: int) -> str:
    return dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def test_resolve_after_accepts_times_and_snapshot_ids(arena_home):
    assert resolve_after(fixtures.T_LB) == fixtures.T_LB
    assert resolve_after(_iso(fixtures.T_LB)) == fixtures.T_LB
    assert resolve_after(_iso(fixtures.T_LB).replace("Z", "+00:00")) == fixtures.T_LB
    assert resolve_after("fx-old") == fixtures.T_LB          # its manifest's T_end
    assert resolve_after("fx") == fixtures.T_END
    with pytest.raises(ValueError):
        resolve_after("no-such-snapshot")


def test_tier_starts_after_the_freeze(arena_home):
    d = SnapshotData.load("fx", "prospective", after=fixtures.T_LB)
    assert (d.tier.start, d.tier.end) == (fixtures.T_LB, fixtures.T_END)
    assert d.after == fixtures.T_LB
    # history before the freeze is still served (models fit on everything known at a cutoff)
    assert d.tables["turns"].select(ms("t_known").min()).item() < fixtures.T_LB
    whole = SnapshotData.load("fx", "prospective")           # no --after: the whole data span, as before
    assert whole.tier.start < fixtures.T_LB and whole.after is None


def test_every_cutoff_falls_after_the_freeze(arena_home):
    d = SnapshotData.load("fx", "prospective", after=fixtures.T_LB)
    eps = sample_episodes(TierIndex(d), SamplerConfig(episodes=12, seed=5))
    assert eps
    assert all(e.cutoff > fixtures.T_LB for e in eps)
    assert all(min(e.checkpoints, default=e.cutoff) >= e.cutoff for e in eps)


def test_nothing_after_the_snapshot_end_is_an_error(arena_home):
    with pytest.raises(ValueError, match="nothing to score"):
        SnapshotData.load("fx", "prospective", after=fixtures.T_END)
    with pytest.raises(ValueError):
        SnapshotData.load("fx", "lockbox", after=fixtures.T_LB)


@pytest.mark.parametrize("jobs", ["1", "2"])
def test_cli_run_prospective(arena_home, tmp_path, jobs):
    db = tmp_path / f"p{jobs}.duckdb"
    rc = main(["run", "--models", "example-linear", "--tier", "prospective", "--after", "fx-old",
               "--snapshot", "fx", "--episodes", "3", "--seed", "2", "--checkpoints", "4",
               "--results-db", str(db), "--jobs", jobs] + (["--in-process"] if jobs == "1" else []))
    assert rc == 0
    con = duckdb.connect(str(db), read_only=True)
    assert con.execute("select tier from runs").fetchone()[0] == "prospective"
    cutoffs = [r[0] for r in con.execute("select epoch_ms(cutoff) from episodes").fetchall()]
    assert cutoffs and all(c > fixtures.T_LB for c in cutoffs)
    assert con.execute("select count(*) from scores").fetchone()[0] > 0


def test_cli_prospective_needs_after(arena_home):
    with pytest.raises(SystemExit, match="needs --after"):
        main(["run", "--models", "example-linear", "--tier", "prospective", "--snapshot", "fx",
              "--episodes", "1", "--in-process"])
    with pytest.raises(SystemExit, match="prospective only"):
        main(["run", "--models", "example-linear", "--tier", "lockbox", "--after", "fx-old", "--snapshot", "fx",
              "--episodes", "1", "--in-process"])
