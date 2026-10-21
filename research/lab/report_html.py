"""Build reports/benchmark.html from reports/data.json (report_data.py).

  uv run report_data.py > reports/data.json && uv run report_html.py
"""
from __future__ import annotations

import json
import re

import numpy as np
import pandas as pd

import lab

OUT = lab.HERE / "reports" / "benchmark.html"

PINNED = {
    "five_hour": ["rule-old", "rule-current", "engine-recent-rate", "engine-saturating", "engine-diurnal-rate",
                  "tok-rate-30m", "tok-rate-30m-cal", "tokc-decay-30m", "fm-timestral-5m-6h_3d",
                  "fm-timestral-28m-6h_3d", "fm-timestral-123m-6h_3d", "fm-timestral-209m-1d_1w",
                  "fm-toto-151m-2d_2w", "fm-timesfm25-200m-2d_2w", "fm-tirex-35m-1d_1w",
                  "ml-linqr-delta-pooled-acct-stacked-tok-cal", "ml-lgbm-delta-pooled-acct-stacked-tok-cal",
                  "l2-sel-acct-half-all", "l2-meta-5pct-all", "l2-route-gbm-all", "l2-stack-gbm-all",
                  "l2-stack-nnls-pooled-all-all", "l2-comb-invw5-pooled-all-all", "l2-comb-med-all-all",
                  "l3-median6-5h", "p2-ewinvw5-30-pooled", "p3-pooled-last25-m5", "p3-hedge-pick-e1-pooled",
                  "afm-router", "afm-forecast"],
    "seven_day": ["rule-old", "rule-current", "engine-recent-rate", "engine-diurnal-rate", "engine-saturating",
                  "tok-rate-1d", "tok-rate-1d-cal", "tokc-rate-1d-cal", "fm-timestral-5m-1w_4w",
                  "fm-timestral-28m-1w_4w", "fm-timestral-209m-1w_4w", "fm-chronos2-1w_4w",
                  "ml-linqr-frac-pooled-acct-stacked-cal", "ml-lgbm-frac-pooled-tok-cal",
                  "l2-sel-acct-half-all", "l2-meta-5pct-all", "l2-route-gbm-all", "l2-stack-gbm-all",
                  "l2-comb-invw5-hier-half-engtok", "l2-comb-med-all-all", "l3-median12-7d", "p2-medbias-acct",
                  "p3-pooled-hl30-m0", "p3-hedge-pick-e1-pooled", "afm-router",
                  "afm-forecast"],
}
LABELS = {
    "rule-old": "Shipping rule before #305", "rule-current": "Shipping rule (PR #311)",
    "engine-recent-rate": "Latest pace, held", "engine-saturating": "Slowing toward a ceiling",
    "engine-diurnal-rate": "Your daily rhythm", "tok-rate-30m": "Token burn, 30 min, raw",
    "tok-rate-30m-cal": "Token burn, 30 min, calibrated", "tokc-decay-30m": "Cost burn, 30 min, fading",
    "tok-rate-1d": "Token burn, 1 day, raw", "tok-rate-1d-cal": "Token burn, 1 day, calibrated",
    "tokc-rate-1d-cal": "Cost burn, 1 day, calibrated",
    "fm-timestral-5m-6h_3d": "Timestral 5M (6 h)", "fm-timestral-28m-6h_3d": "Timestral 28M (6 h)",
    "fm-timestral-123m-6h_3d": "Timestral 123M (6 h)", "fm-timestral-209m-1d_1w": "Timestral 209M (1 d)",
    "fm-timestral-5m-1w_4w": "Timestral 5M (4 wk)", "fm-timestral-28m-1w_4w": "Timestral 28M (4 wk)",
    "fm-timestral-209m-1w_4w": "Timestral 209M (4 wk)", "fm-toto-151m-2d_2w": "Toto 151M",
    "fm-timesfm25-200m-2d_2w": "TimesFM 2.5 200M", "fm-tirex-35m-1d_1w": "TiRex 35M",
    "fm-chronos2-1w_4w": "Chronos-2",
    "ml-linqr-delta-pooled-acct-stacked-tok-cal": "Linear quantile, stacked + tokens",
    "ml-lgbm-delta-pooled-acct-stacked-tok-cal": "LightGBM, stacked + tokens",
    "ml-linqr-frac-pooled-acct-stacked-cal": "Linear quantile on headroom, stacked",
    "ml-lgbm-frac-pooled-tok-cal": "LightGBM on headroom + tokens",
    "l2-sel-acct-half-all": "Pick best by record (per account, per half)",
    "l2-meta-5pct-all": "Rule-picker over strategies (5% margin)",
    "l2-route-gbm-all": "Learned router (LightGBM)", "l2-stack-gbm-all": "Learned stacker (LightGBM)",
    "l2-stack-nnls-pooled-all-all": "Learned blend weights (NNLS)",
    "l2-comb-invw5-pooled-all-all": "Top 5 by record, weighted",
    "l2-comb-invw5-hier-half-engtok": "Top 5 by record, weighted (engine + tokens)",
    "l2-comb-med-all-all": "Median of all candidates", "l3-median6-5h": "Median of the 6 lab models (live)",
    "l3-median12-7d": "Median of 12 (live)", "afm-router": "Apple FM as router (300-case sample)",
    "afm-forecast": "Apple FM as forecaster (sample)",
    "p2-median": "Median of 20 curated models", "p2-ewinvw5-30-pooled": "Top 5, recency-weighted",
    "p2-medbias-acct": "Median + learned bias (per account)",
    "p3-pooled-last25-m5": "Picker of pickers, by last 25 windows",
    "p3-pooled-hl30-m0": "Picker of pickers, recency-weighted",
    "p3-hedge-pick-e1-pooled": "Picker of pickers (Hedge)",
    "p3-fs10-pick-e1-acct": "Picker of pickers (Fixed-Share)",
}
STRATEGY_LABELS = {
    "median": "Median of all", "trim2": "Trimmed mean", "medbias-hier": "Median + learned bias",
    "ewinvw5-30-hier": "Top 5, recency-weighted", "ewsel-30-hier": "Best one, recency-weighted",
    "shrink50-pooled": "Learned blend, shrunk", "rule-current": "Shipping rule",
    "tokc-decay-30m": "Best single model", "tokc-rate-1d-cal": "Best single model",
}


