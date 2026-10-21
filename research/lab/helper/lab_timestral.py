"""Mistral's Timestral (zero-shot time-series foundation model) as live
predictors, in the formulation research/lab/foundation used (issue #271):
the account's CUMULATIVE BURN on a 5-minute grid (meter increments summed
across cycles, never resetting; a gap over 2 h is missing, not flat), the
context ending at the cut, the median / q10 / q90 of the burn by the reset
added to the current reading.

Needs torch and `timestral`: run the helper on the foundation project's
Python (`LAB_HELPER_PYTHON=research/lab/foundation/.venv/bin/python make
lab-helper`). Weights load from the local Hugging Face cache, once per size.
"""
from __future__ import annotations

import bisect
import math
import os
import threading

STEP = 300.0          # 5-minute grid (5-hour window)
STALE = 2 * 3600.0
_MODELS: dict[str, object] = {}
_LOCK = threading.Lock()
_CUM: dict[tuple, tuple[list[float], list[float]]] = {}
_CACHE_FILE = __import__("pathlib").Path(__file__).resolve().parent / "cache" / "timestral.json"
_PRE: dict | None = None


def cache_key(size: str, account, t_cut: float, window: str = "five_hour") -> str:
    tag = "" if window == "five_hour" else f"{window}|"
    return f"{size}|{tag}{account or ''}|{round(t_cut / 60)}"


def _precomputed() -> dict:
    global _PRE
    if _PRE is None:
        import json
        _PRE = json.loads(_CACHE_FILE.read_text()) if _CACHE_FILE.exists() else {}
    return _PRE


def model(size: str):
    with _LOCK:
        if size not in _MODELS:
            import torch
            from timestral import TimestralForecaster
            torch.set_num_threads(int(os.environ.get("LAB_TORCH_THREADS", 4)))
            _MODELS[size] = TimestralForecaster.from_pretrained(f"mistralai/Timestral-{size}", local_files_only=True)
        return _MODELS[size]


def cumulative(history) -> tuple[list[float], list[float]]:
    """(times, cumulative burn) over this account's readings up to the cut.
    Causal, so a prefix computed for a later cut serves an earlier one."""
    key = (history.window, history.account)
    rs = history.readings
    cached = _CUM.get(key)
    if cached is not None and cached[0] and rs and cached[0][-1] >= rs[-1].t:
        return cached
    ats, cs = [], []
    c, prev_key, prev_used = 0.0, None, 0.0
    for r in rs:
        k = round(r.resets_at / 60.0) * 60.0
        if k == prev_key:
            if r.pct > prev_used:
                c += r.pct - prev_used
                prev_used = r.pct
        else:
            c += r.pct
            prev_key, prev_used = k, r.pct
        ats.append(r.t)
        cs.append(c)
    _CUM[key] = (ats, cs)
    return ats, cs


def forecast(size: str, history, t_cut: float, resets_at: float, context_steps: int, use_cache: bool = True,
             step: float = STEP):
    """(final, q10, q90) or None. Past cuts come from the precomputed cache
    (precompute_timestral.py) when it has them; the rest run the model."""
    if use_cache:
        hit = _precomputed().get(cache_key(size, history.account, t_cut, history.window))
        if hit is not None:
            return tuple(hit)
    import numpy as np
    ats, cs = cumulative(history)
    hi = bisect.bisect_right(ats, t_cut)
    if hi == 0:
        return None
    ats_a, cs_a = np.asarray(ats[:hi]), np.asarray(cs[:hi])
    t = t_cut - step * np.arange(context_steps - 1, -1, -1)
    idx = np.searchsorted(ats_a, t, side="right") - 1
    ok = idx >= 0
    ok[ok] &= (t[ok] - ats_a[idx[ok]]) <= STALE
    ctx = np.full(context_steps, np.nan, dtype=np.float32)
    ctx[ok] = cs_a[idx[ok]]
    if np.isnan(ctx[-1]):
        return None
    steps = (resets_at - t_cut) / step
    h = max(1, math.ceil(steps))
    fc = model(size)
    q = fc.forecast(ctx[None, :], prediction_length=h).quantiles.numpy()[0, 0]   # (H, Q)
    levels = np.asarray(fc.quantile_levels)
    i10, i50, i90 = (int(np.argmin(abs(levels - x))) for x in (0.1, 0.5, 0.9))
    c_last = float(ctx[-1])
    lo_i, hi_i = max(0, math.floor(steps) - 1), h - 1
    w = steps - math.floor(steps) if hi_i != lo_i else 0.0
    qh = q[lo_i] * (1 - w) + q[hi_i] * w if steps >= 1 else c_last + (q[0] - c_last) * steps
    burn = np.maximum(np.maximum.accumulate(qh - c_last), 0.0)
    cyc = history.cycle()
    used = cyc[-1].pct if cyc else 0.0
    out = (used + float(burn[i50]), used + float(burn[i10]), used + float(burn[i90]))
    # Kept for the next request: a live request also asks about recently
    # completed cycles the precompute never saw, and running four sizes over
    # them redone every refit overran the 1.2 s deadline each time.
    if use_cache:
        _precomputed()[cache_key(size, history.account, t_cut, history.window)] = list(out)
    return out
