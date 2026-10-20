"""usage: run_chronos.py MODEL_KEY [ctxlabel ...]   MODEL_KEY in bolt-tiny|bolt-mini|bolt-small|bolt-base|2"""
import os, sys, time, numpy as np, pandas as pd, torch
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from common import *
torch.set_num_threads(int(os.environ.get("FM_THREADS", 6)))
from chronos import BaseChronosPipeline
key = sys.argv[1]; labels = sys.argv[2:] or list(CTX)
hf = "amazon/chronos-2" if key == "2" else f"amazon/chronos-{key.replace('bolt-', 'bolt-')}"
pipe = BaseChronosPipeline.from_pretrained(hf, device_map="cpu", torch_dtype=torch.float32)
levels = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9] if key != "2" else list(pipe.quantiles)
MAXCTX = 2048 if key != "2" else 8192
def qfun(x, H):
    xs = [torch.tensor(r[-MAXCTX:]) for r in x]
    if key == "2":
        # Chronos-2 takes a 3D (B, n_variates, T) tensor or list of (n_variates, T)
        q, _ = pipe.predict_quantiles([t[None, :] for t in xs], prediction_length=H, quantile_levels=levels)
        return np.stack([qq[0].numpy() if hasattr(qq, 'numpy') else np.asarray(qq)[0] for qq in q]).transpose(0, 1, 2)
    q, _ = pipe.predict_quantiles(xs, prediction_length=H, quantile_levels=levels)
    return q.numpy()
tag = "chronos2" if key == "2" else f"chronos-{key}"
for lbl in labels:
    name = f"fm-{tag}-{lbl}"
    t0 = time.perf_counter(); parts = []
    for w in ("five_hour", "seven_day"):
        c, ctx, h, st = contexts(w, CTX[lbl][w])
        parts.append(to_preds(c, ctx, h, st, qfun, levels, batch=64 if w == "five_hour" else 16, label=f"{name}/{w}"))
    lab.write_preds(name, pd.concat(parts))
    print(f"DONE {name} {time.perf_counter()-t0:.0f}s", flush=True)