def main() -> None:
    d = json.loads((lab.HERE / "reports" / "data.json").read_text())
    c = lab.cases()
    # The live 5-hour ensemble, as a lab prediction, so it sits on the board.
    g = c[c["window"] == "five_hour"][["case_id", "used_now"]].copy()
    six = ["tokc-decay-30m", "tokc-rate-30m-cal", "fm-timestral-5m-6h_3d", "fm-timestral-28m-6h_3d",
           "fm-timestral-123m-6h_3d", "fm-timestral-209m-1d_1w"]
    for n in six:
        g = g.merge(lab.read_preds(n)[["case_id", "pred"]].rename(columns={"pred": n}), on="case_id", how="left")
    V = np.clip(g[six].to_numpy(), g["used_now"].to_numpy()[:, None], 100)
    lab.write_preds("l3-median6-5h", pd.DataFrame({"case_id": g["case_id"], "pred": np.nanmedian(V, axis=1)}))
    r = lab.score("l3-median6-5h", c)["five_hour"]
    d["rows"].append({"name": "l3-median6-5h", "family": "Second layer", "tier": 0, "window": "five_hour",
                      "headline": r["headline"], "mean": r["mean"], "median": r["median"], "folds": r["folds"],
                      "coverage": None, "share": r["share"], "cases": r["cases"]})
    by = {(x["name"], x["window"]): x for x in d["rows"]}
    featured = {}
    for w, names in PINNED.items():
        featured[w] = [dict(by[(n, w)], label=LABELS.get(n, n)) for n in names if (n, w) in by]
    d["featured"] = featured
    # What the picker of pickers chose, per quarter of history.
    pk = json.loads((lab.HERE / "reports" / "picks.json").read_text())
    d["picks"] = {}
    for w, v in pk.items():
        strategies = v["strategies"]
        d["picks"][w] = {"strategies": [STRATEGY_LABELS.get(x, x) for x in strategies], "variants": {}}
        for variant in ("hedge-pick-e1-pooled", "fs10-pick-e1-acct"):
            ch, fold = v["choices"][variant], v["fold"]
            d["picks"][w]["variants"][variant] = [
                [sum(1 for c, f in zip(ch, fold) if f == q and c == x) / max(1, sum(1 for f in fold if f == q))
                 for x in strategies] for q in range(4)]
    d["labels"] = LABELS
    html = TEMPLATE.replace("/*DATA*/", json.dumps(d, default=lambda o: None))
    OUT.write_text(html)
    print(OUT)


TEMPLATE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pacer Prediction Lab</title>
<style>
:root{--surface:#fcfcfb;--page:#f9f9f7;--ink:#0b0b0b;--ink2:#52514e;--muted:#898781;--grid:#e1e0d9;--axis:#c3c2b7;
--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--s4:#eda100;--s5:#e87ba4;--s6:#008300;--s7:#6250d6;--s8:#e34948;--ref:#52514e;--good:#006300;--bad:#d03b3b;
font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;color-scheme:light}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--surface:#1a1a19;--page:#0d0d0d;--ink:#f0efec;--ink2:#c3c2b7;--muted:#898781;--grid:#2c2c2a;--axis:#383835;
--s1:#3987e5;--s2:#d95926;--s3:#199e70;--s4:#c98500;--s5:#d55181;--s6:#008300;--s7:#9085e9;--s8:#e66767;--ref:#c3c2b7;--good:#0ca30c;color-scheme:dark}}
body{margin:0;background:var(--page);color:var(--ink)}
main{max-width:1100px;margin:0 auto;padding:32px max(16px,env(safe-area-inset-left)) 80px}
h1{font-size:28px;margin:0 0 4px;letter-spacing:-.01em}h2{font-size:20px;margin:44px 0 8px}h3{font-size:15px;margin:20px 0 6px}
p{max-width:75ch;margin:6px 0}.meta{color:var(--muted);font-size:13px}
.card{background:var(--surface);border:1px solid var(--grid);border-radius:10px;padding:16px 18px;margin:12px 0}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;margin:18px 0}
.tile{background:var(--surface);border:1px solid var(--grid);border-radius:10px;padding:14px 16px}
.tile .k{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}.tile .v{font-size:30px;font-weight:600;font-variant-numeric:tabular-nums}
.tile .s{font-size:13px;color:var(--ink2)}.good{color:var(--good)}
.tabs{display:flex;gap:6px;margin:10px 0}.tabs button{font:inherit;font-size:13px;padding:5px 12px;border-radius:999px;border:1px solid var(--axis);background:transparent;color:var(--ink2);cursor:pointer}
.tabs button[aria-pressed=true]{background:var(--ink);color:var(--surface);border-color:var(--ink)}
.legend{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:13px;color:var(--ink2);margin:6px 0 2px}.legend i{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:-1px}
svg{display:block;width:100%;height:auto;overflow:visible}svg text{fill:var(--ink2);font-size:12px}svg .muted{fill:var(--muted)}
table{border-collapse:collapse;width:100%;font-size:13px;font-variant-numeric:tabular-nums}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--grid)}
th{color:var(--muted);font-weight:500;cursor:pointer;white-space:nowrap}td.n{text-align:right}th.n{text-align:right}
.tablewrap{overflow-x:auto}#tip{position:fixed;pointer-events:none;background:var(--ink);color:var(--surface);font-size:12px;padding:6px 8px;border-radius:6px;max-width:320px;display:none;z-index:9}
input[type=search]{font:inherit;font-size:13px;padding:5px 10px;border:1px solid var(--axis);border-radius:8px;background:var(--surface);color:var(--ink);width:min(320px,100%)}
ul{padding-left:20px}li{margin:4px 0;max-width:75ch}code{font-size:12px}
</style></head><body><main>
<h1>Pacer Prediction Lab</h1>
<p class="meta">Overnight 20–21 Oct 2026 · branch exp/prediction-lab · every candidate replayed walk-forward over your full history (live readings + archive)</p>

