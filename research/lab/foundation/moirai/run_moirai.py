"""usage: run_moirai.py [ctxlabel ...] -> fm-moirai2-small-<ctx> (Moirai 2.0 R-small, 11M; the only 2.0 size on HF)"""
import os, sys, time, numpy as np, pandas as pd, torch
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from common import *
torch.set_num_threads(int(os.environ.get("FM_THREADS", 6)))
from uni2ts.model.moirai2 import Moirai2Forecast, Moirai2Module
labels = sys.argv[1:] or list(CTX)
mod = Moirai2Module.from_pretrained("Salesforce/moirai-2.0-R-small")
levels = list(mod.quantile_levels)
for lbl in labels:
    name = f"fm-moirai2-small-{lbl}"; t0 = time.perf_counter(); parts = []
    for w in ("five_hour", "seven_day"):
        n = CTX[lbl][w]; c, ctx, h, st = contexts(w, n)
        def qfun(x, H):
            f = Moirai2Forecast(prediction_length=H, context_length=n, target_dim=1, feat_dynamic_real_dim=0,
                                past_feat_dynamic_real_dim=0, module=mod)
            q = f.predict([r[:, None] for r in x])      # (B, Q, H)
            return np.asarray(q).transpose(0, 2, 1)
        parts.append(to_preds(c, ctx, h, st, qfun, levels, batch=32 if w == "five_hour" else 8, label=f"{name}/{w}"))
    lab.write_preds(name, pd.concat(parts))
    print(f"DONE {name} {time.perf_counter()-t0:.0f}s", flush=True)
