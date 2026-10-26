"""Fixtures for the fleet tests: a throwaway fleet root and ARENA_HOME under
pytest's tmp_path, a tiny dummy snapshot, and stand-ins for `claude` and
`pacer` so nothing here ever starts a real agent or reads Pacer."""
from __future__ import annotations

import json
import os
import stat
import sys
import textwrap
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
import pytest

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from fleet.paths import FleetPaths  # noqa: E402

T_TRAIN = 1_767_225_600_000
SNAP = "snap1"


def chmod_writable(root: Path) -> None:
    for dirpath, dirnames, filenames in os.walk(root):
        os.chmod(dirpath, 0o755)
        for f in filenames:
            p = Path(dirpath, f)
            if not p.is_symlink():
                os.chmod(p, 0o644)


@pytest.fixture
def paths(tmp_path):
    p = FleetPaths(tmp_path / "fleet", tmp_path / "home")
    p.root.mkdir()
    p.home.mkdir()
    yield p
    chmod_writable(tmp_path)


def make_snapshot(home: Path, snap: str = SNAP, marker: str = "HIDDEN-MARKER") -> Path:
    d = home / "snapshots" / snap
    (d / "train" / "turns" / "month=2025-12").mkdir(parents=True)
    ts = pa.timestamp("ms", tz="UTC")
    pq.write_table(pa.table({"t_event": pa.array([T_TRAIN - 10], ts), "t_known": pa.array([T_TRAIN - 5], ts),
                             "account": ["A1"]}), d / "train" / "turns" / "month=2025-12" / "p.parquet")
    (d / "holdout").mkdir()
    (d / "holdout" / "secret.txt").write_text(marker)
    (d / "labels").mkdir()
    pq.write_table(pa.table({"t_known": pa.array([T_TRAIN - 1, T_TRAIN + 1], ts), "cycle_id": ["a", "b"]}),
                   d / "labels" / "cycles.parquet")
    (d / "manifest.json").write_text(json.dumps({
        "id": snap, "T_train": T_TRAIN, "T_leaderboard_end": T_TRAIN + 1000, "T_end": T_TRAIN + 2000,
        "source_fingerprints": {"transcripts": 123}, "row_counts": {"turns": 99}}))
    (home / "salt").write_bytes(b"S" * 32)
    return d


@pytest.fixture
def snapshot(paths):
    return make_snapshot(paths.home)


def write_exe(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(text).lstrip())
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


@pytest.fixture
def fake_claude(tmp_path):
    """Prints Claude Code's init and result events for the session id it was
    given, records when it ran, optionally commits a model, and exits."""
    log = tmp_path / "fake-claude.log"
    exe = write_exe(tmp_path / "bin" / "claude", f"""
        #!/bin/bash
        if [ "$1" = "--version" ]; then echo "9.9.9 (Claude Code)"; exit 0; fi
        sid=""; model=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --session-id) sid="$2"; shift;;
            --model) model="$2"; shift;;
          esac
          shift
        done
        name=$(basename "$PWD")
        echo "start $name $(date +%s.%N) $model" >> {log}
        echo '{{"type":"system","subtype":"init","model":"'$model'","session_id":"'$sid'","permissionMode":"dontAsk","tools":["Bash","Read","Write","Edit","WebFetch","WebSearch"],"cwd":"'$PWD'"}}'
        echo '{{"type":"assistant","message":{{"content":[{{"type":"tool_use","id":"t1","name":"Bash","input":{{"command":"cat ~/.claude/projects/x"}}}}]}}}}'
        echo '{{"type":"user","message":{{"content":[{{"type":"tool_use_id","tool_use_id":"t1"}},{{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"cat: Operation not permitted"}}]}}}}'
        if [ -n "$FAKE_COMMIT" ] || [ -f .fake-commit ]; then
          mkdir -p "models/$name-m1"
          printf 'class Model:\\n    def __init__(self, ctx): pass\\n' > "models/$name-m1/model.py"
          printf 'name = "%s-m1"\\nchildren = ["example-linear"]\\n' "$name" > "models/$name-m1/model.toml"
          echo "# report from $name" > REPORT.md
          echo "# upstream from $name" > UPSTREAM.md
          if [ -f .fake-violate ]; then chmod u+w arena arena/types.py; echo "# edited" >> arena/types.py; fi
          git add -A models REPORT.md UPSTREAM.md arena >/dev/null 2>&1
          git commit -q -m "model from $name" >/dev/null 2>&1
        fi
        sleep "${{FAKE_SLEEP:-0.3}}"
        echo "end $name $(date +%s.%N)" >> {log}
        echo '{{"type":"result","subtype":"success","is_error":false,"num_turns":3,"total_cost_usd":0.01,"modelUsage":{{"'$model'":{{}}}}}}'
        exit 0
        """)
    return exe, log


@pytest.fixture
def fake_pacer(tmp_path):
    """`gate` answers from a script of exit codes (one per call), `wait` exits 0."""
    calls = tmp_path / "pacer-calls.log"
    codes = tmp_path / "pacer-codes"
    codes.write_text("")
    exe = write_exe(tmp_path / "bin" / "pacer", f"""
        #!/bin/bash
        echo "$@" >> {calls}
        if [ "$1" = "gate" ]; then
          code=$(head -1 {codes}); sed -i '' 1d {codes} 2>/dev/null
          [ -z "$code" ] && code=0
          [ "$code" = 10 ] && echo paused || echo go
          exit $code
        fi
        exit 0
        """)
    return exe, calls, codes