<div class="tiles" id="tiles"></div>

<div class="card"><h3 style="margin-top:0">How to read the numbers</h3>
<ul>
<li><b>Cases:</b> every completed window in your history, seen at 8 checkpoints (20%, 30% … 90% of the way through). <span id="ncases"></span> Every model sees all of them, except Apple's model, which ran on a sample.</li>
<li><b>Walk-forward:</b> each prediction uses only data that existed at that moment, and every learner retrains only on windows that had already ended. No model ever sees the answer.</li>
<li><b>Typical miss:</b> how far the shown value at reset landed from the real final reading, in percentage points of the meter. It's the median on 5-hour windows and the mean on 7-day ones (most weekly windows end at the cap, so their median is ~0 for everyone). Lower is better.</li>
<li><b>Periods won (e.g. 4/4):</b> your history split into four consecutive quarters (~980 five-hour cases each); a model "wins" a quarter if its typical miss there beats the shipping rule's. 4/4 means it was better in every stretch of time, not just on average.</li>
</ul></div>

<h2>Leaderboard</h2>
<p>Named contenders from every family. Each dot is a model's typical miss on the same cases, best at the top, and the dashed line is the shipping rule. "4/4" means it beat the rule in all four quarters of your history. Hover a row for details; the full table of every candidate is at the bottom.</p>
<div class="tabs" id="lbtabs"></div><div class="legend" id="lblegend"></div><div class="card"><div id="lb"></div></div>

<h2>Learning less held up better</h2>
<p>Every candidate (dots), grouped by how much it learns from your history. The plain median of other models learns nothing at all and is the best performer on both windows. Heavier learners (routers, stackers, gradient boosting) fit your past closely and generalized worse to the next stretch of time. The one fragile exception is a weekly linear model, the best of ~170 tries and only 2/4 periods.</p>
<div class="tabs" id="fstabs"></div><div class="card"><div id="fs"></div></div>

<h2>Do they get better with more history?</h2>
<p>Five-hour typical miss by how many of the account's windows had already completed (the record a learner could use). The learned layers start poor and improve (the router goes from 4.7 to 3.0), but none overtakes the median, which needs no history. The picker of pickers improves until it is effectively the median. Timestral is strongest when history is thin, since it was pretrained elsewhere. Buckets mix accounts and periods, so read the shapes, not single points; the 7-day version is too noisy to show.</p>
<div class="legend" id="lclegend"></div><div class="card"><div id="lc"></div></div>

<h2>Timestral: size barely matters, context does</h2>
<p>Mistral's zero-shot model at every size, by how much recent history it reads. On 5-hour windows the shortest context wins and 5M is within ~0.3 pp of 209M. On 7-day windows nothing beats the shipping rule (8.18).</p>
<div class="card tablewrap" id="ts"></div>

<h2>Routers, pickers and blends: the second layer</h2>
<p>Ways to decide which model to trust, or to combine them, all retrained walk-forward as history grew.</p>
<div class="card tablewrap" id="l2"></div>

<h2>A picker of pickers</h2>
<p>One more layer: an online learner choosing, for each account and half of the window, among eight second-layer strategies (the median, a trimmed mean, the median with a learned bias, recency-weighted top 5 and best one, a shrunk learned blend, the shipping rule, and the best single model). It retrains after every completed window, so it changes as your usage does. Hedge provably approaches the best strategy in hindsight; Fixed-Share is built to follow a best strategy that changes over time. The hindsight rows are ceilings: what a perfect picker could reach.</p>
<div class="card tablewrap" id="l3"></div>
<p>On 5-hour windows, the best strategy for each account in hindsight is the median itself (2.77), so a picker of pickers can at most tie it, and Hedge gets within 0.04. On 7-day windows the per-account ceiling (6.94–6.99) sits about 0.3–0.4 pp below the median, but no online picker reaches it yet. The best gets 7.49, still worse than the plain median. The per-case ceiling is out of reach for any picker: which model lands closest in a given window is effectively random.</p>
<h3>What the picker of pickers chose</h3>
<p>Share of cases given to each strategy, per quarter of your history (Hedge, records pooled across accounts). On 5-hour windows it settles on the median by itself. On 7-day windows it never settles, because ~34 weeks is too little record.</p>
<div class="legend" id="pklegend"></div><div class="card" id="pk"></div>

