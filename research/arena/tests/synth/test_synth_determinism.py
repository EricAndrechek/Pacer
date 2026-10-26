"""Same seed, same snapshot; another seed, another one."""
from __future__ import annotations

import json

from synth import simulate, write_snapshot
from synth_testutil import small_config


def _hashes(path):
    man = json.loads((path / "manifest.json").read_text())
    return {n: v["sha256"] for n, v in man["tables"].items()}, man["content_sha256"]


def test_same_seed_same_content(snap, tmp_path):
    again = write_snapshot(simulate(small_config()), tmp_path / "again", "again")
    assert _hashes(again) == _hashes(snap)
    assert (again / "truth" / "params.json").read_text() == (snap / "truth" / "params.json").read_text()


def test_other_seed_other_content(snap, tmp_path):
    other = write_snapshot(simulate(small_config(seed=8)), tmp_path / "other", "other")
    h1, c1 = _hashes(snap)
    h2, c2 = _hashes(other)
    assert c1 != c2 and h1["turns"] != h2["turns"] and h1["meter_readings"] != h2["meter_readings"]


def test_adding_a_user_keeps_the_others(world):
    """Users draw from their own seed streams: a 7th user leaves the first
    six users' activity untouched (their meters may differ only through the
    machine-wide polling)."""
    bigger = simulate(small_config(users=7))
    a = world.truth["spend_true"].filter(world.truth["spend_true"]["account"] == "A7")
    b = bigger.truth["spend_true"].filter(bigger.truth["spend_true"]["account"] == "A7")
    assert a["t_event"].to_list() == b["t_event"].to_list()
    assert json.dumps(world.params["resolved"]["users"][0]["spells"]) == \
        json.dumps(bigger.params["resolved"]["users"][0]["spells"])
