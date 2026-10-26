"""`arena board`: one leaderboard per target, primary column CRPS skill."""
from __future__ import annotations

import argparse

import duckdb
import polars as pl

from arena.scoring.aggregate import load_scores, skill
from arena.scoring.compare import mcs_for_target

COLUMNS = ["ae_point", "ae_reset", "next_reading_ae", "brier_hit", "cover80", "pit_tv"]


def leaderboard(scores: pl.DataFrame, target: str, baseline: str | None) -> pl.DataFrame:
    """Rows per model for one target. `skill` is blank without a baseline."""
    d = scores.filter(pl.col("target") == target)
    whole = d.filter(pl.col("lead_s").is_null())
    means = (whole.group_by(["model", "metric"]).agg(pl.col("value").mean())
                  .pivot(on="metric", index="model", values="value"))
    for c in ["crps", *(c for c in COLUMNS if c != "pit_tv")]:
        if c not in means.columns:
            means = means.with_columns(pl.lit(None, pl.Float64).alias(c))
    n = (whole.filter(pl.col("metric") == "crps").group_by("model")
              .agg(pl.len().alias("n")))
    pit = [f"pit_b{b}" for b in range(10)]
    if all(c in means.columns for c in pit):
        # Distance of the mean PIT histogram from flat (0 = calibrated, 0.9 =
        # every truth point in one decile).
        means = means.with_columns(
            (0.5 * pl.sum_horizontal([(pl.col(c) - 0.1).abs() for c in pit])).alias("pit_tv"))
    else:
        means = means.with_columns(pl.lit(None, pl.Float64).alias("pit_tv"))
    out = means.join(n, on="model", how="left")
    if baseline:
        sk = skill(d, baseline, metric="crps").group_by("model").agg(pl.col("skill").mean())
        out = out.join(sk, on="model", how="left")
    else:
        out = out.with_columns(pl.lit(None, pl.Float64).alias("skill"))
    tied = set(mcs_for_target(d, target, "crps"))
    out = out.with_columns(pl.col("model").is_in(list(tied)).alias("tied_best"))
    return out.select(["model", "skill", "crps", *COLUMNS, "n", "tied_best"]).sort(
        "crps", nulls_last=True)


def _fmt(v, digits=3):
    return "-" if v is None or v != v else f"{v:.{digits}f}"


def render(board: pl.DataFrame, target: str, baseline: str | None) -> str:
    head = ["model", "crps skill" + (f" vs {baseline}" if baseline else ""), "crps",
            *COLUMNS, "n", "best (MCS)"]
    rows = [[r["model"], _fmt(r["skill"]), _fmt(r["crps"]),
             *[_fmt(r[c]) for c in COLUMNS], str(r["n"] or 0),
             "tied for best" if r["tied_best"] else ""] for r in board.iter_rows(named=True)]
    w = [max(len(str(x[i])) for x in [head, *rows]) for i in range(len(head))]
    line = lambda r: "  ".join(str(c).ljust(w[i]) for i, c in enumerate(r)).rstrip()
    return "\n".join([f"== {target} ==", line(head), *map(line, rows)])


def run(args: argparse.Namespace) -> int:
    from arena.snapshot import arena_home
    db = args.db or str(arena_home() / "results" / "arena.duckdb")
    con = duckdb.connect(db, read_only=True)
    scores = load_scores(con, run_id=args.run, tier=args.tier, snapshot=args.snapshot)
    if args.target:
        scores = scores.filter(pl.col("target") == args.target)
    if scores.is_empty():
        print("no scores")
        return 0
    # One set of boards per snapshot: synthetic and real data, or two exports,
    # are different questions and never averaged together.
    snaps = sorted(scores["snapshot_id"].unique().to_list())
    for snap in snaps:
        sub = scores.filter(pl.col("snapshot_id") == snap)
        if len(snaps) > 1:
            print(f"######## snapshot {snap}\n")
        for t in sorted(sub["target"].unique().to_list()):
            print(render(leaderboard(sub, t, args.baseline), t, args.baseline), end="\n\n")
    return 0


def register(subparsers) -> None:
    p = subparsers.add_parser("board", help="leaderboards and paired comparisons")
    p.add_argument("--target", help="e.g. meter.five_hour (default: one board per target)")
    p.add_argument("--tier", help="visible | leaderboard | lockbox | synthetic | prospective")
    p.add_argument("--run", help="run id")
    p.add_argument("--snapshot", help="snapshot id (default: one set of boards per snapshot)")
    p.add_argument("--baseline", help="model name the skill column is relative to")
    p.add_argument("--db", help="results database (default: ARENA_HOME/results/arena.duckdb)")
    p.set_defaults(func=run)
