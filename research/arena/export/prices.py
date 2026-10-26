"""`prices`: every rate, from every source, on two time axes (spec §2.1).

- `t_effective_from` / `to` (and `t_event`): when the rate applied, as the
  source dates it. Backdated for curated and ledger rows.
- `t_known`: when Pacer could have known it. For the catalogs, the commit
  that introduced the rate plus Pacer's 24 h refresh; the catalogs are dated
  to the commit's UTC day, so the end of that day is used (an upper bound,
  never early). Curated rows: their review time. Ledger rows: `recordedAt`.
  Never `effectiveFrom`.

`t_effective_to` is written NULL (agreed with the synthetic generator): a
filled one would tell a model when the next price change comes. Each
effective period is still its own row; the rate in force at t, as known at
T, is the row with the latest `t_effective_from <= t` among rows with
`t_known <= T` (a correction beating the original, then the later
`t_known`). The exporter keeps the end internally (`eff_to_internal`) for
its own price gate.

Row semantics: `rate_per_mtok` is the standard-speed, global-region rate of
`part` above `tier_threshold` prompt tokens (null = the base tier).
`geo_mult` is the multiplier a regional request (`inference_geo` us/eu) pays
on it, `speed_mult` the one a fast-mode request pays; null where the source
offers none. A source record that carries explicit fast-mode rates is
exported under model `<model>:fast` with speed_mult 1.

Ledger rows come from provider `anthropic` only: Claude Code bills through
the Anthropic API here, and the schema has no provider column to keep
Bedrock/Vertex/Foundry rates apart.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from .clocks import DAY
from .util import ms

PARTS = {"input": "input", "output": "output", "cacheRead": "cache_read",
         "cacheWrite5m": "cache_write_5m", "cacheWrite1h": "cache_write_1h"}
TIERS = {"above200k": 200_000, "above100k": 100_000}
CATALOG_REFRESH_MS = DAY


def _catalog_rows(cand: dict | None) -> list[dict]:
    rows = []
    if not cand:
        return rows
    for m in cand.get("models", []):
        model = m.get("model")
        for src_key, source in (("litellm", "litellm"), ("modelsDev", "models_dev")):
            s = m.get(src_key) or {}
            periods = sorted(s.get("periods") or [], key=lambda p: (p["from"], p.get("commit") or ""))
            for i, p in enumerate(periods):
                start = ms(p["from"])
                end = ms(periods[i + 1]["from"]) if i + 1 < len(periods) else None
                known = start + DAY + CATALOG_REFRESH_MS
                geo = (p.get("multipliers") or {}).get("us")
                blocks = [(None, p.get("perMTok") or {})]
                for tk, thr in TIERS.items():
                    tb = (p.get("tiers") or {}).get(tk)
                    if tb:
                        blocks.append((thr, tb))
                for thr, rates in blocks:
                    for k, part in PARTS.items():
                        if rates.get(k) is None:
                            continue
                        rows.append(dict(model=model, part=part, tier_threshold=thr, geo_mult=geo, speed_mult=None,
                                         rate_per_mtok=float(rates[k]), source=source, commit_sha=p.get("commit"),
                                         t_effective_from=start, t_effective_to=end, t_known=known,
                                         is_correction=False))
    return rows


def _curated_rows(cur: dict | None, reviewed_ms: int | None) -> list[dict]:
    rows = []
    if not cur:
        return rows
    known = reviewed_ms if reviewed_ms is not None else ms(cur.get("asOf", "2026-10-21")) + DAY
    for r in cur.get("records", []):
        model = r["model"] + (":fast" if r.get("speed") == "fast" else "")
        start = ms(r["effectiveFrom"])
        end = ms(r["effectiveTo"]) if r.get("effectiveTo") else None
        for k, part in PARTS.items():
            v = (r.get("perMTok") or {}).get(k)
            if v is None:
                continue
            rows.append(dict(model=model, part=part, tier_threshold=r.get("tierAbovePromptTokens") or None,
                             geo_mult=r.get("regionalMultiplier"),
                             speed_mult=1.0 if r.get("speed") == "fast" else r.get("fastMultiplier"),
                             rate_per_mtok=float(v), source="curated", commit_sha=None,
                             t_effective_from=start, t_effective_to=end, t_known=known, is_correction=False))
    return rows


def _ledger_rows(pr: pd.DataFrame) -> list[dict]:
    rows = []
    if pr is None or pr.empty:
        return rows
    pr = pr[(pr["provider"].fillna("anthropic") == "anthropic")]
    pr = pr[pr["region"].isna() | (pr["region"] == "global")]
    for r in pr.itertuples(index=False):
        model = r.model + (":fast" if r.speed == "fast" else "")
        for col, part in (("input", "input"), ("output", "output"), ("cache_read", "cache_read"),
                          ("cache_write_5m", "cache_write_5m"), ("cache_write_1h", "cache_write_1h")):
            v = getattr(r, col)
            if v is None or pd.isna(v):
                continue
            rows.append(dict(model=model, part=part,
                             tier_threshold=None if pd.isna(r.tier) or int(r.tier) == 0 else int(r.tier),
                             geo_mult=None if pd.isna(r.regional_mult) else float(r.regional_mult),
                             speed_mult=1.0 if r.speed == "fast" else (None if pd.isna(r.fast_mult) else float(r.fast_mult)),
                             rate_per_mtok=float(v) * 1e6, source="ledger", commit_sha=None,
                             t_effective_from=None if pd.isna(r.eff_from) else int(r.eff_from),
                             t_effective_to=None if pd.isna(r.eff_to) else int(r.eff_to),
                             t_known=int(r.recorded_at), is_correction=False,
                             curated_src=bool(r.curated)))
    return rows


def build_prices(inp) -> pd.DataFrame:
    pr = inp.price_records
    reviewed = None
    if pr is not None and not pr.empty and pr["reviewed_at"].notna().any():
        reviewed = int(pr["reviewed_at"].dropna().max())
    rows = _catalog_rows(inp.price_candidate) + _curated_rows(inp.price_curated, reviewed) + _ledger_rows(pr)
    df = pd.DataFrame(rows, columns=["model", "part", "tier_threshold", "geo_mult", "speed_mult", "rate_per_mtok",
                                     "source", "commit_sha", "t_effective_from", "t_effective_to", "t_known",
                                     "is_correction", "curated_src"])
    df["curated_src"] = df["curated_src"].fillna(False).astype(bool)
    df = _flag_corrections(df)
    df["t_event"] = df["t_effective_from"]
    df["t_known_src"] = "observed"
    df["eff_to_internal"] = df["t_effective_to"]
    df["t_effective_to"] = None
    df["rate_per_mtok"] = df["rate_per_mtok"].round(9)
    df = df.sort_values(["t_known", "source", "model", "part", "tier_threshold", "t_effective_from", "commit_sha"],
                        na_position="first", kind="stable").reset_index(drop=True)
    return df.drop(columns=["curated_src"])


def _flag_corrections(df: pd.DataFrame) -> pd.DataFrame:
    """A curated (or curated-ledger) rate is a correction when, at its own
    effective date, the catalogs said something else for the same model,
    part and tier: those are the audit's fixes to what the catalogs knew."""
    cat = df[df["source"].isin(["litellm", "models_dev"])]
    idx = {}
    for r in cat.itertuples():
        idx.setdefault((r.model, r.part, r.tier_threshold if pd.notna(r.tier_threshold) else None), []).append(
            (r.t_effective_from, r.t_effective_to, r.rate_per_mtok, r.source))
    flags = []
    for r in df.itertuples():
        if not (r.source == "curated" or (r.source == "ledger" and r.curated_src)) or pd.isna(r.t_effective_from):
            flags.append(False)
            continue
        key = (r.model, r.part, r.tier_threshold if pd.notna(r.tier_threshold) else None)
        said = [rate for f, t, rate, src in sorted(idx.get(key, []), key=lambda x: x[3])
                if f <= r.t_effective_from and (t is None or pd.isna(t) or r.t_effective_from < t)]
        flags.append(bool(said) and not any(np.isclose(s, r.rate_per_mtok, rtol=1e-6) for s in said))
    df["is_correction"] = flags
    return df


def ledger_rate_lookup(prices: pd.DataFrame):
    """(canonical model) -> sorted [(from, to)] ledger periods for the base
    tier input rate: what gate 6 checks a turn against."""
    led = prices[(prices["source"] == "ledger") & (prices["part"] == "input") & prices["tier_threshold"].isna()]
    out: dict[str, list[tuple[int, int]]] = {}
    for r in led.itertuples():
        f = -(1 << 62) if pd.isna(r.t_effective_from) else int(r.t_effective_from)
        t = (1 << 62) if pd.isna(r.eff_to_internal) else int(r.eff_to_internal)
        out.setdefault(r.model, []).append((f, t))
    return out
