"""Build AFM prompts on a stratified sample. Run from research/lab: uv run afm/prep.py"""
import sys, json, numpy as np, pandas as pd
sys.path.insert(0, ".."); sys.path.insert(0, ".")
import lab
CANDS = ["rule-current", "engine-recent-rate", "tok-decay-30m", "tok-rate-1d-cal"]
c = lab.cases()
P = {n: lab.read_preds(n).set_index("case_id")["pred"] for n in CANDS}
for n in CANDS: c[n] = c.case_id.map(P[n])
c["err_"] = 0
rng = np.random.default_rng(7)
fh = c[c.window == "five_hour"]
# stratify: account x fold x cut, round-robin
fh = fh.sample(frac=1, random_state=7)
fh["strat"] = fh.groupby(["account", "fold", "cut"]).cumcount()
fh = fh.sort_values("strat", kind="stable").head(300)
sd = c[c.window == "seven_day"]
S = pd.concat([fh, sd])
S[["case_id"]].to_csv("afm/sample_ids.csv", index=False)
print(S.groupby("window").size(), fh.account.value_counts().to_dict(), fh.fold.value_counts().to_dict(), fh.cut.value_counts().sort_index().to_dict())
h = lab.History()
byacct = {k: g for k, g in c.groupby(["window", "account"])}
def dur(s): return f"{s/3600:.1f}h" if s < 86400*2 else f"{s/86400:.1f}d"
def traj(g, cut):
    g = g[g.cut <= cut + 1e-9].sort_values("cut")
    return " ".join(f"{int(round(x*100))}%:{u:.0f}" for x, u in zip(g.cut, g.used_now))
fc, rt = [], []
for _, r in S.iterrows():
    W = lab.WINDOWS[r.window]
    allc = byacct[(r.window, r.account)]
    past = allc[(allc.resets_at < r.t_cut)]                       # cycles that had reset
    own = allc[(allc.resets_at == r.resets_at)]
    cur = traj(own, r.cut)
    s = h.series(r.window, r.account, until=r.t_cut, since=r.t_cut - 0.1 * W)
    if len(s) >= 2 and s.t.iloc[-1] > s.t.iloc[0]:
        rate = (s.pct.iloc[-1] - s.pct.iloc[0]) / ((s.t.iloc[-1] - s.t.iloc[0]) / 3600)
        rs = f"burn over the last {dur(s.t.iloc[-1]-s.t.iloc[0])}: {rate:+.2f} pct points per hour"
    else: rs = "burn rate over the last 10% of the window: unknown"
    pc = past[past.cut == r.cut]
    sim = pc.iloc[(pc.used_now - r.used_now).abs().argsort()[:4]]
    ex = "\n".join(f"- past cycle: {traj(past[past.resets_at==x.resets_at], r.cut)} -> final {x.truth:.0f}" for _, x in sim.iterrows()) or "- none available"
    head = (f"Rate-limit window of {dur(W)}. Now {r.cut*100:.0f}% elapsed ({dur(r.cut*W)} elapsed, {dur((1-r.cut)*W)} remaining). "
            f"Usage meter now {r.used_now:.0f}%. Readings so far (elapsed%:usage): {cur}. {rs}.")
    fc.append({"id": r.case_id, "kind": "forecast", "prompt": head + "\nSimilar past cycles of this account, same point in the window:\n" + ex +
               "\nPredict the usage meter value (0-100) at the end of this window. It never decreases and caps at 100."})
    # router: track record on the past 6 cycles at this cut
    pr = pc.sort_values("resets_at").tail(6)
    lines = []
    for i, n in enumerate(CANDS):
        e = (pr[n].clip(lower=pr.used_now, upper=100) - pr.truth).abs().dropna()
        v = "unavailable" if pd.isna(r[n]) else f"{max(r.used_now, min(100, r[n])):.0f}"
        lines.append(f"{i}. {n}: predicts {v}; mean abs error on last {len(e)} past cycles at this cut: " + (f"{e.mean():.1f}" if len(e) else "n/a"))
    rt.append({"id": r.case_id, "kind": "router", "prompt": head + "\nCandidate forecasters for the final usage:\n" + "\n".join(lines) +
               "\nWhich candidate (index 0-3) should be trusted for this case?"})
for name, L in (("forecast", fc), ("router", rt)):
    open(f"afm/prompts-{name}.jsonl", "w").write("\n".join(json.dumps(x) for x in L) + "\n")
print(fc[0]["prompt"]); print(rt[0]["prompt"])
