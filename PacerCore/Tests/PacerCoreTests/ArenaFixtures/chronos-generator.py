"""Raw Chronos-2 outputs for the Swift port's network tests, on the port
fixtures' own synthetic contexts.

`arena port-fixtures` keeps the network's raw quantiles for five-hour cases
only (`include_raw`), and only for one variate. This runs the arena's own
backend (`kit.fm.backends.Chronos2Backend`, chronos-forecasting 2.3.2) on

- every weekly case's context from `chronos-fm-chronos2-meter.json` (the
  meter path, B = V = 1), keeping every EVERY-th horizon step and the last;
- two of those contexts as one series of two variates (one group: the group
  attention mixes them), and as two independent series (B = 2), horizon 64.

    F=<this folder>
    cd research/arena
    HF_HUB_OFFLINE=1 uv run --extra fm python $F/chronos-generator.py \
        $F/chronos-fm-chronos2-meter.json $F/chronos-raw.json

Synthetic contexts only (the fixture's, `arena synth --seed 42`).
"""
from __future__ import annotations

import json
import sys

import numpy as np

from arena.cli_portfix import _arr
from kit.fm.backends import get_backend

WEIGHTS = "amazon/chronos-2@29ec3766d36d6f73f0696f85560a422f50e8498c"
EVERY = 10


def ctx_of(out: dict) -> np.ndarray:
    return np.asarray([np.nan if v is None else v for v in out["detail"]["context"]], dtype=np.float64)


def main(src: str, dst: str) -> int:
    fix = json.load(open(src))
    be = get_backend("chronos2", WEIGHTS, threads=4)
    weekly = []
    for out in fix["outputs"]:
        d = out["detail"]
        if d.get("flat") or "raw" in d or not d.get("horizon_steps"):
            continue
        h = int(d["horizon_steps"])
        levels, q = be.quantiles(ctx_of(out)[None, None, :], h)
        keep = sorted(set(range(0, h, EVERY)) | {h - 1})
        weekly.append({"case": out["case"], "horizon": h, "steps": keep, "raw": _arr(q[0, 0, keep])})
        print(out["case"], h, file=sys.stderr)
    two = [o for o in fix["outputs"] if o["case"] in ("c01", "c03")]
    a, b = ctx_of(two[0]), ctx_of(two[1])
    h = 64
    _, qmv = be.quantiles(np.stack([a, b])[None, :, :], h)          # one series, two variates
    _, qb = be.quantiles(np.stack([a, b])[:, None, :], h)           # two series
    steps = list(range(0, h, 4)) + [h - 1]
    doc = {"format": "pacer-chronos-raw/1", "weights": WEIGHTS, "levels": _arr(levels), "every": EVERY,
           "weekly": weekly,
           "multi": {"cases": ["c01", "c03"], "horizon": h, "steps": steps,
                     "multivariate": _arr(qmv[0][:, steps]), "batch": _arr(qb[:, 0][:, steps])}}
    open(dst, "w").write(json.dumps(doc, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
