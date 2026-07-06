"""Deterministic parameter sweep over the replay harness — the tuning loop.

Grid-sweeps the EngineParams knobs, replaying the WHOLE store walk-forward for
each configuration (~1s per config), and recommends a change only when the
winner is FOLD-ROBUST — this is the adoption hysteresis, kept out of the app
by design:

  a candidate is recommendable only if, versus the shipping baseline, it
  1. improves the median |end-at-reset error| in ≥ 3 of 4 contiguous
     time folds (not just on average),
  2. improves the overall median by ≥ 5%, and
  3. keeps 80%-band coverage inside [0.70, 0.92].

Winners land in Swift's EngineParams as a reviewed code change; the printed
canonical string / version tag matches what the app will then record into
its prediction snapshots.

Usage:
    uv run sweep.py                       # default grid, both windows
    uv run sweep.py --window seven_day --full
"""

from __future__ import annotations

import argparse
import itertools
import json
from dataclasses import replace

from pacer_replay import (
    CaseScore, Params, load_activity_grid, load_rate_samples, locate_store,
    open_copy, replay_window, summarize,
)

FOLDS = 4

DEFAULT_GRID = {
    "linear_recent_lookback_fraction": [0.2, 0.3, 0.45],
    "recency_half_life_fraction": [0.10, 0.15, 0.25],
    "conformal_min_residuals": [5, 8, 12],
}
FULL_GRID = {
    "linear_recent_lookback_fraction": [0.15, 0.2, 0.3, 0.4, 0.5],
    "recency_half_life_fraction": [0.08, 0.10, 0.15, 0.20, 0.25, 0.35],
    "conformal_min_residuals": [5, 8, 12, 20],
    "rl_stratum_min_scores": [6, 10, 16],
}


def fold_medians(scores: list[CaseScore]) -> list[float | None]:
    """Median |error| per contiguous time fold (by cycle index)."""
    if not scores:
        return [None] * FOLDS
    max_idx = max(s.cycle_index for s in scores) + 1
    out: list[float | None] = []
    for f in range(FOLDS):
        lo, hi = max_idx * f / FOLDS, max_idx * (f + 1) / FOLDS
        errs = sorted(s.abs_error for s in scores if lo <= s.cycle_index < hi)
        n = len(errs)
        out.append(None if n == 0 else (errs[n // 2] if n % 2 else (errs[n // 2 - 1] + errs[n // 2]) / 2))
    return out


def robust_improvement(base_folds, cand_folds, base_med, cand_med, cand_cov) -> bool:
    paired = [(b, c) for b, c in zip(base_folds, cand_folds) if b is not None and c is not None]
    if len(paired) < 3:
        return False
    wins = sum(1 for b, c in paired if c < b)
    if wins < max(3, len(paired) - 1):
        return False
    if base_med is None or cand_med is None or cand_med > base_med * 0.95:
        return False
    return cand_cov is not None and 0.70 <= cand_cov <= 0.92


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--store")
    ap.add_argument("--window", choices=["five_hour", "seven_day"])
    ap.add_argument("--full", action="store_true", help="the larger grid (~360 configs)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    conn = open_copy(locate_store(args.store))
    grid_prior = load_activity_grid(conn)
    windows = [args.window] if args.window else ["five_hour", "seven_day"]
    samples = {w: load_rate_samples(conn, w) for w in windows}

    grid = FULL_GRID if args.full else DEFAULT_GRID
    keys = sorted(grid)
    configs = [Params(), *(
        replace(Params(), **dict(zip(keys, values)))
        for values in itertools.product(*(grid[k] for k in keys))
    )]
    # De-dup (the baseline usually appears in the grid too).
    seen, unique = set(), []
    for p in configs:
        if p.canonical() not in seen:
            seen.add(p.canonical())
            unique.append(p)

    report: dict = {"baseline": Params().version_tag(), "windows": {}}
    for window in windows:
        rows = []
        for i, p in enumerate(unique):
            scores = replay_window(window, samples[window], grid_prior, p)
            s = summarize(scores)
            rows.append({
                "tag": p.version_tag(), "canonical": p.canonical(),
                "median": s.get("medianAbsErrorPP"), "coverage80": s.get("coverage80"),
                "brier": s.get("brier"), "folds": fold_medians(scores),
                "isBaseline": i == 0,
            })
            print(f"\r[{window}] {i + 1}/{len(unique)}", end="", flush=True)
        print()
        base = rows[0]
        recommendable = [r for r in rows[1:] if robust_improvement(
            base["folds"], r["folds"], base["median"], r["median"], r["coverage80"])]
        recommendable.sort(key=lambda r: r["median"])
        report["windows"][window] = {
            "baseline": {k: base[k] for k in ("tag", "median", "coverage80", "brier")},
            "recommend": recommendable[0] if recommendable else None,
            "top5": sorted(rows, key=lambda r: (r["median"] is None, r["median"]))[:5],
        }

    if args.json:
        print(json.dumps(report, indent=2))
        return
    for window, r in report["windows"].items():
        b = r["baseline"]
        print(f"\n[{window}] baseline {b['tag']}: median {b['median']}pp, coverage {b['coverage80']}, brier {b['brier']}")
        if r["recommend"]:
            c = r["recommend"]
            print(f"  RECOMMEND {c['tag']}: median {c['median']}pp, coverage {c['coverage80']} (fold-robust)")
            print(f"    {c['canonical']}")
        else:
            print("  no fold-robust improvement — keep the baseline (this is the hysteresis working)")
        print("  top 5 by median error:")
        for row in r["top5"]:
            mark = "*" if row["isBaseline"] else " "
            print(f"   {mark} {row['tag']}  median={row['median']}  cov={row['coverage80']}  brier={row['brier']}")


if __name__ == "__main__":
    main()
