"""usage: run_timestral.py SIZE [ctxlabel ...]  -> preds/fm-timestral-<size>-<ctxlabel>.parquet"""
import sys, time, numpy as np, pandas as pd, torch
from common import *
import os; torch.set_num_threads(int(os.environ.get("FM_THREADS", 6)))
from timestral import TimestralForecaster
size = sys.argv[1]; labels = sys.argv[2:] or [k for k in CTX if k not in CTX_SHORT]
fc = TimestralForecaster.from_pretrained(f"mistralai/Timestral-{size}", local_files_only=True)
levels = np.asarray(fc.quantile_levels)
def qfun(x, H):
    return fc.forecast(x, prediction_length=H).quantiles.numpy()[:, 0]
for lbl in labels:
    name = f"fm-timestral-{size.lower()}-{lbl}"
    t0 = time.perf_counter(); parts = []
    for w in ("five_hour", "seven_day"):
        c, ctx, h, st = contexts(w, CTX[lbl][w])
        parts.append(to_preds(c, ctx, h, st, qfun, levels, batch=64 if w == "five_hour" else 16, label=f"{name}/{w}"))
    lab.write_preds(name, pd.concat(parts))
    print(f"DONE {name} {time.perf_counter()-t0:.0f}s", flush=True)
