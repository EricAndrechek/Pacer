"""Helpers for the synth tests (a unique module name, so it can't collide
with another area's test helpers on sys.path)."""
from __future__ import annotations

from pathlib import Path

import polars as pl

from synth import SynthConfig

SMALL = dict(seed=7, users=6, days=35, tiers="5d,5d", scale=0.3)


def small_config(**over) -> SynthConfig:
    cfg = SynthConfig().merged({**SMALL, **over})
    # At reduced scale the power user never nears the default 90 % rotation
    # threshold; lower it so the rotation controller acts in the test world.
    cfg.personas[0].rotate_threshold_5h = 45.0
    return cfg


def read_table(snap: Path, name: str, splits=("train", "holdout")) -> pl.DataFrame:
    """A whole data table from the written files (both splits), as a reader
    that knows nothing about the generator would assemble it."""
    files = []
    for sp in splits:
        single = snap / sp / f"{name}.parquet"
        if single.exists():
            files.append(single)
        files += sorted((snap / sp / name).glob("**/*.parquet")) if (snap / sp / name).is_dir() else []
    frames = [pl.read_parquet(f, hive_partitioning=False) for f in files]
    return pl.concat(frames) if frames else pl.DataFrame()


def ms(col: str) -> pl.Expr:
    return pl.col(col).dt.epoch("ms")
