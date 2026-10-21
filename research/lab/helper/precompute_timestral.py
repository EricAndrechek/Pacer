"""Precompute every Timestral size's answer at every past 5-hour cut, so the
app's full-history pass reads them instead of running four transformers
inside a 20-second request. Keyed by account and the cut instant to the
minute; lab_timestral.forecast() reads the cache first.

  research/lab/foundation/.venv/bin/python helper/precompute_timestral.py   (from research/lab)
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import lab  # noqa: E402
import lab_timestral as T  # noqa: E402
from lab_history import History  # noqa: E402
from lab_store import Store  # noqa: E402

SIZES = {"5M": 72, "28M": 72, "123M": 72, "209M": 288}
WEEKLY = {"5M": 28 * 96, "28M": 28 * 96}     # lab-ensemble-7d's two Timestral members
OUT = HERE / "cache" / "timestral.json"


def main():
    store = Store()
    c = lab.cases()
    c = c[c["window"] == "five_hour"].sort_values("t_cut")
    cache = json.loads(OUT.read_text()) if OUT.exists() else {}
    t0 = time.time()
    for n, r in enumerate(c.itertuples(index=False)):
        s = store.series("five_hour", r.account)
        h = History(window="five_hour", account=r.account, t_cut=r.t_cut, cycle_start=r.cycle_start,
                    resets_at=r.resets_at, duration=lab.WINDOWS["five_hour"], readings=s.until(r.t_cut))
        for size, steps in SIZES.items():
            key = T.cache_key(size, r.account, r.t_cut)
            if key not in cache:
                cache[key] = T.forecast(size, h, r.t_cut, r.resets_at, steps, use_cache=False)
        if n % 200 == 0:
            OUT.write_text(json.dumps(cache))
            print(f"{n}/{len(c)} {time.time() - t0:.0f}s", flush=True)
    w7 = lab.cases()
    w7 = w7[w7["window"] == "seven_day"].sort_values("t_cut")
    for r in w7.itertuples(index=False):
        s = store.series("seven_day", r.account)
        h = History(window="seven_day", account=r.account, t_cut=r.t_cut, cycle_start=r.cycle_start,
                    resets_at=r.resets_at, duration=lab.WINDOWS["seven_day"], readings=s.until(r.t_cut))
        for size, steps in WEEKLY.items():
            key = T.cache_key(size, r.account, r.t_cut, "seven_day")
            if key not in cache:
                cache[key] = T.forecast(size, h, r.t_cut, r.resets_at, steps, use_cache=False, step=900.0)
    OUT.write_text(json.dumps(cache))
    print(f"done {len(cache)} entries in {time.time() - t0:.0f}s", flush=True)


if __name__ == "__main__":
    main()
