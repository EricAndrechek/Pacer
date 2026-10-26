"""`arena synth` registers on the shared parser and writes a snapshot."""
from __future__ import annotations

import argparse
import json

import pytest

from arena import cli_synth


def test_register_adds_the_subcommand():
    p = argparse.ArgumentParser(prog="arena")
    sub = p.add_subparsers(dest="cmd")
    cli_synth.register(sub)
    args = p.parse_args(["synth", "--out", "x", "--seed", "3", "--users", "2", "--days", "20", "--tiers", "3d,3d"])
    assert args.cmd == "synth" and args.func is cli_synth.run
    assert (args.out, args.seed, args.users, args.days, args.tiers) == ("x", 3, 2, 20, "3d,3d")


def test_cli_writes_into_arena_home(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("ARENA_HOME", str(tmp_path))
    argv = ["--out", "tiny", "--seed", "2", "--users", "2", "--days", "14", "--tiers", "2d,2d", "--scale", "0.2"]
    assert cli_synth.main(argv) == 0
    snap = tmp_path / "snapshots" / "tiny"
    man = json.loads((snap / "manifest.json").read_text())
    assert man["snapshot_id"] == "tiny" and man["validation"]["ok"]
    assert "turns" in capsys.readouterr().out
    with pytest.raises(FileExistsError):
        cli_synth.main(argv)
    assert cli_synth.main(argv + ["--force"]) == 0


def test_config_file_overrides(tmp_path, monkeypatch):
    monkeypatch.setenv("ARENA_HOME", str(tmp_path))
    cfg = tmp_path / "c.json"
    cfg.write_text(json.dumps({"meter": {"server_lag_s": 0.0}, "changes": {"regimes_include_injected": False}}))
    argv = ["--out", "cfg", "--seed", "2", "--users", "1", "--days", "14", "--tiers", "2d,2d", "--scale", "0.1",
            "--config", str(cfg)]
    assert cli_synth.main(argv) == 0
    params = json.loads((tmp_path / "snapshots" / "cfg" / "truth" / "params.json").read_text())
    assert params["config"]["meter"]["server_lag_s"] == 0.0
    assert params["config"]["users"] == 1