<h2>What moves the meter</h2>
<div class="card"><ul>
<li><b>Token spend explains the meter almost completely:</b> hour-by-hour out-of-sample R² ≈ 0.96 on the 5-hour meter and 0.97 on the weekly one.</li>
<li><b>Price vs tokens:</b> API-equivalent cost with a single factor per account fits the 5-hour meter as well as 25 separate token weights (busiest account: cost R² 0.964 vs tokens 0.863). On the weekly meter, tokens (0.973) and cost with per-model factors (0.958) beat plain cost (0.892).</li>
<li><b>Per model:</b> Fable 5.1 moves the weekly all-models meter ~2.5× more per dollar than average, consistent with its own weekly cap. Model and period are confounded, though: each model was used in different weeks.</li>
<li><b>It drifts:</b> points of the 5-hour meter per API dollar ranged 0.11–0.25 week to week, about ±30% (August, mostly Opus 5, was the most generous). Hence the daily recalibration.</li>
<li><b>No off-peak generosity:</b> on the busiest account, 9 PM–3 AM moved the meter 20–30% <i>more</i> per dollar, and hour-of-day factors don't hold up out of sample. Weekends: mixed.</li>
</ul><p class="meta">Points of the 5-hour meter per API-equivalent dollar, week by week, busiest account:</p><div id="ppd"></div></div>

<h2>What's live in your Pacer now</h2>
<div class="card"><ul>
<li><b>5-hour:</b> Recent spend fading · Recent spend held · Timestral 5M / 28M / 123M / 209M · Median of the lab models. The app is currently showing the median on your main account and Timestral 28M on another, picked by their records.</li>
<li><b>7-day:</b> Last day's spend held · Median of twelve. Built-in models still win the weekly pick.</li>
<li>Served by a local helper; after a reboot restart it with <code>LAB_HELPER_PYTHON=research/lab/foundation/.venv/bin/python make lab-helper</code> in the lab worktree. Without it, Pacer falls back to the built-in models.</li>
</ul></div>

<h2>Caveats</h2>
<div class="card"><ul>
<li>The activity prior (your usual usage by hour) is built from the whole store, so "Your daily rhythm" and the ML features saw a little of the future. That mildly flatters them.</li>
<li>Weekly results rest on 276 cases from ~34 completed weeks. Treat any single weekly winner as provisional.</li>
<li>With ~650 candidates, the best of a family is optimistically biased. That's why the periods-won column matters more than a small gap.</li>
<li>The live helper's fading models can't borrow from other accounts on a thin record, so the live 7-day median scores 7.41 against 7.20 in the lab.</li>
</ul></div>

<h2>Every candidate</h2>
<p><input type="search" id="q" placeholder="Filter by name or family"> <span class="meta" id="qn"></span></p>
<div class="card tablewrap"><table id="all"><thead></thead><tbody></tbody></table></div>
</main><div id="tip"></div>
<script>
const D=/*DATA*/;
const FAMS=["Built-in models","Token / cost models","Timestral (Mistral)","Other foundation models","Machine learning","Second layer","Apple Foundation Models","Picker of pickers"];
const col=f=>FAMS.includes(f)?`var(--s${FAMS.indexOf(f)+1})`:"var(--ref)";const W={five_hour:"5-hour",seven_day:"7-day"};
const rule=w=>D.rows.find(r=>r.name==="rule-current"&&r.window===w);
const tip=document.getElementById("tip");
function showTip(e,html){tip.innerHTML=html;tip.style.display="block";const x=Math.min(e.clientX+14,innerWidth-tip.offsetWidth-8);tip.style.left=x+"px";tip.style.top=(e.clientY+14)+"px"}
function hideTip(){tip.style.display="none"}
const wins=(r)=>{const b=rule(r.window);return r.folds&&b?r.folds.filter((x,i)=>x<b.folds[i]).length:0};
const pct=(r)=>{const b=rule(r.window).headline;return((1-r.headline/b)*100)};
const fmt=x=>x==null?"–":x.toFixed(2);
const sgn=x=>x>=0?`${x.toFixed(1)}% better`:`${(-x).toFixed(1)}% worse`;
function tipHtml(r,label){return `<b>${label||r.name}</b><br>${r.family}<br>typical miss ${fmt(r.headline)} pp (${sgn(pct(r))} vs rule)<br>periods won ${wins(r)}/4 · cases ${r.cases}${r.coverage!=null?`<br>80% range covered ${(r.coverage*100).toFixed(0)}%`:""}`}
function legend(id,items){document.getElementById(id).innerHTML=items.map(([l,c])=>`<span><i style="background:${c}"></i>${l}</span>`).join("")}
function tabs(id,cb){const el=document.getElementById(id);el.innerHTML=Object.entries(W).map(([k,v])=>`<button data-w="${k}" aria-pressed="${k==="five_hour"}">${v}</button>`).join("");
 el.onclick=e=>{const b=e.target.closest("button");if(!b)return;el.querySelectorAll("button").forEach(x=>x.setAttribute("aria-pressed",x===b));cb(b.dataset.w)};cb("five_hour")}
