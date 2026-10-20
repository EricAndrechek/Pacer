"""Leaderboard over every preds/*.parquet: per window, the headline error
(median on 5h, mean on 7d), coverage when a band is given, the four time
folds, and how many folds beat the shipping rule (rule-current).

  uv run score.py                 # all candidates
  uv run score.py --json out.json # also write the table
  uv run score.py --match timestral
"""
from __future__ import annotations

import argparse
import json

import lab


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json")
    ap.add_argument("--match", default="")
    a = ap.parse_args()
    c = lab.cases()
    names = sorted(p.stem for p in lab.PREDS.glob("*.parquet") if not p.stem.endswith(".choices"))
    names = [n for n in names if a.match in n or n == "rule-current"]
    table = {n: lab.score(n, c) for n in dict.fromkeys(names)}
    base = table.get("rule-current", {})
    for window in lab.WINDOWS:
        b = base.get(window)
        print(f"\n== {window} — headline {'mean' if lab.weekly(window) else 'median'} |shown − final| (pp)")
        rows = sorted(((n, t[window]) for n, t in table.items() if window in t), key=lambda r: r[1]["headline"])
        for n, r in rows:
            wins = sum(1 for x, y in zip(r["folds"], b["folds"]) if x < y) if b and len(r["folds"]) == len(b["folds"]) else "-"
            cov = f"cov {r['coverage80']:.2f}" if "coverage80" in r else "        "
            gain = f"{(1 - r['headline'] / b['headline']) * 100:+5.1f}%" if b else ""
            print(f"  {n:44s} {r['headline']:6.2f} {gain}  {cov}  share {r['share']:.2f}  folds "
                  + " ".join(f"{x:5.2f}" for x in r["folds"]) + f"  beats rule-current {wins}/4")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(table, f, indent=1)


if __name__ == "__main__":
    main()
