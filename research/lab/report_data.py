"""Everything the benchmark page (report_html.py) shows, as one JSON: every
candidate placed in the chain (layer 1 forecasters, layer 2 combiners, layer 3
pickers of pickers, hindsight ceilings), absolute miss metrics per window,
worked examples of real windows through every layer, learning curves and the
Timestral grid.

  uv run report_data.py > reports/data.json && uv run report_html.py
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime

import numpy as np
import pandas as pd

import lab

sys.path.insert(0, str(lab.HERE / "layer3"))
from pickers import POOL  # noqa: E402  the curated layer-1 pool the p2/p3 layers ran on

# Where each candidate sits in the chain: (node id, layer, title, what it does, pattern).
# First match wins, so the specific patterns come first.
NODES = [
    ("ceil-case", "ceiling", "Perfect choice for every window",
     "Hindsight: the closest layer-2 answer in every single case. No real picker can know this in advance.",
     r"^p3-hindsight-case$"),
    ("ceil-acct", "ceiling", "Perfect choice per account",
     "Hindsight: the one layer-2 strategy that would have been best for each account (or account and half).",
     r"^p3-hindsight-(all|acct|acct-half)$"),
    ("p3online", 3, "Hedge / Fixed-Share over combiners",
     "Weights over the layer-2 strategies, updated after every completed window.", r"^p3-(hedge|fs)"),
    ("p3record", 3, "Choose a combiner by record",
     "Use the layer-2 strategy with the best recent record, switching only when another is clearly ahead.",
     r"^p3-(acct|pooled|hier)-|^l2-meta"),
    ("median", 2, "Median, no learning",
     "The middle answer of the forecasters, or a trimmed mean. Nothing is learned.",
     r"^p2-median$|^p2-trim|^l2-comb-med-all-|^l3-median"),
    ("weighted", 2, "Weighted by track record",
     "Trust forecasters with better records more: top-K by error, recency-weighted, or the median plus its usual bias.",
     r"^l2-comb-(invw|med)\d|^p2-ewinvw|^p2-medbias"),
    ("choose", 2, "Choose one by track record",
     "Use the single forecaster with the best record for this account and point in the window. "
     "Pacer's shipping rule is one of these.", r"^l2-sel|^p2-ewsel|^rule-"),
    ("online", 2, "Online experts over forecasters",
     "Hedge and Fixed-Share weights over the forecasters, updated after every completed window.", r"^p2-(hedge|fs)"),
    ("learned", 2, "Learned stacking and routing",
     "A model trained on past cases maps every forecaster's answer (plus context) to the final, "
     "or predicts which one will be closest.", r"^l2-(stack|route)|^p2-shrink|^ml-.*stacked|^ml-ens"),
    ("afm-router", 2, "Apple's on-device LLM as router",
     "Asked which forecaster to trust.", r"^afm-router"),
    ("fit", 1, "Curve fits on the meter",
     "Extend this window's readings: latest pace, a line, a slowing curve, your daily rhythm, a Kalman trend.",
     r"^engine-"),
    ("tok", 1, "Token and cost burn",
     "Price recent token spend at API rates, convert it to meter points, and extend it to the reset.", r"^tokc?-"),
    ("timestral", 1, "Timestral (Mistral, zero-shot)",
     "A pretrained time-series model reads your cumulative usage and forecasts the rest. No training on your data.",
     r"^fm-timestral"),
    ("fm", 1, "Other foundation models",
     "Chronos-2, Chronos-Bolt, Moirai 2, TimesFM 2.5, TiRex and Toto, set up the same way.", r"^fm-"),
    ("ml", 1, "Machine learning on your history",
     "Gradient boosting, linear quantile and nearest-neighbour models trained on your completed windows.",
     r"^ml-"),
    ("afm-forecast", 1, "Apple's on-device LLM as forecaster",
     "Asked for the final reading directly.", r"^afm-forecast"),
]
LIVE = {  # what runs in the installed Pacer
    "five_hour": {"tokc-decay-30m": "lab", "tokc-rate-30m-cal": "lab", "fm-timestral-5m-6h_3d": "lab",
                  "fm-timestral-28m-6h_3d": "lab", "fm-timestral-123m-6h_3d": "lab",
                  "fm-timestral-209m-1d_1w": "lab", "l3-median6-5h": "lab", "rule-current": "shipping"},
    "seven_day": {"tokc-rate-1d-cal": "lab", "l3-median12-7d": "lab", "rule-current": "shipping"},
}
ANCHORS = {  # always on the featured board, beside the best of every node
    "five_hour": ["engine-recent-rate", "engine-linear-recent", "engine-saturating", "engine-kalman-trend",
                  "engine-diurnal-rate", "tok-rate-30m", "tokc-decay-30m", "tokc-rate-30m-cal",
                  "fm-timestral-5m-6h_3d", "fm-timestral-28m-6h_3d", "fm-timestral-123m-6h_3d",
                  "fm-timestral-209m-1d_1w", "fm-toto-151m-2d_2w", "fm-chronos2-1d_1w", "fm-moirai2-small-1d_1w",
                  "ml-lgbm-delta-pooled-tok-cal", "ml-knn-delta-pooled-tok-cal",
                  "l3-median6-5h", "p2-median", "l2-comb-med-all-all", "p2-trim2", "p2-ewinvw5-30-pooled",
                  "p2-medbias-acct", "l2-sel-acct-half-all", "rule-current", "rule-old", "p2-shrink50-pooled",
                  "l2-stack-gbm-all", "l2-route-gbm-all", "p2-hedge-avg-e0.3-hier",
                  "p3-hedge-pick-e1-pooled", "p3-hedge-avg-e1-pooled", "p3-fs10-pick-e1-acct",
                  "p3-pooled-last25-m5", "l2-meta-5pct-all",
                  "p3-hindsight-acct", "p3-hindsight-acct-half", "p3-hindsight-case"],
    "seven_day": ["engine-recent-rate", "engine-linear-recent", "engine-saturating", "engine-diurnal-rate",
                  "engine-kalman-trend", "tok-rate-1d", "tokc-rate-1d-cal", "tokc-decay-1d",
                  "fm-timestral-5m-1w_4w", "fm-timestral-28m-1w_4w", "fm-timestral-209m-1w_4w",
                  "fm-toto-151m-1w_4w", "fm-chronos2-1w_4w", "ml-lgbm-frac-pooled-tok-cal",
                  "l3-median12-7d", "p2-median", "p2-medbias-acct", "l2-comb-med-all-all", "p2-ewinvw5-30-pooled",
                  "l2-sel-acct-half-all", "rule-current", "rule-old", "ml-linqr-frac-pooled-acct-stacked-cal",
                  "l2-stack-gbm-all", "l2-route-gbm-all", "p2-hedge-avg-e0.3-hier",
                  "p3-fs10-avg-e0.3-acct", "p3-pooled-hl30-m0", "p3-hedge-pick-e1-pooled", "l2-meta-5pct-all",
                  "p3-hindsight-acct", "p3-hindsight-acct-half", "p3-hindsight-case"],
}
TIERS = ["Nothing learned", "Fits only this window, or pretrained elsewhere",
         "A few numbers learned from your history", "Many parameters fit to your history"]

ENGINE = {"recent-rate": "Latest pace, held", "linear-recent": "Straight line, recent readings",
          "recency-weighted": "Recency-weighted line", "saturating": "Slowing toward a ceiling",
          "diurnal-rate": "Your daily rhythm", "damped-acceleration": "Damped acceleration",
          "kalman-trend": "Kalman trend"}
FM = {"timestral-5m": "Timestral 5M", "timestral-28m": "Timestral 28M", "timestral-123m": "Timestral 123M",
      "timestral-209m": "Timestral 209M", "toto-151m": "Toto 151M", "timesfm25-200m": "TimesFM 2.5 200M",
      "tirex-35m": "TiRex 35M", "chronos2": "Chronos-2", "moirai2-small": "Moirai 2 small",
      "chronos-bolt-base": "Chronos-Bolt base", "chronos-bolt-small": "Chronos-Bolt small",
      "chronos-bolt-mini": "Chronos-Bolt mini", "chronos-bolt-tiny": "Chronos-Bolt tiny"}
SPAN = {"30m": "30 min", "1h": "1 h", "2h": "2 h", "6h": "6 h", "12h": "12 h", "1d": "1 day", "2d": "2 days",
        "3d": "3 days", "1w": "1 week", "2w": "2 weeks", "4w": "4 weeks"}
SCOPE = {"acct": "per account", "pooled": "all accounts pooled", "hier": "per account once it has 10 windows",
         "joint": "joint"}
GRAN = {"half": "per half of the window", "cut": "per checkpoint"}


def label(name: str, window: str) -> str:
    """A readable name for any candidate."""
    if name == "rule-current":
        return "Pacer's shipping rule"
    if name == "rule-old":
        return "Shipping rule before #305"
    if name.startswith("engine-"):
        return ENGINE.get(name[7:], name)
    if m := re.match(r"^fm-(.+)-(\d+[hdw])_(\d+[hdw])$", name):
        ctx = m.group(2) if window == "five_hour" else m.group(3)
        return f"{FM.get(m.group(1), m.group(1))} · {SPAN.get(ctx, ctx)} of context"
    if name == "tok-nowcast":
        return "Token nowcast"
    if m := re.match(r"^(tokc?)-(rate|decay)-(\w+?)(-cal)?$", name):
        what = "Cost burn" if m.group(1) == "tokc" else "Token burn"
        how = "held" if m.group(2) == "rate" else "fading"
        return f"{what}, last {SPAN.get(m.group(3), m.group(3))}, {how}" + (", recalibrated daily" if m.group(4) else "")
    if m := re.match(r"^ml-(lgbm|linqr|knn)-(delta|frac|truth)-(.+)$", name):
        algo = {"lgbm": "LightGBM", "linqr": "Linear quantile", "knn": "Nearest neighbours"}[m.group(1)]
        target = {"delta": "remaining burn", "frac": "share of headroom", "truth": "the final reading"}[m.group(2)]
        flags = m.group(3).split("-")
        bits = [SCOPE.get(f) for f in flags if f in SCOPE]
        if "stacked" in flags:
            bits.append("+ forecasters' answers")
        if "tok" in flags:
            bits.append("+ token features")
        if "cal" in flags:
            bits.append("calibrated")
        return f"{algo} on {target}" + (" · " + ", ".join(dict.fromkeys(b for b in bits if b)) if bits else "")
    if name.startswith("ml-ens-"):
        return "ML ensemble · " + name[7:].replace("-", " ")
    if m := re.match(r"^l3-median(\d+)", name):
        return f"Median of {m.group(1)} lab models" if m.group(1) == "6" else f"Median of {m.group(1)} models"
    if name.startswith("l2-"):
        t = name[3:].split("-")
        if t[:3] == ["comb", "med", "all"]:
            return {"all": "Median of every candidate", "engine": "Median of the built-in models",
                    "engtok": "Median of the built-in and token models"}.get(t[3], "Median of every candidate")
        kind, rest = (t[0] + "-" + t[1], t[2:]) if t[0] in ("comb", "stack", "route") else (t[0], t[1:])
        if m := re.match(r"comb-med(\d+)", kind):
            head = f"Median of the top {m.group(1)} by record"
        elif m := re.match(r"comb-invw(\d+)", kind):
            head = f"Top {m.group(1)} by record, weighted"
        elif kind == "sel":
            head = "Best one by record"
        elif kind == "stack-nnls":
            head = "Learned blend weights (NNLS)"
        elif kind == "stack-gbm":
            head = "Learned stacker (LightGBM)"
        elif kind == "route-gbm":
            head = "Learned router (LightGBM)"
        elif kind == "meta":
            return f"Picker of pickers by record, {rest[0].replace('pct', '')}% margin"
        else:
            head = kind
        bits = [SCOPE.get(x) or GRAN.get(x) for x in rest]
        if rest and rest[-1] not in ("all", "half", "cut") and rest[-1] not in SCOPE:
            bits.append({"engtok": "built-in + token models", "eng": "built-in only",
                         "engine": "built-in only"}.get(rest[-1], rest[-1]))
        return head + (" · " + ", ".join(b for b in bits if b) if any(bits) else "")
    if name.startswith("p2-") or name.startswith("p3-"):
        layer, t = name[:2], name[3:]
        if t == "median":
            return "Median of the 20 curated forecasters"
        if m := re.match(r"trim(\d)", t):
            return f"Trimmed mean, dropping the {m.group(1)} highest and lowest"
        if m := re.match(r"medbias-(\w+)", t):
            return f"Median + its usual bias · {SCOPE[m.group(1)]}"
        if m := re.match(r"ewinvw5-(\d+)-(\w+)", t):
            return f"Top 5, recency-weighted (half-life {m.group(1)} windows) · {SCOPE[m.group(2)]}"
        if m := re.match(r"ewsel-(\d+)-(\w+)", t):
            return f"Best one, recency-weighted (half-life {m.group(1)} windows) · {SCOPE[m.group(2)]}"
        if m := re.match(r"shrink(\d+)-(\w+)", t):
            return f"Learned blend, shrunk {m.group(1)}% toward equal weights · {SCOPE[m.group(2)]}"
        if m := re.match(r"hindsight-(.+)", t):
            return {"all": "Perfect single strategy for everyone (hindsight)",
                    "acct": "Perfect strategy per account (hindsight)",
                    "acct-half": "Perfect strategy per account and half (hindsight)",
                    "case": "Perfect choice for every window (hindsight)"}[m.group(1)]
        if m := re.match(r"(hedge|fs(\d+))-(avg|pick)-e([\d.]+)-(\w+)", t):
            algo = "Hedge" if m.group(1) == "hedge" else f"Fixed-Share {m.group(2)}%"
            what = "blend" if m.group(3) == "avg" else "pick"
            over = "combiners" if layer == "p3" else "forecasters"
            return f"{algo} {what} over {over} (η {m.group(4)}) · {SCOPE[m.group(5)]}"
        if m := re.match(r"(acct|pooled|hier)-(all|last\d+|hl\d+)-m(\d+)", t):
            look = {"all": "whole record"}.get(m.group(2)) or (
                f"last {m.group(2)[4:]} windows" if m.group(2).startswith("last") else f"half-life {m.group(2)[2:]} windows")
            return f"Choose a combiner by record ({look}, {m.group(3)}% margin) · {SCOPE[m.group(1)]}"
    if name == "afm-router":
        return "Apple on-device LLM as router"
    if name == "afm-forecast":
        return "Apple on-device LLM as forecaster"
    return name


def tier(name: str):
    if name.startswith("p3-hindsight"):
        return None
    if re.match(r"^(engine-(recent-rate|linear-recent)|tok-nowcast|tok-rate-\w+|p2-median|p2-trim\d|"
                r"l2-comb-med-all-\w+|l3-median.*)$", name):
        return 0
    if re.match(r"^(engine-|fm-|afm-)", name):
        return 1
    if re.match(r"^(ml-|l2-stack|l2-route|p2-shrink)", name):
        return 3
    return 2


def node_of(name: str):
    for nid, layer, *_rest, pat in NODES:
        if re.search(pat, name):
            return nid, layer
    return None, None


def ensure_live_median() -> None:
    """The live 5-hour ensemble (lab_ensemble_5h) as a lab prediction, so it
    sits on the board beside the rest."""
    c = lab.cases()
    g = c[c["window"] == "five_hour"][["case_id", "used_now"]].copy()
    six = ["tokc-decay-30m", "tokc-rate-30m-cal", "fm-timestral-5m-6h_3d", "fm-timestral-28m-6h_3d",
           "fm-timestral-123m-6h_3d", "fm-timestral-209m-1d_1w"]
    for n in six:
        g = g.merge(lab.read_preds(n)[["case_id", "pred"]].rename(columns={"pred": n}), on="case_id", how="left")
    V = np.clip(g[six].to_numpy(), g["used_now"].to_numpy()[:, None], 100)
    lab.write_preds("l3-median6-5h", pd.DataFrame({"case_id": g["case_id"], "pred": np.nanmedian(V, axis=1)}))


def metrics(err: np.ndarray, cut: np.ndarray, fold: np.ndarray, window: str, total: int) -> dict:
    def h(sel):
        return float(lab.headline(err[sel], window)) if sel.sum() >= 4 else None
    folds = [h(fold == f) for f in range(4)]
    return {"typical": h(np.ones(len(err), bool)), "mean": float(err.mean()), "p90": float(np.quantile(err, 0.9)),
            "big": float((err > 5).mean() * 100), "early": h(cut < 0.5), "late": h(cut >= 0.5),
            "worst": max(folds) if all(f is not None for f in folds) else None,
            "folds": folds if all(f is not None for f in folds) else None,
            "cases": int(len(err)), "share": len(err) / total}


def main() -> None:
    ensure_live_median()
    c = lab.cases()
    names = sorted(p.stem for p in lab.PREDS.glob("*.parquet")
                   if not p.stem.endswith(".choices") and p.stem != "p3-oracle")
    totals = {w: int((c["window"] == w).sum()) for w in lab.WINDOWS}
    cands = []
    for n in names:
        nid, layer = node_of(n)
        if nid is None:
            print(f"unplaced: {n}", file=sys.stderr)
            continue
        p = lab.read_preds(n)[["case_id", "pred"]]
        m = c.merge(p, on="case_id").dropna(subset=["pred"])
        entry = {"name": n, "node": nid, "layer": layer, "tier": tier(n), "m": {}, "label": {}, "live": {}}
        for w, g in m.groupby("window"):
            err = np.abs(lab.shown(g["pred"].to_numpy(), g["used_now"].to_numpy()) - g["truth"].to_numpy())
            entry["m"][w] = metrics(err, g["cut"].to_numpy(), g["fold"].to_numpy(), w, totals[w])
            entry["label"][w] = label(n, w)
            entry["live"][w] = LIVE[w].get(n) or ("built-in" if n.startswith("engine-") else None)
        if entry["m"]:
            cands.append(entry)
    by = {e["name"]: e for e in cands}

    featured = {}
    for w in lab.WINDOWS:
        ok = [e for e in cands if w in e["m"] and e["m"][w]["share"] >= 0.9]
        pick = [n for n in ANCHORS[w] if n in by and w in by[n]["m"]]
        for nid, *_ in NODES:
            members = sorted((e for e in ok if e["node"] == nid), key=lambda e: e["m"][w]["typical"])
            pick += [e["name"] for e in members[:2]]
        featured[w] = list(dict.fromkeys(pick))

    # Worked examples: real windows, every layer's answer beside the truth.
    picks = json.loads((lab.HERE / "reports" / "picks.json").read_text())
    examples = {}
    order = c.sort_values(["t_cut", "case_id"])
    for w in lab.WINDOWS:
        g = order[order["window"] == w].reset_index(drop=True)
        ch = picks[w]["choices"]["hedge-pick-e1-pooled"]
        assert len(ch) == len(g)
        g["hedge_choice"] = ch
        pool = [n for n in POOL[w] if n in by]
        best_single = "tokc-decay-30m" if w == "five_hour" else "tokc-rate-1d-cal"
        live_med = "l3-median6-5h" if w == "five_hour" else "l3-median12-7d"
        l2 = {"median": "p2-median", "trim2": "p2-trim2", "medbias-hier": "p2-medbias-hier",
              "ewinvw5-30-hier": "p2-ewinvw5-30-hier", "ewsel-30-hier": "p2-ewsel-30-hier",
              "shrink50-pooled": "p2-shrink50-pooled", "rule-current": "rule-current", best_single: best_single}
        cols = list(dict.fromkeys(pool + list(l2.values()) + [live_med, "p3-hedge-pick-e1-pooled"]))
        for n in cols:
            g = g.merge(lab.read_preds(n)[["case_id", "pred"]].rename(columns={"pred": n}), on="case_id", how="left")
            g[n] = lab.shown(g[n].to_numpy(), g["used_now"].to_numpy())
        P = g[pool].to_numpy()
        complete = ~np.isnan(P).any(axis=1) & ~g[cols].isna().any(axis=1).to_numpy()
        valid = complete & (g["fold"].to_numpy() >= 2)          # late enough that the learners had a record
        truth = g["truth"].to_numpy()
        spread = np.nanpercentile(P, 75, axis=1) - np.nanpercentile(P, 25, axis=1)
        med_err = np.abs(g["p2-median"].to_numpy() - truth)
        min_err = np.nanmin(np.abs(P - truth[:, None]), axis=1)
        hi_spread = spread >= np.nanquantile(spread[valid], 0.8)
        mid_spread = np.abs(spread - np.nanmedian(spread[valid])) <= np.nanstd(spread[valid]) * 0.25
        kinds = [
            ("The forecasters disagree, and the median lands close", valid & hi_spread & (med_err <= 1.5)),
            ("A typical window", valid & mid_spread & (med_err <= 3)),
            # By the later quarters Hedge picks the median every time, so this one
            # comes from earlier history.
            ("The picker of pickers chose something other than the median",
             complete & (g["hedge_choice"].to_numpy() != "median")),
            ("The median is wrong, but one forecaster had it", valid & (med_err >= 5) & (min_err <= 1)),
            ("Nobody saw it coming", valid & (truth - np.nanmax(P, axis=1) >= 8)),
        ]
        out, used_cuts, used_windows = [], set(), set()
        for title, sel in kinds:
            idx = [j for j in np.where(sel)[0][::-1]           # most recent first, one per window
                   if (g.at[j, "account"], g.at[j, "resets_at"]) not in used_windows]
            if not idx:
                continue
            i = next((j for j in idx if g.at[j, "cut"] not in used_cuts), idx[0])
            used_cuts.add(g.at[i, "cut"])
            used_windows.add((g.at[i, "account"], g.at[i, "resets_at"]))
            r = g.loc[i]
            out.append({
                "title": title,
                "start": datetime.fromtimestamp(r["cycle_start"]).strftime("%a %-d %b, %-I:%M %p"),
                "cut": float(r["cut"]), "elapsed_h": float(r["t_cut"] - r["cycle_start"]) / 3600,
                "used": float(r["used_now"]), "truth": float(r["truth"]),
                "layer1": [{"name": n, "label": by[n]["label"][w], "node": by[n]["node"], "value": float(r[n])}
                           for n in pool],
                "layer2": [{"name": n, "key": k, "label": by[n]["label"][w], "value": float(r[n])}
                           for k, n in l2.items()]
                          + [{"name": live_med, "key": "live", "label": by[live_med]["label"][w],
                              "value": float(r[live_med])}],
                "layer3": {"name": "p3-hedge-pick-e1-pooled", "label": by["p3-hedge-pick-e1-pooled"]["label"][w],
                           "choice": by[l2[r["hedge_choice"]]]["label"][w], "value": float(r["p3-hedge-pick-e1-pooled"])},
            })
        examples[w] = out

    # Learning curves: typical miss by how many of the account's windows had
    # completed before the case (the record a learner could have used).
    curves = {}
    keys = ["rule-current", "tokc-decay-30m", "fm-timestral-28m-6h_3d", "p2-median", "l2-route-gbm-all",
            "p3-hedge-pick-e1-pooled", "tokc-rate-1d-cal", "l3-median12-7d"]
    edges = {"five_hour": [0, 10, 25, 50, 100, 200, 10_000], "seven_day": [0, 3, 6, 10, 15, 100]}
    for w in lab.WINDOWS:
        g = c[c["window"] == w].copy()
        resets = {a: np.sort(x["resets_at"].unique()) for a, x in g.groupby("account")}
        g["record"] = [int(np.searchsorted(resets[a], t, "right")) for a, t in zip(g["account"], g["t_cut"])]
        e = edges[w]
        g["bucket"] = np.searchsorted(e, g["record"], "right") - 1
        labels = [f"{e[i]}–{e[i + 1] - 1}" if e[i + 1] < 10_000 else f"{e[i]}+" for i in range(len(e) - 1)]
        curves[w] = {"buckets": labels, "counts": [int((g["bucket"] == i).sum()) for i in range(len(labels))],
                     "series": {}}
        for n in keys:
            if n not in by or w not in by[n]["m"]:
                continue
            m = g.merge(lab.read_preds(n)[["case_id", "pred"]], on="case_id").dropna(subset=["pred"])
            err = np.abs(lab.shown(m["pred"].to_numpy(), m["used_now"].to_numpy()) - m["truth"].to_numpy())
            curves[w]["series"][n] = [float(lab.headline(err[m["bucket"].to_numpy() == i], w))
                                      if (m["bucket"].to_numpy() == i).sum() >= 8 else None
                                      for i in range(len(labels))]
    timestral = []
    for e in cands:
        if mm := re.match(r"fm-timestral-(\d+m)-(.+)$", e["name"]):
            for w, m in e["m"].items():
                timestral.append({"size": mm.group(1).upper(), "context": mm.group(2), "window": w,
                                  "typical": m["typical"]})
    json.dump({"nodes": [{"id": n[0], "layer": n[1], "title": n[2], "desc": n[3]} for n in NODES],
               "candidates": cands, "featured": featured, "examples": examples, "tiers": TIERS,
               "curves": curves, "timestral": timestral, "cases": totals,
               "built": datetime.now().strftime("%-d %b %Y, %-I:%M %p")}, sys.stdout)


if __name__ == "__main__":
    main()