// Tiles
(()=>{const f5=D.featured.five_hour.find(r=>r.name==="l3-median6-5h"),f7=D.featured.seven_day.find(r=>r.name==="l3-median12-7d");
const t=[["5-hour · median of 6 (live)",f5.headline.toFixed(2)+" pp",`vs ${rule("five_hour").headline.toFixed(2)} shipping rule · ${sgn(pct(f5))} · ${wins(f5)}/4 periods`],
["7-day · median of 12",f7.headline.toFixed(2)+" pp",`vs ${rule("seven_day").headline.toFixed(2)} shipping rule · ${sgn(pct(f7))} · ${wins(f7)}/4 periods · live helper 7.41`],
["Token spend → meter","R² 0.96","hour by hour, out of sample"],
["Candidates scored",new Set(D.rows.filter(r=>r.tier!=null).map(r=>r.name)).size,"8 families, both windows"]];
document.getElementById("tiles").innerHTML=t.map(([k,v,s])=>`<div class="tile"><div class="k">${k}</div><div class="v">${v}</div><div class="s">${s}</div></div>`).join("");
document.getElementById("ncases").textContent=`${D.cases.five_hour.toLocaleString()} five-hour and ${D.cases.seven_day} weekly cases.`})();
legend("lblegend",FAMS.map(f=>[f,col(f)]).concat([["Shipping rule","var(--ref)"]]));
// Leaderboard: one dot per contender on an absolute, zoomed scale; the
// shipping rule is the dashed line, anything past 1.5x it is listed below.
tabs("lbtabs",w=>{const ref=rule(w).headline,cap=ref*1.5;const all=[...D.featured[w]].sort((a,b)=>a.headline-b.headline);
 // A score on a sample is not on the same cases as the rest, so it is listed, not plotted.
 const sampled=all.filter(r=>r.share<0.9),full=all.filter(r=>r.share>=0.9);
 const rows=full.filter(r=>r.headline<=cap),off=full.filter(r=>r.headline>cap);
 const rh=26,L=320,R=200,Wd=1000,H=rows.length*rh+40,lo=Math.max(0,Math.floor(Math.min(...rows.map(r=>r.headline))-0.5)),hi=Math.ceil(cap);
 const x=v=>L+(Wd-L-R)*(v-lo)/(hi-lo);const step=hi-lo>6?2:(hi-lo>3?1:0.5);
 let s=`<svg viewBox="0 0 ${Wd} ${H}" role="img" aria-label="Leaderboard ${W[w]}">`;
 for(let v=lo;v<=hi+1e-9;v+=step)s+=`<line x1="${x(v)}" x2="${x(v)}" y1="0" y2="${H-34}" stroke="var(--grid)"/><text class="muted" x="${x(v)}" y="${H-18}" text-anchor="middle">${+v.toFixed(1)}</text>`;
 s+=`<text class="muted" x="${(L+Wd-R)/2}" y="${H-2}" text-anchor="middle">typical miss at reset, percentage points (lower is better)</text>`;
 s+=`<line x1="${x(ref)}" x2="${x(ref)}" y1="0" y2="${H-34}" stroke="var(--ref)" stroke-width="2" stroke-dasharray="4 3"/>`;
 rows.forEach((r,i)=>{const y=i*rh+14,isRule=r.name==="rule-current";const p=pct(r);
  s+=`<g data-i="${i}"><rect x="0" y="${y-12}" width="${Wd}" height="${rh}" fill="transparent"/>
  <line x1="${L}" x2="${Wd-R}" y1="${y}" y2="${y}" stroke="var(--grid)" stroke-dasharray="1 4"/>
  <text x="${L-12}" y="${y+4}" text-anchor="end" style="fill:var(--ink)${isRule?";font-weight:600":""}">${r.label}</text>
  <circle cx="${x(r.headline)}" cy="${y}" r="7" fill="${r.name.startsWith("rule-")?"var(--ref)":col(r.family)}" stroke="var(--surface)" stroke-width="2"/>
  <text x="${Wd-R+12}" y="${y+4}" style="fill:var(--ink)">${r.headline.toFixed(2)}</text>
  <text x="${Wd-R+56}" y="${y+4}" style="fill:${isRule?"var(--muted)":(p>=0?"var(--good)":"var(--bad)")}">${isRule?"reference":sgn(p)+" · "+wins(r)+"/4"}</text></g>`});
 s+=`</svg>`+(off.length?`<p class="meta">Off the scale (more than 1.5× the shipping rule): ${off.map(r=>`${r.label} ${r.headline.toFixed(1)}`).join(" · ")}</p>`:"")
 +(sampled.length?`<p class="meta">Scored on a ${sampled[0].cases}-case sample, so not comparable here: ${sampled.map(r=>`${r.label} ${r.headline.toFixed(1)}`).join(" · ")}. As a router, Apple's model only tied the best model it was choosing from on the same sample.</p>`:"");
 const el=document.getElementById("lb");el.innerHTML=s;el.querySelectorAll("g[data-i]").forEach(g=>{const r=rows[+g.dataset.i];g.onmousemove=e=>showTip(e,tipHtml(r,r.label));g.onmouseleave=hideTip})});
