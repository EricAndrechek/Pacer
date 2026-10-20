"""usage: run_tirex.py [ctxlabel ...] -> fm-tirex-35m-<ctx>"""
import os, sys, time, numpy as np, pandas as pd, torch
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from common import *
torch.set_num_threads(int(os.environ.get("FM_THREADS", 6)))
from tirex import load_model
labels = sys.argv[1:] or list(CTX)
levels = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
m = load_model("NX-AI/TiRex", device="cpu")
def qfun(x, H):
    q, _ = m.forecast(context=torch.tensor(x), prediction_length=H)
    return q.numpy()
for lbl in labels:
    name = f"fm-tirex-35m-{lbl}"; t0 = time.perf_counter(); parts = []
    for w in ("five_hour", "seven_day"):
        c, ctx, h, st = contexts(w, CTX[lbl][w])
        parts.append(to_preds(c, ctx, h, st, qfun, levels, batch=32 if w == "five_hour" else 8, label=f"{name}/{w}"))
    lab.write_preds(name, pd.concat(parts))
    print(f"DONE {name} {time.perf_counter()-t0:.0f}s", flush=True)
