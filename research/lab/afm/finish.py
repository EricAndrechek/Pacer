"""Turn AFM outputs into preds and print sampled-case comparison. Run from research/lab: uv run afm/finish.py"""
import sys, json, numpy as np, pandas as pd
sys.path.insert(0, "."); import lab
CANDS = ["rule-current", "engine-recent-rate", "tok-decay-30m", "tok-rate-1d-cal"]
ids = pd.read_csv("afm/sample_ids.csv").case_id
c = lab.cases(); c = c[c.case_id.isin(set(ids))]
def load(p): return [json.loads(l) for l in open(p)]
f = load("afm/out-forecast.jsonl"); r = load("afm/out-router.jsonl")
fe = pd.DataFrame(f); re_ = pd.DataFrame(r)
print("errors forecast/router:", fe.get("error", pd.Series()).notna().sum(), re_.get("error", pd.Series()).notna().sum())
for n, d in (("forecast", fe), ("router", re_)):
    print(n, "latency mean %.2fs median %.2fs p95 %.2fs max %.2fs n=%d" % (d.latency.mean(), d.latency.median(), d.latency.quantile(.95), d.latency.max(), len(d)))
if "error" in fe: fe = fe[fe.error.isna()]
if "error" in re_: re_ = re_[re_.error.isna()]
lab.write_preds("afm-forecast", pd.DataFrame({"case_id": fe.id, "pred": fe.value.astype(float)}))
P = {n: lab.read_preds(n).set_index("case_id").pred for n in CANDS}
rows = []
picks = []
for _, x in re_.iterrows():
    k = int(x.value); k = k if 0 <= k < 4 else 0
    v = P[CANDS[k]].get(x.id, np.nan)
    if pd.isna(v): v = P["rule-current"].get(x.id, np.nan); k = -1
    rows.append((x.id, v)); picks.append(k)
lab.write_preds("afm-router", pd.DataFrame(rows, columns=["case_id", "pred"]))
print("router picks:", pd.Series(picks).value_counts().sort_index().to_dict())
for n in ["afm-forecast", "afm-router", "rule-current", "tok-decay-30m", "tok-rate-1d-cal"]:
    s = lab.score(n, c=c)
    print(n, {w: (v["cases"], round(v["headline"], 2), round(v["mean"], 2)) for w, v in s.items()})
# restrict to cases both afm files answered