// Fit spectrum (strip chart)
tabs("fstabs",w=>{const rows=D.rows.filter(r=>r.window===w&&r.share>0.9&&r.headline!=null&&r.tier!=null);const Wd=900,H=380,T=4,pad=60,top=10,bot=60;
 const vals=rows.map(r=>r.headline).sort((a,b)=>a-b),hi=vals[Math.floor(vals.length*0.97)]*1.05,lo=Math.max(0,vals[0]*0.9);
 const y=v=>top+(H-top-bot)*(1-(Math.min(v,hi)-lo)/(hi-lo)),cw=(Wd-pad)/T,ref=rule(w).headline;
 let s=`<svg viewBox="0 0 ${Wd} ${H}" role="img" aria-label="Fit spectrum ${W[w]}">`;
 for(let i=0;i<5;i++){const v=lo+(hi-lo)*i/4;s+=`<line x1="${pad}" x2="${Wd}" y1="${y(v)}" y2="${y(v)}" stroke="var(--grid)"/><text class="muted" x="${pad-8}" y="${y(v)+4}" text-anchor="end">${v.toFixed(1)}</text>`}
 D.tiers.forEach((t,i)=>{const cx=pad+cw*(i+.5);s+=`<foreignObject x="${pad+cw*i+6}" y="${H-bot+8}" width="${cw-12}" height="48"><div xmlns="http://www.w3.org/1999/xhtml" style="font-size:11px;color:var(--ink2);text-align:center;line-height:1.3">${t}</div></foreignObject>`});
 rows.forEach((r,k)=>{const h=[...r.name].reduce((a,c)=>(a*31+c.charCodeAt(0))>>>0,7);const jx=((h%1000)/1000-.5)*cw*.7;const cx=pad+cw*(r.tier+.5)+jx;
  s+=`<circle data-k="${k}" cx="${cx}" cy="${y(r.headline)}" r="4.5" fill="${col(r.family)}" stroke="var(--surface)" stroke-width="1.5"/>`});
 s+=`<line x1="${pad}" x2="${Wd}" y1="${y(ref)}" y2="${y(ref)}" stroke="var(--ref)" stroke-width="2" stroke-dasharray="4 3"/><text x="${Wd}" y="${y(ref)-6}" text-anchor="end">shipping rule ${ref.toFixed(2)}</text></svg>`;
 const el=document.getElementById("fs");el.innerHTML=s;el.querySelectorAll("circle").forEach(c=>{const r=rows[+c.dataset.k];c.onmousemove=e=>showTip(e,tipHtml(r,D.labels[r.name]));c.onmouseleave=hideTip})});
// Learning curves (5h)
(()=>{const C=D.curves.five_hour,keys=[["rule-current","Shipping rule"],["engine-recent-rate","Latest pace, held"],["fm-timestral-28m-6h_3d","Timestral 28M"],["tokc-decay-30m","Cost burn, fading"],["l2-comb-med-all-all","Median of all"],["l2-route-gbm-all","Learned router"],["p3-hedge-pick-e1-pooled","Picker of pickers (Hedge)"]];
 const cols=["var(--ref)","var(--s1)","var(--s3)","var(--s2)","var(--s6)","var(--s5)","var(--s8)"];legend("lclegend",keys.map((k,i)=>[k[1],cols[i]]));
 const Wd=900,H=320,L=50,R=20,T=10,B=50,n=C.buckets.length,xs=i=>L+(Wd-L-R)*i/(n-1);const all=keys.flatMap(k=>C.series[k[0]]||[]).filter(v=>v!=null);const mx=Math.max(...all)*1.08,mn=Math.min(...all)*0.9;const y=v=>T+(H-T-B)*(1-(v-mn)/(mx-mn));
 let s=`<svg viewBox="0 0 ${Wd} ${H}" role="img" aria-label="Learning curves">`;for(let i=0;i<5;i++){const v=mn+(mx-mn)*i/4;s+=`<line x1="${L}" x2="${Wd-R}" y1="${y(v)}" y2="${y(v)}" stroke="var(--grid)"/><text class="muted" x="${L-8}" y="${y(v)+4}" text-anchor="end">${v.toFixed(1)}</text>`}
 C.buckets.forEach((b,i)=>s+=`<text class="muted" x="${xs(i)}" y="${H-28}" text-anchor="middle">${b}</text><text class="muted" x="${xs(i)}" y="${H-12}" text-anchor="middle" style="font-size:10px">${C.counts[i]} cases</text>`);
 keys.forEach(([k,l],j)=>{const v=C.series[k];if(!v)return;const pts=v.map((y_,i)=>y_==null?null:[xs(i),y(y_)]).filter(Boolean);
  s+=`<polyline points="${pts.map(p=>p.join(",")).join(" ")}" fill="none" stroke="${cols[j]}" stroke-width="2" ${k==="rule-current"?'stroke-dasharray="5 4"':""}/>`;
  v.forEach((y_,i)=>{if(y_!=null)s+=`<circle cx="${xs(i)}" cy="${y(y_)}" r="4" fill="${cols[j]}" stroke="var(--surface)" stroke-width="2"><title>${l}: ${y_.toFixed(2)} pp with ${C.buckets[i]} windows of record</title></circle>`})});
 s+=`<text class="muted" x="${(Wd)/2}" y="${H}" text-anchor="middle">completed windows of the account's own record before the case</text></svg>`;document.getElementById("lc").innerHTML=s})();
