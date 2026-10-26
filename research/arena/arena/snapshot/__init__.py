"""Snapshot schema, on-disk layout and (from the harness core) as-of views."""
from __future__ import annotations

import os
from pathlib import Path


def arena_home() -> Path:
    """Where snapshots, the salt, results and caches live: outside the repo and
    outside every worktree, so all of them share one copy and an agent's
    sandbox can be pointed at exactly the parts it may read."""
    return Path(os.environ.get("ARENA_HOME", Path.home() / ".local/share/pacer-arena"))


def snapshot_dir(snapshot_id: str) -> Path:
    """<home>/snapshots/<id>/ holding manifest.json, train/, holdout/,
    labels/ and validation/ (docs/snapshot-spec.md §2.7)."""
    return arena_home() / "snapshots" / snapshot_id
