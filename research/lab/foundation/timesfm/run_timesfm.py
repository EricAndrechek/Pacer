"""usage: run_timesfm.py [ctxlabel ...] -> fm-timesfm25-200m-<ctx>"""
import os, sys, time, numpy as np, pandas as pd, torch
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from common import *
torch.set_num_threads(int(os.environ.get("FM_THREADS", 6)))
import timesfm
from timesfm.configs import ForecastConfig
labels = sys.argv[1:] or list(CTX)
levels = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
m = timesfm.TimesFM_2p5_200M_torch.from_pretrained("google/timesfm-2.5-200m-pytorch")
for lbl in labels:
    name = f"fm-timesfm25-200m-{lbl}"; t0 = time.perf_counter(); parts = []
    for w in ("five_hour", "seven_day"):
        n = CTX[lbl][w]; c, ctx, h, st = contexts(w, n)
        mh = int(-(-h.max() // 128) * 128)
        m.compile(ForecastConfig(max_context=min(n, 16384), max_horizon=mh, normalize_inputs=True,
                                 use_continuous_quantile_head=True, fix_quantile_crossing=True, per_core_batch_size=16))
        def qfun(x, H):
            _, q = m.forecast(horizon=H, inputs=[r[-16384:] for r in x])
            return np.asarray(q)[:, :, 1:10]
        parts.append(to_preds(c, ctx, h, st, qfun, levels, batch=16, label=f"{name}/{w}", prep=fill_gaps))
    lab.write_preds(name, pd.concat(parts))
    print(f"DONE {name} {time.perf_counter()-t0:.0f}s", flush=True)