// Timestral table
(()=>{const sizes=["5M","28M","123M","209M"],ctx=[...new Set(D.timestral.map(t=>t.context))];const get=(s,c,w)=>D.timestral.find(t=>t.size===s&&t.context===c&&t.window===w);
 const ctxLabel=c=>({"6h_3d":"6 h / 3 d","12h_3d":"12 h / 3 d","1d_1w":"1 d / 1 wk","2d_2w":"2 d / 2 wk","1w_4w":"1 wk / 4 wk"})[c]||c;
 let h=`<table><thead><tr><th>Context (5-hour / 7-day)</th>${sizes.map(s=>`<th class="n">${s} · 5h</th>`).join("")}${sizes.map(s=>`<th class="n">${s} · 7d</th>`).join("")}</tr></thead><tbody>`;
 ["6h_3d","12h_3d","1d_1w","2d_2w","1w_4w"].filter(c=>ctx.includes(c)).forEach(c=>{h+=`<tr><td>${ctxLabel(c)}</td>`;["five_hour","seven_day"].forEach(w=>sizes.forEach(s=>{const t=get(s,c,w);const b=rule(w).headline;h+=`<td class="n" ${t&&t.headline<b?'style="color:var(--good);font-weight:600"':""}>${t?t.headline.toFixed(2):"–"}</td>`}));h+="</tr>"});
 h+=`</tbody></table><p class="meta">Green beats the shipping rule (5-hour ${rule("five_hour").headline.toFixed(2)}, 7-day ${rule("seven_day").headline.toFixed(2)}). Other families: TiRex, TimesFM and Toto landed near the rule on 5-hour; Chronos and Moirai were worse everywhere.</p>`;document.getElementById("ts").innerHTML=h})();
// Second-layer table
(()=>{const items=[["l2-sel-acct-half-all","Pick the best model by its record (per account, per half of the window)","few"],["l2-sel-pooled-half-all","…the same, records pooled across accounts","few"],
["l2-meta-5pct-all","A rule-picker choosing among these strategies by their own record, switching only when 5% better","few"],["l2-meta-0pct-all","…switching whenever another strategy is ahead","few"],
["l2-route-gbm-all","Learned router: gradient boosting predicts each model's miss from context, then uses the lowest","many"],["l2-stack-gbm-all","Learned stacker: gradient boosting maps all models' answers + context to the final","many"],
["l2-stack-nnls-pooled-all-all","Learned blend: non-negative weights fit to past cases","many"],["l2-comb-invw5-pooled-all-all","Top 5 models by record, weighted by 1/error²","few"],
["l2-comb-med5-pooled-all-all","Median of the top 5 by record","few"],["l2-comb-med-all-all","Median of every candidate, no learning","none"],["afm-router","Apple's on-device LLM as router (300-case sample)","pretrained"]];
 let h=`<table><thead><tr><th>Strategy</th><th>Learns</th><th class="n">5-hour</th><th class="n">vs rule</th><th class="n">periods</th><th class="n">7-day</th><th class="n">vs rule</th><th class="n">periods</th></tr></thead><tbody>`;
 items.forEach(([n,l,k])=>{h+=`<tr><td>${l}</td><td>${k}</td>`;["five_hour","seven_day"].forEach(w=>{const r=D.rows.find(x=>x.name===n&&x.window===w);h+=r?`<td class="n">${r.headline.toFixed(2)}</td><td class="n">${sgn(pct(r))}</td><td class="n">${wins(r)}/4</td>`:`<td class="n">–</td><td></td><td></td>`});h+="</tr>"});
 document.getElementById("l2").innerHTML=h+`</tbody></table>`})();
// Picker of pickers: results table and what it chose per quarter.
(()=>{const items=[["p2-median","Plain median of the curated models","nothing"],["p2-ewinvw5-30-pooled","Top 5 by recency-weighted record","a few numbers"],
["p2-medbias-acct","Median + its typical bias at this point of the window","a few numbers"],["p2-hedge-avg-e0.3-hier","Hedge over every base model","a few numbers"],
["p3-pooled-last25-m5","Picker of pickers by its last 25 windows (switch at 5% better)","a few numbers"],["p3-hedge-pick-e1-pooled","Picker of pickers (Hedge)","a few numbers"],
["p3-fs10-pick-e1-acct","Picker of pickers (Fixed-Share, per account)","a few numbers"],
["p3-fs10-avg-e0.3-acct","Picker of pickers, weighted blend (Fixed-Share, per account)","a few numbers"],
["p3-hindsight-acct","Ceiling: best strategy per account, in hindsight","hindsight"],["p3-hindsight-acct-half","Ceiling: best per account and half, in hindsight","hindsight"],
["p3-hindsight-case","Ceiling: best strategy for every single case, in hindsight","hindsight"]];
 let h=`<table><thead><tr><th>Strategy</th><th>Learns</th><th class="n">5-hour</th><th class="n">vs rule</th><th class="n">periods</th><th class="n">7-day</th><th class="n">vs rule</th><th class="n">periods</th></tr></thead><tbody>`;
 items.forEach(([n,l,k])=>{const ceil=k==="hindsight";h+=`<tr${ceil?' style="color:var(--muted)"':""}><td>${l}</td><td>${k}</td>`;["five_hour","seven_day"].forEach(w=>{const r=D.rows.find(x=>x.name===n&&x.window===w);h+=r?`<td class="n">${r.headline.toFixed(2)}</td><td class="n">${sgn(pct(r))}</td><td class="n">${wins(r)}/4</td>`:`<td class="n">–</td><td></td><td></td>`});h+="</tr>"});
 document.getElementById("l3").innerHTML=h+`</tbody></table>`;
 const S=D.picks.five_hour.strategies,pc=S.map((_,i)=>`var(--s${i+1})`);legend("pklegend",S.map((s,i)=>[s,pc[i]]));
 const Wd=900,L=110,R=60,bh=22,gap=10,panel=(w)=>{const v=D.picks[w].variants["hedge-pick-e1-pooled"],H=4*(bh+gap)+28;let s=`<svg viewBox="0 0 ${Wd} ${H}" role="img" aria-label="Picker choices ${W[w]}"><text x="0" y="14" style="fill:var(--ink);font-weight:600">${W[w]}</text>`;
  v.forEach((shares,q)=>{const y=24+q*(bh+gap);let x=L;s+=`<text x="${L-10}" y="${y+15}" text-anchor="end">quarter ${q+1}</text>`;
   shares.forEach((f,i)=>{if(f<=0)return;const wdt=(Wd-L-R)*f;s+=`<rect x="${x}" y="${y}" width="${Math.max(0,wdt-2)}" height="${bh}" rx="3" fill="${pc[i]}"><title>${S[i]}: ${(f*100).toFixed(0)}% of quarter ${q+1}</title></rect>`;if(f>=0.12)s+=`<text x="${x+6}" y="${y+15}" style="fill:#fff;font-size:11px">${(f*100).toFixed(0)}%</text>`;x+=wdt});});
  return s+`</svg>`};
 document.getElementById("pk").innerHTML=panel("five_hour")+panel("seven_day")})();
