"""spend.hourly and tokens.hourly: several pretrained forecasters' paths
(children), combined by quantile averaging (Vincentization) at each hour.

Each child is a zero-shot forecaster with covariates (kit.fm.spend_model).
At every grid hour the children's sorted path values are averaged rank by rank
(weights from config), which keeps the members' common sharpness instead of
widening it as a linear pool would. The hour-to-hour dependence of the result
is the first child's: each output path takes, at every hour, the averaged
value at the rank its first-child path had there.
"""
from __future__ import annotations

import numpy as np

from arena.types import Forecast, Request, Target, TargetForecast

HOURLY = (Target.SPEND_HOURLY, Target.TOKENS_HOURLY)


def vincentize(paths: list[np.ndarray], weights: list[float], n: int, rng) -> np.ndarray:
    """[n_c, T] arrays -> [n, T]: rank-wise weighted average, the first
    member's ranks."""
    T = paths[0].shape[1]
    lv = (np.arange(n) + 0.5) / n
    avg = np.zeros((n, T))
    wsum = 0.0
    for P, w in zip(paths, weights):
        S = np.sort(np.asarray(P, dtype=np.float64), axis=0)
        m = S.shape[0]
        pos = lv * m - 0.5
        lo = np.clip(np.floor(pos).astype(int), 0, m - 1)
        hi = np.clip(lo + 1, 0, m - 1)
        f = np.clip(pos - lo, 0.0, 1.0)[:, None]
        avg += w * ((1 - f) * S[lo] + f * S[hi])
        wsum += w
    avg /= wsum
    P0 = np.asarray(paths[0], dtype=np.float64)
    m0 = P0.shape[0]
    # ranks of the first member's paths at each time, mapped onto n paths
    pick = np.linspace(0, m0 - 1, n).round().astype(int)
    P0 = P0[pick]
    ranks = np.argsort(np.argsort(P0 + rng.uniform(0, 1e-9, P0.shape), axis=0), axis=0)
    return np.take_along_axis(avg, ranks, axis=0)


def forecast_hourly(ctx, request, trs, cfg: dict, rng, log) -> dict:
    children = list(cfg.get("children", []))
    weights = [float(w) for w in cfg.get("weights", [1.0] * len(children))]
    sub = Request(request.now, request.scope, tuple(trs))
    got, ws = [], []
    for name, w in zip(children, weights):
        if w <= 0:
            continue
        try:
            got.append(ctx.model(name).forecast(sub))
            ws.append(w)
        except Exception as e:  # noqa: BLE001 - a failed child is left out, and said so
            log(f"child {name} failed: {type(e).__name__}: {str(e)[:200]}")
    out = {}
    for tr in trs:
        mem = [(f.by_key[tr.key].paths, w) for f, w in zip(got, ws) if tr.key in f.by_key]
        if not mem:
            out[tr.key] = TargetForecast.point(np.zeros(len(tr.grid)), tr.n_paths)
            continue
        P = vincentize([m[0] for m in mem], [m[1] for m in mem], tr.n_paths, rng)
        out[tr.key] = TargetForecast(np.maximum(P, 0.0))
    return out
