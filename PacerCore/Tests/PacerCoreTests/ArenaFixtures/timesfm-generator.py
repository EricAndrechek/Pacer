"""TimesFM 2.5 port fixtures (synthetic snapshot only).

1. `arena port-fixtures` for fm-timesfm25-meter (the shared 20 cases, seed 42).
2. The backend's raw quantiles (`TimesFM25Backend.quantiles`, sorted) on the
   weekly cases' contexts (every 16th horizon step) and on edge contexts the
   meter cases never reach: a length off the 32-patch grid (front padding),
   NaN gaps (fill_gaps), a constant series (sigma 0), a negative series (no
   positivity clamp), a horizon past the continuous quantile head (1100).
"""
import json
import sys
import time

import numpy as np

from arena import cli_portfix

out_dir = sys.argv[1]
rc = cli_portfix.main(["port-fixtures", "--model", "fm-timesfm25-meter", "--snapshot", "port-fixtures",
                       "--seed", "42", "--cases", "20", "--out", out_dir])
assert rc == 0

from kit.fm.backends import get_backend

W = "google/timesfm-2.5-200m-pytorch@1d952420fba87f3c6dee4f240de0f1a0fbc790e3"
be = get_backend("timesfm25", W, 4)
doc = json.load(open(f"{out_dir}/fm-timesfm25-meter.json"))


def r6(x):
    return None if not np.isfinite(x) else round(float(x), 6)


rows = []
for o in doc["outputs"]:
    d = o["detail"]
    if "raw" in d or not d.get("context") or d.get("horizon_steps", 0) <= 0:
        continue
    ctx = np.array([np.nan if v is None else v for v in d["context"]], dtype=np.float64)
    h = int(d["horizon_steps"])
    t0 = time.time()
    lv, q = be.quantiles(ctx[None, None, :], h)
    dt = time.time() - t0
    every = 16
    rows.append({"case": o["case"], "horizon": h, "every": every, "context": None,
                 "raw": [[r6(v) for v in q[0, 0, i]] for i in range(0, h, every)], "seconds": round(dt, 4)})

rng = np.random.default_rng(7)
base = np.cumsum(np.maximum(rng.normal(0.05, 0.1, 700), 0))
edge = {
    "pad300": (base[:300].copy(), 60),
    "nan-gaps": (np.where((np.arange(288) % 50) < 6, np.nan, base[:288]), 60),
    "lead-nan": (np.concatenate([np.full(40, np.nan), base[:248]]), 40),
    "constant": (np.full(288, 3.25), 30),
    "negative": (np.sin(np.arange(288) / 9.0) - 0.4 + base[:288] * 0.01, 50),
    "h1100": (base[:672].copy(), 1100),
    "h200-pad": (base[:500].copy(), 200),
}
for name, (ctx, h) in edge.items():
    t0 = time.time()
    lv, q = be.quantiles(ctx[None, None, :], h)
    dt = time.time() - t0
    every = 1 if h <= 60 else 10
    rows.append({"case": name, "horizon": h, "every": every, "context": [r6(v) for v in ctx],
                 "raw": [[r6(v) for v in q[0, 0, i]] for i in range(0, h, every)], "seconds": round(dt, 4)})
    print(name, h, round(dt, 3), file=sys.stderr)

json.dump({"format": 1, "weights": W, "levels": [float(x) for x in lv],
           "note": "TimesFM25Backend.quantiles (kit/fm/backends.py, timesfm==3.0.2, torch, CPU, float32) "
                   "on the fm-timesfm25-meter weekly cases' contexts and on edge contexts; raw [H/every][9], "
                   "sorted; context null = the case's own (timesfm-meter.json detail.context)",
           "cases": rows}, open(f"{out_dir}/timesfm-raw.json", "w"), separators=(",", ":"))
print("done", file=sys.stderr)