// Points per dollar (weekly, hardcoded from factor_over_time.py)
(()=>{const wk=["May 4","May 11","May 18","May 25","Jun 1","Jun 8","Jun 15","Jun 22","Jun 29","Jul 6","Jul 13","Jul 20","Jul 27","Aug 3","Aug 10","Aug 17","Aug 24","Aug 31","Sep 7","Sep 14","Sep 21","Sep 28","Oct 5","Oct 12","Oct 19"];
 const v=[.184,.180,.202,.230,.186,.212,.193,.227,.253,.192,.145,.165,.182,.122,.113,.137,.123,.170,.153,.161,.201,.155,.170,.186,.167];
 const Wd=900,H=220,L=50,R=20,T=10,B=40,x=i=>L+(Wd-L-R)*i/(v.length-1),y=a=>T+(H-T-B)*(1-(a-.08)/(.28-.08));
 let s=`<svg viewBox="0 0 ${Wd} ${H}" role="img" aria-label="Points per dollar by week">`;[.1,.15,.2,.25].forEach(a=>s+=`<line x1="${L}" x2="${Wd-R}" y1="${y(a)}" y2="${y(a)}" stroke="var(--grid)"/><text class="muted" x="${L-8}" y="${y(a)+4}" text-anchor="end">${a.toFixed(2)}</text>`);
 wk.forEach((w,i)=>{if(i%3===0)s+=`<text class="muted" x="${x(i)}" y="${H-14}" text-anchor="middle">${w}</text>`});
 s+=`<polyline points="${v.map((a,i)=>x(i)+","+y(a)).join(" ")}" fill="none" stroke="var(--s2)" stroke-width="2"/>`+v.map((a,i)=>`<circle cx="${x(i)}" cy="${y(a)}" r="4" fill="var(--s2)" stroke="var(--surface)" stroke-width="2"><title>week of ${wk[i]}: ${a.toFixed(3)} points per $</title></circle>`).join("")+`</svg>`;
 document.getElementById("ppd").innerHTML=s})();
// Full table
(()=>{const names=[...new Set(D.rows.map(r=>r.name))];const get=(n,w)=>D.rows.find(r=>r.name===n&&r.window===w);
 const rows=names.map(n=>{const a=get(n,"five_hour"),b=get(n,"seven_day"),any=a||b;return{n,label:D.labels[n]||"",fam:any.family,tier:any.tier,h5:a?a.headline:null,w5:a?wins(a):null,h7:b?b.headline:null,w7:b?wins(b):null,cov:a&&a.coverage!=null?a.coverage:null,share:a?a.share:(b?b.share:null)}});
 const cols=[["n","Candidate"],["fam","Family"],["tier","Learns"],["h5","5-hour"],["w5","periods"],["h7","7-day"],["w7","periods"],["cov","5h range cover"]];const tierN=["nothing","this window","a few numbers","many"];const tierName=t=>t==null?"hindsight":tierN[t];
 let key="h5",asc=true;const th=document.querySelector("#all thead");th.innerHTML="<tr>"+cols.map(([k,l])=>`<th class="${["h5","w5","h7","w7","cov"].includes(k)?"n":""}" data-k="${k}">${l}</th>`).join("")+"</tr>";
 function draw(){const q=document.getElementById("q").value.toLowerCase();const f=rows.filter(r=>(r.n+r.label+r.fam).toLowerCase().includes(q)).sort((a,b)=>{const x=a[key],y=b[key];return(x==null)-(y==null)||(x<y?-1:x>y?1:0)*(asc?1:-1)});
  document.getElementById("qn").textContent=f.length+" candidates";document.querySelector("#all tbody").innerHTML=f.map(r=>`<tr><td>${r.label?r.label+"<br><span class='meta'>"+r.n+"</span>":r.n}${r.share!=null&&r.share<.9?" <span class='meta'>(sample)</span>":""}</td><td><i style="display:inline-block;width:8px;height:8px;border-radius:2px;background:${col(r.fam)};margin-right:6px"></i>${r.fam}</td><td>${tierName(r.tier)}</td><td class="n">${fmt(r.h5)}</td><td class="n">${r.w5==null?"":r.w5+"/4"}</td><td class="n">${fmt(r.h7)}</td><td class="n">${r.w7==null?"":r.w7+"/4"}</td><td class="n">${r.cov==null?"":(r.cov*100).toFixed(0)+"%"}</td></tr>`).join("")}
 th.onclick=e=>{const k=e.target.dataset.k;if(!k)return;asc=key===k?!asc:true;key=k;draw()};document.getElementById("q").oninput=draw;draw()})();
</script></body></html>
"""

if __name__ == "__main__":
    main()
