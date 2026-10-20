"""usage: run_toto.py [ctxlabel ...] -> fm-toto-151m-<ctx>. Env: TOTO_SAMPLES (default 64), TOTO_LIMIT (smoke test)."""
import os, sys, time, numpy as np, pandas as pd, torch
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from common import *
torch.set_num_threads(int(os.environ.get("FM_THREADS", 6)))
from toto.data.util.dataset import MaskedTimeseries
from toto.inference.forecaster import TotoForecaster
from toto.model.toto import Toto
labels = sys.argv[1:] or list(CTX)
NS = int(os.environ.get("TOTO_SAMPLES", 64))
toto = Toto.from_pretrained("Datadog/Toto-Open-Base-1.0").to("cpu")
fc = TotoForecaster(toto.model)
levels = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
def qfun_for(step):
    def qfun(x, H):
        B, n = x.shape
        xt = torch.tensor(x)[:, None, :]
        inp = MaskedTimeseries(series=xt, padding_mask=torch.ones_like(xt, dtype=torch.bool),
            id_mask=torch.zeros_like(xt), timestamp_seconds=torch.zeros_like(xt),
            time_interval_seconds=torch.full((B, 1), step))
        f = fc.forecast(inp, prediction_length=H, num_samples=NS, samples_per_batch=NS)
        return f.quantile(torch.tensor(levels))[:, 0].permute(1, 2, 0).numpy() if False else \
               torch.stack([f.samples[:, 0].quantile(q, dim=-1) for q in levels], -1).numpy()
    return qfun
for lbl in labels:
    name = f"fm-toto-151m-{lbl}"; t0 = time.perf_counter(); parts = []
    for w in ("five_hour", "seven_day"):
        c, ctx, h, st = contexts(w, CTX[lbl][w])
        lim = int(os.environ.get("TOTO_LIMIT", 0))
        if lim:
            c, ctx, h, st = c.iloc[:lim].reset_index(drop=True), ctx[:lim], h[:lim], st[:lim]
        parts.append(to_preds(c, ctx, h, st, qfun_for(STEP[w]), levels, batch=16 if w == "five_hour" else 4, label=f"{name}/{w}", prep=fill_gaps))
    if os.environ.get("TOTO_LIMIT"):
        print(pd.concat(parts).head()); print(f"smoke {time.perf_counter()-t0:.0f}s"); sys.exit()
    lab.write_preds(name, pd.concat(parts))
    print(f"DONE {name} {time.perf_counter()-t0:.0f}s", flush=True)
