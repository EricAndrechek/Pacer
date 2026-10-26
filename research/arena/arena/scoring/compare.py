"""Paired comparisons. Everything is paired on identical
(episode, checkpoint, target_key) cells, never on model means alone.

Sign convention everywhere: difference = loss(A) - loss(B), so a NEGATIVE
difference (and a negative Diebold-Mariano statistic) means A is better.
"""
from __future__ import annotations

import math

import numpy as np
import pandas as pd
import polars as pl
from scipy import stats

PAIR = ["episode_id", "checkpoint_t", "target_key"]


def _whole(df: pl.DataFrame, metric: str, model_col: str = "model") -> pl.DataFrame:
    return df.filter((pl.col("metric") == metric) & pl.col("lead_s").is_null())


def paired_differences(scores: pl.DataFrame, a: str, b: str, metric: str = "crps",
                       *, target: str | None = None) -> pl.DataFrame:
    """Rows (episode_id, checkpoint_t, target_key, diff) with diff = A - B,
    only where both models scored the same cell."""
    d = _whole(scores, metric)
    if target is not None:
        d = d.filter(pl.col("target") == target)
    key = ["run_id", *PAIR]
    left = d.filter(pl.col("model") == a).select(key + [pl.col("value").alias("a")])
    right = d.filter(pl.col("model") == b).select(key + [pl.col("value").alias("b")])
    return (left.join(right, on=key, how="inner")
                .with_columns((pl.col("a") - pl.col("b")).alias("diff")))


def week_block_bootstrap_ci(diffs: pl.DataFrame, *, reps: int = 2000, alpha: float = 0.05,
                            seed: int = 0) -> dict:
    """Mean paired difference with a percentile CI that resamples whole ISO
    weeks of `checkpoint_t` (checkpoints in a week are correlated)."""
    if diffs.is_empty():
        return {"mean": math.nan, "lo": math.nan, "hi": math.nan, "n": 0, "n_weeks": 0}
    wk = diffs.with_columns(pl.col("checkpoint_t").dt.iso_year().alias("_y"),
                            pl.col("checkpoint_t").dt.week().alias("_w"))
    g = wk.group_by(["_y", "_w"]).agg(pl.col("diff").sum().alias("s"), pl.len().alias("n"))
    s, n = g["s"].to_numpy(), g["n"].to_numpy().astype(float)
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, len(s), size=(reps, len(s)))
    means = s[idx].sum(axis=1) / n[idx].sum(axis=1)
    lo, hi = np.quantile(means, [alpha / 2, 1 - alpha / 2])
    return {"mean": float(s.sum() / n.sum()), "lo": float(lo), "hi": float(hi),
            "n": int(n.sum()), "n_weeks": int(len(s))}


def diebold_mariano(d, *, lag: int | None = None) -> dict:
    """Diebold-Mariano test on a loss-difference series `d` (A - B, e.g. the
    per-episode mean difference), with a Newey-West (Bartlett) HAC variance.
    Statistic < 0 means A has the lower loss. Two-sided normal p-value."""
    d = np.asarray(d, dtype=np.float64)
    d = d[np.isfinite(d)]
    n = len(d)
    if n < 3:
        return {"stat": math.nan, "p": math.nan, "mean": float(d.mean()) if n else math.nan, "n": n}
    if lag is None:
        lag = int(math.floor(n ** (1 / 3)))
    lag = min(lag, n - 1)
    mean = d.mean()
    e = d - mean
    var = float(e @ e) / n
    for k in range(1, lag + 1):
        w = 1 - k / (lag + 1)
        var += 2 * w * float(e[k:] @ e[:-k]) / n
    var = max(var, 0.0)
    if var == 0.0:
        stat = 0.0 if mean == 0 else math.copysign(math.inf, mean)
    else:
        stat = float(mean / math.sqrt(var / n))
    p = float(2 * stats.norm.sf(abs(stat))) if math.isfinite(stat) else 0.0
    return {"stat": stat, "p": p, "mean": float(mean), "n": n}


def model_confidence_set(losses: pd.DataFrame, *, size: float = 0.10, reps: int = 1000,
                         block_size: int | None = None, seed: int = 0) -> list[str]:
    """Hansen's Model Confidence Set (arch's `MCS`, T_max statistic): the
    models statistically tied for best at confidence 1 - size. `losses` is
    [observations, models], one column per model, paired rows (identical
    observations for every model). A single model is trivially the set."""
    cols = list(losses.columns)
    if len(cols) < 2:
        return cols
    from arch.bootstrap import MCS
    if block_size is None:
        block_size = max(1, int(round(len(losses) ** (1 / 3))))
    # Models whose losses are identical (a flat forecast and a live meter that
    # never moved, on a cap nobody used) make a loss difference with zero
    # variance, and arch's MCS then never finishes: `arena board` hung for
    # hours on such a target. Test one representative per distinct loss column
    # and give its verdict to its copies. Near-constant differences are also
    # nudged apart by a negligible, seeded jitter so no difference has zero
    # variance.
    groups: dict[bytes, list[str]] = {}
    for c in cols:
        groups.setdefault(losses[c].round(12).to_numpy().tobytes(), []).append(c)
    reps_cols = [g[0] for g in groups.values()]
    if len(reps_cols) < 2:
        return cols
    import numpy as np
    x = losses[reps_cols].astype(float)
    scale = float(np.nanmax(np.abs(x.to_numpy()))) or 1.0
    x = x + np.random.default_rng(seed).normal(0.0, 1e-9 * scale, size=x.shape)
    mcs = MCS(x, size=size, reps=reps, block_size=block_size, method="max", seed=seed)
    mcs.compute()
    included = {str(m) for m in mcs.included}
    return [c for g in groups.values() if g[0] in included for c in g]


def mcs_for_target(scores: pl.DataFrame, target: str, metric: str = "crps", *,
                   size: float = 0.10, reps: int = 1000, seed: int = 0) -> list[str]:
    """MCS over per-episode mean losses of one target, using only episodes
    every model scored."""
    d = _whole(scores, metric).filter(pl.col("target") == target)
    per_ep = d.group_by(["model", "run_id", "episode_id"]).agg(pl.col("value").mean())
    wide = per_ep.pivot(on="model", index=["run_id", "episode_id"], values="value").drop_nulls()
    if wide.is_empty():
        return []
    pdf = wide.drop(["run_id", "episode_id"]).to_pandas()
    return model_confidence_set(pdf, size=size, reps=reps, seed=seed)
