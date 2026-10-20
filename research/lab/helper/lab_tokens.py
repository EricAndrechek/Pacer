"""Token spend for predictors: every Claude Code turn's API-equivalent cost
per account, from the live store (read-only) and Pacer's live price list.

The meter is driven by this spend (research/lab/tokens/FINDINGS.md): one
points-per-dollar factor per account explains the 5-hour meter's hourly rise
with R² ≈ 0.96 out of sample. Pacer records each turn as it happens, minutes
before the next meter poll.

NO PEEKING: every query takes the case's `t_cut` and is clipped to it; asking
for spend after the cut is clipped and asserted against.
"""
from __future__ import annotations

import bisect
import json
import sqlite3
import threading
import time
from pathlib import Path

GROUP = Path.home() / "Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer"
STORE = GROUP / "pacer.sqlite"
PRICES = GROUP / "litellm-pricing.cache.json"
EPOCH_2001 = 978_307_200
KINDS = {"ZINPUTTOKENS": "input_cost_per_token", "ZOUTPUTTOKENS": "output_cost_per_token",
         "ZCACHEREADTOKENS": "cache_read_input_token_cost",
         "ZCACHECREATION5MTOKENS": "cache_creation_input_token_cost",
         "ZCACHECREATION1HTOKENS": "cache_creation_input_token_cost_above_1hr"}


def _prices() -> dict[str, dict[str, float]]:
    d = json.loads(PRICES.read_text())
    d = d.get("entries", d)
    return {m: {k: float(e.get(v) or 0.0) for k, v in KINDS.items()}
            for m, e in d.items() if isinstance(e, dict) and m.startswith("claude-") and e.get("input_cost_per_token")}


class Ledger:
    """Cumulative cost per account, topped up from the store every 30 s."""

    def __init__(self, store: Path = STORE, top_up_s: float = 30.0):
        self.store, self.top_up_s = store, top_up_s
        self.prices = _prices()
        self.t: dict[str, list[float]] = {}
        self.cum: dict[str, list[float]] = {}
        self.last_raw = -1e18
        self.checked = 0.0
        self.lock = threading.Lock()
        self._load()

    def _price(self, model: str) -> dict[str, float] | None:
        p = self.prices.get(model)
        if p is None:
            hits = [k for k in self.prices if k in model]
            p = self.prices[max(hits, key=len)] if hits else None
        return p

    def _load(self) -> None:
        conn = sqlite3.connect(f"file:{self.store}?mode=ro", uri=True, timeout=5)
        try:
            rows = conn.execute(
                "SELECT ZSAMPLEDAT, ZACCOUNTID, ZMODEL, " + ", ".join(KINDS) +
                " FROM ZTOKENSAMPLE WHERE ZSAMPLEDAT > ? AND ZMODEL != '<synthetic>' ORDER BY ZSAMPLEDAT",
                (self.last_raw,)).fetchall()
        finally:
            conn.close()
        for raw, acct, model, *tok in rows:
            p = self._price(model or "")
            if p is None:
                continue
            cost = sum((n or 0) * p[k] for n, k in zip(tok, KINDS))
            a = acct or ""
            ts, cs = self.t.setdefault(a, []), self.cum.setdefault(a, [0.0])
            ts.append(raw + EPOCH_2001)
            cs.append(cs[-1] + cost)
            self.last_raw = max(self.last_raw, raw)
        self.checked = time.time()

    def _fresh(self) -> None:
        if time.time() - self.checked > self.top_up_s:
            with self.lock:
                if time.time() - self.checked > self.top_up_s:
                    self._load()

    def spent(self, account: str | None, t0: float, t1: float, t_cut: float) -> float:
        """API-equivalent $ spent by the account in (t0, t1], clipped to the cut."""
        self._fresh()
        t1 = min(t1, t_cut)
        if t1 <= t0:
            return 0.0
        ts, cs = self.t.get(account or "", []), self.cum.get(account or "", [0.0])
        return cs[bisect.bisect_right(ts, t1)] - cs[bisect.bisect_right(ts, t0)]


_LEDGER: Ledger | None = None


def ledger() -> Ledger:
    global _LEDGER
    if _LEDGER is None:
        _LEDGER = Ledger()
    return _LEDGER


def points_per_dollar(history, t_cut: float, days: float = 14.0) -> float | None:
    """The account's meter points per API $, from this window's reading intervals
    in the `days` before the start of the cut's day (refit daily). None when
    too little was spent to say."""
    led = ledger()
    hi = (t_cut // 86400) * 86400
    lo = hi - days * 86400
    rise = spent = 0.0
    prev = None
    for r in history.readings:
        if r.t > hi:
            break
        if prev is not None and r.t > lo and abs(r.resets_at - prev.resets_at) < history.duration / 2 \
                and r.pct >= prev.pct and 0 < r.t - prev.t < 3600:
            rise += r.pct - prev.pct
            spent += led.spent(history.account, prev.t, r.t, t_cut)
        prev = r
    return rise / spent if spent > 1.0 else None
