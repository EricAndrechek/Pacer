"""Paired comparison over a bench results DB.

    python paired.py [--metric crps] [--base model] [model ...]

Prints, per target and metric, each model's mean over the cells (episode,
checkpoint, target_key) that every listed model scored, so the comparison is
not polluted by which episodes a model happened to answer.
"""
from __future__ import annotations

import argparse
import sys

import duckdb
import polars as pl

from arena.scoring.aggregate import load_scores

METRICS = ["crps", "ae_point", "ae_reset", "next_reading_ae", "energy", "variogram",
           "crps_ttl", "brier_hit", "cover50", "cover80", "cover95"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("models", nargs="*")
    ap.add_argument("--db", default="bench/*.duckdb")
    ap.add_argument("--metrics", default=",".join(METRICS))
    ap.add_argument("--run")
    a = ap.parse_args()
    import glob
    frames = []
    import shutil, tempfile, os
    tmp = tempfile.mkdtemp()
    for path in sorted(glob.glob(a.db)):
        # Copy first: a run still writing holds an exclusive lock.
        local = os.path.join(tmp, os.path.basename(path))
        try:
            shutil.copy(path, local)
            for ext in (".wal",):
                if os.path.exists(path + ext):
                    shutil.copy(path + ext, local + ext)
            con = duckdb.connect(local)
            frames.append(load_scores(con, run_id=a.run))
            con.close()
        except Exception as e:
            print(f"skip {os.path.basename(path)}: {type(e).__name__}", file=sys.stderr)
    shutil.rmtree(tmp, ignore_errors=True)
    if not frames:
        raise SystemExit(f"no results db matched {a.db}")
    df = pl.concat(frames, how="vertical_relaxed")
    if a.models:
        df = df.filter(pl.col("model").is_in(a.models))
    mets = a.metrics.split(",")
    df = df.filter(pl.col("lead_s").is_null() & pl.col("metric").is_in(mets))
    models = sorted(df["model"].unique().to_list())
    for target in sorted(df["target"].unique().to_list()):
        d = df.filter(pl.col("target") == target)
        print(f"=== {target}   ({d['episode_id'].n_unique()} episodes)")
        print(f"{'model':32s}" + "".join(f"{m[:11]:>12s}" for m in mets) + "   cells")
        rows = []
        for m in models:
            vals, ncell = {}, 0
            for met in mets:
                dm = d.filter(pl.col("metric") == met)
                keys = (dm.group_by(["episode_id", "checkpoint_t", "target_key"])
                          .agg(pl.col("model").n_unique().alias("k"))
                          .filter(pl.col("k") == dm["model"].n_unique()))
                dj = dm.join(keys.drop("k"), on=["episode_id", "checkpoint_t", "target_key"])
                v = dj.filter(pl.col("model") == m)
                vals[met] = v["value"].mean()
                ncell = max(ncell, v.height)
            rows.append((vals.get("crps") or 1e18, m, vals, ncell))
        for _, m, vals, n in sorted(rows):
            print(f"{m:32s}" + "".join(
                f"{vals[met]:12.4g}" if vals.get(met) is not None else f"{'-':>12s}" for met in mets)
                + f"   {n}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
