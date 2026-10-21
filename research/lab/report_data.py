"""Everything the benchmark page shows, as one JSON: every candidate's scores
per window, its family and how much it learns from the user's history, learning
curves by how much history each case had, and the Timestral grid.

  uv run report_data.py > reports/data.json
"""
from __future__ import annotations

import json
import re
import sys

import numpy as np

import lab

FAMILY = [  # (prefix regex, family, fit tier)
    (r"^rule-", "Shipping selection", 2),
    (r"^engine-(recent-rate|linear-recent)$", "Built-in models", 0),
    (r"^engine-diurnal-rate$", "Built-in models", 2),
    (r"^engine-", "Built-in models", 1),
    (r"^tok-nowcast$|^tok-rate-[0-9a-z]+$", "Token / cost models", 0),
    (r"^tok", "Token / cost models", 2),
    (r"^fm-timestral", "Timestral (Mistral)", 1),
    (r"^fm-", "Other foundation models", 1),
    (r"^ml-", "Machine learning", 3),
    (r"^l2-comb-med-all|^l3-median", "Second layer", 0),
    (r"^l2-comb", "Second layer", 2),
    (r"^l2-", "Second layer", 3),
    (r"^afm-", "Apple Foundation Models", 1),
]
TIERS = ["Rule of thumb, nothing learned", "Fits only the current window (or pretrained elsewhere)",
         "Calibrated: a few numbers learned from your history", "Learned: many parameters fit to your history"]


def classify(name: str):
    for pat, fam, tier in FAMILY:
        if re.search(pat, name):
            return fam, tier
    return "Other", 1


def strategy(name: str) -> str:
    """Plain-language description of a second-layer name."""
    m = re.match(r"l2-(sel|comb-med\d|comb-invw\d|comb-med|stack-nnls|stack-gbm|route-gbm|meta-\d+pct)-?(acct|pooled|hier)?-?(all|half|cut)?", name)
    return m.group(0) if m else name


def main() -> None:
    c = lab.cases()
    names = sorted(p.stem for p in lab.PREDS.glob("*.parquet") if not p.stem.endswith(".choices"))
    rows = []
    for n in names:
        fam, tier = classify(n)
        s = lab.score(n, c)
        for w, r in s.items():
            rows.append({"name": n, "family": fam, "tier": tier, "window": w,
                         "headline": r["headline"], "mean": r["mean"], "median": r["median"],
                         "folds": r["folds"], "coverage": r.get("coverage80"), "share": r["share"],
                         "cases": r["cases"]})
    # Learning curves: headline error by how many of the account's cycles had
    # completed before the case (the record a learner could have used).
    curves = {}
    key = ["rule-current", "rule-old", "engine-recent-rate", "tokc-decay-30m", "fm-timestral-28m-6h_3d",
           "l2-comb-med-all-all", "l2-comb-invw5-pooled-all-all", "l2-route-gbm-all", "l2-stack-gbm-all",
           "l2-sel-acct-half-all", "ml-linqr-delta-pooled-acct-stacked-tok-cal", "tokc-rate-1d-cal",
           "l2-comb-invw5-hier-half-engtok", "ml-linqr-frac-pooled-acct-stacked-cal", "l3-median12-7d"]
    edges = {"five_hour": [0, 10, 25, 50, 100, 200, 10_000], "seven_day": [0, 3, 6, 10, 15, 100]}
    for w in lab.WINDOWS:
        g = c[c["window"] == w].copy()
        resets = {a: np.sort(x["resets_at"].unique()) for a, x in g.groupby("account")}
        g["record"] = [int(np.searchsorted(resets[a], t, "right")) for a, t in zip(g["account"], g["t_cut"])]
        e = edges[w]
        g["bucket"] = np.searchsorted(e, g["record"], "right") - 1
        labels = [f"{e[i]}–{e[i + 1] - 1}" if e[i + 1] < 10_000 else f"{e[i]}+" for i in range(len(e) - 1)]
        curves[w] = {"buckets": labels, "counts": [int((g["bucket"] == i).sum()) for i in range(len(labels))], "series": {}}
        for n in key:
            if n not in names:
                continue
            m = g.merge(lab.read_preds(n)[["case_id", "pred"]], on="case_id", how="left").dropna(subset=["pred"])
            if m.empty:
                continue
            err = np.abs(lab.shown(m["pred"].to_numpy(), m["used_now"].to_numpy()) - m["truth"].to_numpy())
            vals = []
            for i in range(len(labels)):
                sel = m["bucket"].to_numpy() == i
                vals.append(lab.headline(err[sel], w) if sel.sum() >= 8 else None)
            curves[w]["series"][n] = vals
    timestral = []
    for r in rows:
        mm = re.match(r"fm-timestral-(\d+m)-(.+)$", r["name"])
        if mm:
            timestral.append({"size": mm.group(1).upper(), "context": mm.group(2), "window": r["window"],
                              "headline": r["headline"], "coverage": r["coverage"]})
    json.dump({"rows": rows, "tiers": TIERS, "curves": curves, "timestral": timestral,
               "cases": {w: int((c["window"] == w).sum()) for w in lab.WINDOWS}}, sys.stdout,
              default=lambda o: None if (isinstance(o, float) and np.isnan(o)) else float(o))


if __name__ == "__main__":
    main()
