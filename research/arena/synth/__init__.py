"""Synthetic snapshots in the real schema and layout, with the generating
truth beside them (`truth/`). For harness tests with known answers, agents'
local debugging and the stress board — never for picking winners.

    from synth import SynthConfig, generate
    path = generate(SynthConfig(seed=1), "synth-default")

Command line: `arena synth --out ID --seed N [--users K] [--days D] …`
(arena/cli_synth.py).
"""
from __future__ import annotations

from pathlib import Path

from arena.snapshot import snapshot_dir

from .config import SynthConfig, load_config
from .world import World, simulate
from .writer import write_snapshot

__all__ = ["SynthConfig", "World", "generate", "load_config", "simulate", "write_snapshot"]


def generate(cfg: SynthConfig, snapshot_id: str, *, out_dir: Path | None = None, force: bool = False) -> Path:
    """Simulate and write a snapshot to <ARENA_HOME>/snapshots/<id> (or out_dir)."""
    world = simulate(cfg)
    return write_snapshot(world, out_dir or snapshot_dir(snapshot_id), snapshot_id, force=force)
