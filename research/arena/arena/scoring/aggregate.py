"""Aggregation over a results database (DuckDB, `results_schema.sql`)."""
from __future__ import annotations

import duckdb
import polars as pl

PAIR = ["episode_id", "checkpoint_t", "target_key"]


def _where(run_id, tier, target, metric, snapshot=None):
    cl, args = [], []
    if run_id is not None:
        cl.append("s.run_id = ?"); args.append(run_id)
    if snapshot is not None:
        cl.append("r.snapshot_id = ?"); args.append(snapshot)
    if tier is not None:
        cl.append("r.tier = ?"); args.append(tier)
    if target is not None:
        cl.append("s.target = ?"); args.append(target)
    if metric is not None:
        cl.append("s.metric = ?"); args.append(metric)
    return (" WHERE " + " AND ".join(cl)) if cl else "", args


def load_scores(con: duckdb.DuckDBPyConnection, *, run_id: str | None = None,
                tier: str | None = None, target: str | None = None,
                metric: str | None = None, snapshot: str | None = None) -> pl.DataFrame:
    """Raw score rows with the model's name and the run's snapshot joined on.
    `model` is the model name when registered, else its hash."""
    where, args = _where(run_id, tier, target, metric, snapshot)
    q = f"""
        SELECT s.run_id, r.snapshot_id, s.episode_id, s.model_hash,
               COALESCE(m.name, s.model_hash) AS model,
               s.checkpoint_t, s.target_key, s.target, s.metric, s.lead_s, s.value
        FROM scores s
        JOIN runs r USING (run_id)
        LEFT JOIN models m USING (model_hash)
        {where}"""
    return pl.from_arrow(con.sql(q, params=args).to_arrow_table())


def aggregate(con, *, run_id=None, tier=None, target=None, metric=None) -> pl.DataFrame:
    """Per (run, model, target, metric, lead): mean, median and n."""
    df = load_scores(con, run_id=run_id, tier=tier, target=target, metric=metric)
    if df.is_empty():
        return df.select(["run_id", "model", "target", "metric", "lead_s"]).with_columns(
            pl.lit(None, pl.Float64).alias("mean"), pl.lit(None, pl.Float64).alias("median"),
            pl.lit(None, pl.UInt32).alias("n")).clear()
    return (df.group_by(["run_id", "model", "target", "metric", "lead_s"], maintain_order=True)
              .agg(pl.col("value").mean().alias("mean"),
                   pl.col("value").median().alias("median"),
                   pl.len().alias("n"))
              .sort(["run_id", "target", "metric", "lead_s", "model"], nulls_last=True))


def skill(df: pl.DataFrame, baseline: str, *, metric: str = "crps") -> pl.DataFrame:
    """1 - score/baseline per (run, model, target), on rows paired with the
    baseline's: only (episode, checkpoint, target_key) cells that both scored
    count, for both sides. `df` is `load_scores` output; whole-path rows only
    (lead_s null). The ratio is of means, so a few near-zero cells can't blow
    it up."""
    d = df.filter((pl.col("metric") == metric) & pl.col("lead_s").is_null())
    base = (d.filter(pl.col("model") == baseline)
              .select(["run_id", *PAIR, pl.col("value").alias("base")]))
    j = d.join(base, on=["run_id", *PAIR], how="inner")
    return (j.group_by(["run_id", "model", "target"], maintain_order=True)
              .agg(pl.col("value").mean().alias("score"),
                   pl.col("base").mean().alias("baseline_score"),
                   pl.len().alias("n_paired"))
              .with_columns((1 - pl.col("score") / pl.col("baseline_score")).alias("skill"))
              .sort(["run_id", "target", "model"]))
