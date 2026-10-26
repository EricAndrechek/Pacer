"""Price a turns frame with the rates known at a moment, or with the final
rates. Cost is a view, never a stored column (docs/snapshot-spec.md §2.2).

- **As of T** (features, the kit): only price rows with `t_known <= T`. A
  price change lands when its catalog commit is known, never on its
  backdated effective date, so a model is never handed tomorrow's catalog.
  Inside a model, `history.table("prices")` is already as of `history.now`.
- **Final** (truth): every price row in the tier.

Which record prices a request (the snapshot's rule, shared with synth and
scoring):

1. **Key.** (model, part, prompt tier). Model ids are matched by a canonical
   form (lowercased, provider prefixes, `-v1:0`, `@date`, `-YYYYMMDD` and
   `[1m]` stripped).
2. **At time.** Among the rows (known by T), the one with the latest
   `t_effective_from <= t_event`: past usage is priced at the rate then in
   effect. `t_effective_to` is not used (snapshots leave it null: a filled one
   would date the next change).
3. **Ties.** At the same start, a correction (`is_correction`) beats the
   original, then the later `t_known` wins.
4. **No such row**, or no rate for a token part the request used: **null,
   never 0**, flagged `unpriced`.

Long context: the request's prompt is all its input (input + cache reads +
both cache writes), and the WHOLE request is priced at the highest tier whose
threshold the prompt exceeds and which has a record in effect.

Multipliers: `inference_geo` other than null/"global"/"" (data residency)
multiplies by the record's `geo_mult` (×1 when null).

Fast mode (`speed == "fast"`): a source that publishes explicit fast-mode
rates is exported under model `<model>:fast` (speed_mult 1; export/prices.py).
A fast request is priced at those rows wherever one is in effect at its time;
otherwise at the standard rate times the standard row's `speed_mult`; with
neither it is unpriced (`unpriced_fast`, never guessed at the standard rate).
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Literal

import numpy as np
import polars as pl

from arena.types import Millis

PARTS = ("input", "output", "cache_read", "cache_write_5m", "cache_write_1h")
GLOBAL_GEOS = frozenset({"global", ""})
SYNTHETIC_MODEL = "<synthetic>"

_PREFIXES = ("us.anthropic.", "eu.anthropic.", "apac.anthropic.", "global.anthropic.",
             "anthropic.", "anthropic/", "claude/")


FAST_SUFFIX = ":fast"


def canonical_model(model: str | None) -> str | None:
    if model is None:
        return None
    s = model.strip().lower()
    if s.endswith(FAST_SUFFIX):            # explicit fast-mode rate rows: canonical base + ":fast"
        base = canonical_model(s[: -len(FAST_SUFFIX)])
        return None if base is None else base + FAST_SUFFIX
    s = re.sub(r"\[1m\]$", "", s)
    for p in _PREFIXES:
        if s.startswith(p):
            s = s[len(p):]
    s = re.sub(r"-v\d+(:\d+)?$", "", s)
    s = re.sub(r"@\d{8}$", "", s)
    s = re.sub(r"-\d{8}$", "", s)
    return s


@dataclass(frozen=True)
class _Rec:
    frm: int
    known: int
    rate: float
    geo: float | None
    speed: float | None
    correction: bool

    def rank(self):
        return (self.frm, self.correction, self.known)


class _Timeline:
    """One key's rates as constant segments, one per distinct start: a
    binary search per request. Before the first start there is no rate."""

    def __init__(self, recs: list[_Rec]):
        best: dict[int, _Rec] = {}
        for r in recs:
            if r.frm not in best or r.rank() > best[r.frm].rank():
                best[r.frm] = r
        starts = sorted(best)
        chosen = [best[f] for f in starts]
        self.starts = np.asarray(starts, dtype=np.int64)
        self.rate = np.array([c.rate for c in chosen], dtype=np.float64)
        self.geo = np.array([np.nan if c.geo is None else c.geo for c in chosen])
        self.speed = np.array([np.nan if c.speed is None else c.speed for c in chosen])

    def at(self, t: np.ndarray):
        """(rate, geo_mult, speed_mult, found) at each time."""
        i = np.searchsorted(self.starts, t, side="right") - 1
        found = i >= 0
        j = np.where(found, i, 0)
        nan = np.full(len(t), np.nan)
        return (np.where(found, self.rate[j], nan), np.where(found, self.geo[j], nan),
                np.where(found, self.speed[j], nan), found)


def _timelines(prices: pl.DataFrame) -> dict[tuple[str, str, int], _Timeline]:
    df = prices.select(
        pl.col("model"), pl.col("part"), pl.col("tier_threshold").fill_null(0).alias("tier"),
        pl.col("t_effective_from").dt.epoch("ms").alias("frm"),
        pl.col("t_known").dt.epoch("ms").alias("known"),
        pl.col("rate_per_mtok").alias("rate"), pl.col("geo_mult").alias("geo"),
        pl.col("speed_mult").alias("speed"),
        pl.col("is_correction").fill_null(False).alias("corr"),
    ).filter(pl.col("rate").is_not_null() & pl.col("frm").is_not_null() & pl.col("part").is_in(list(PARTS)))
    groups: dict[tuple[str, str, int], list[_Rec]] = {}
    for r in df.iter_rows(named=True):
        key = (canonical_model(r["model"]), r["part"], int(r["tier"]))
        groups.setdefault(key, []).append(_Rec(int(r["frm"]), int(r["known"]), float(r["rate"]),
                                                r["geo"], r["speed"], bool(r["corr"])))
    return {k: _Timeline(v) for k, v in groups.items()}


def output_tokens(turns: pl.DataFrame, output: Literal["raw", "best"]) -> pl.Expr:
    """`raw`: the recorded output. `best`: the imputed value where the
    recorded one is known to be unreliable and an imputation exists (it is
    already null in a view until its own t_known)."""
    if output == "raw":
        return pl.col("output").cast(pl.Float64)
    return (pl.when((pl.col("output_reliable") == False) & pl.col("output_imputed").is_not_null())  # noqa: E712
            .then(pl.col("output_imputed")).otherwise(pl.col("output").cast(pl.Float64)))


def price_turns(turns: pl.DataFrame, prices: pl.DataFrame, *, as_of: Millis | None = None,
                output: Literal["raw", "best"] = "raw") -> pl.DataFrame:
    """`turns` with `cost_usd` (Float64; null when no rate was known) and
    `price_flag` (ok | unpriced | unpriced_fast) appended, in the
    same row order. `as_of=None` prices with every row of `prices` (final)."""
    if as_of is not None:
        prices = prices.filter(pl.col("t_known").dt.epoch("ms") <= as_of)
    tl = _timelines(prices)
    n = turns.height
    tok = turns.select(
        pl.col("t_event").dt.epoch("ms").alias("t"),
        pl.col("model"),
        pl.col("input").cast(pl.Float64).alias("input"),
        output_tokens(turns, output).alias("output"),
        pl.col("cache_read").cast(pl.Float64).alias("cache_read"),
        pl.col("cache_write_5m").cast(pl.Float64).alias("cache_write_5m"),
        pl.col("cache_write_1h").cast(pl.Float64).alias("cache_write_1h"),
        pl.col("inference_geo"), pl.col("speed"),
    )
    cost = np.full(n, np.nan)
    flag = np.full(n, "unpriced", dtype=object)
    t_all = tok["t"].to_numpy().astype(np.int64) if n else np.zeros(0, np.int64)
    models = tok["model"].to_list()
    canon = np.array([canonical_model(m) if m is not None else None for m in models], dtype=object)
    parts = {p: tok[p].fill_null(np.nan).to_numpy().astype(np.float64) for p in PARTS}
    prompt = parts["input"] + parts["cache_read"] + parts["cache_write_5m"] + parts["cache_write_1h"]
    geo = np.array([g is not None and g not in GLOBAL_GEOS for g in tok["inference_geo"].to_list()], dtype=bool)
    fast = np.array([s == "fast" for s in tok["speed"].to_list()], dtype=bool)
    # Fast requests go to the model's ":fast" rows where one is in effect;
    # those rows are already the fast rate, so no speed multiplier applies.
    key = canon.copy()
    for fm in {k[0] for k in tl if k[0] and k[0].endswith(FAST_SUFFIX)}:
        base = fm[: -len(FAST_SUFFIX)]
        sel = np.flatnonzero(fast & (canon == base))
        if not len(sel) or (fm, "input", 0) not in tl:
            continue
        _, _, _, found = tl[(fm, "input", 0)].at(t_all[sel])
        key[sel[found]] = fm
    fast = fast & ~np.array([k is not None and k.endswith(FAST_SUFFIX) for k in key], dtype=bool)
    by_model: dict[str, list[int]] = {}
    for i, m in enumerate(key):
        if m is not None and models[i] != SYNTHETIC_MODEL:
            by_model.setdefault(m, []).append(i)
    tiers_of: dict[str, list[int]] = {}
    for (m, _, tier) in tl:
        if tier:
            tiers_of.setdefault(m, []).append(tier)
    for m, idx_list in by_model.items():
        idx = np.asarray(idx_list)
        if (m, "input", 0) not in tl and not any(k[0] == m for k in tl):
            continue
        t = t_all[idx]
        tier = np.zeros(len(idx), dtype=np.int64)
        undecided = np.ones(len(idx), dtype=bool)
        for thr in sorted(set(tiers_of.get(m, [])), reverse=True):
            k = (m, "input", thr)
            if k not in tl:
                continue
            _, _, _, found = tl[k].at(t)
            ok = undecided & (prompt[idx] > thr) & found
            tier[ok] = thr
            undecided &= ~ok
        total = np.zeros(len(idx))
        missing = np.zeros(len(idx), dtype=bool)
        gmult = np.full(len(idx), np.nan)
        smult = np.full(len(idx), np.nan)
        for thr in np.unique(tier):
            sel = tier == thr
            for p in PARTS:
                k = (m, p, int(thr))
                n_tok = parts[p][idx[sel]]
                if k not in tl:
                    missing[np.flatnonzero(sel)[(n_tok != 0) | np.isnan(n_tok)]] = True
                    continue
                rate, g, s, found = tl[k].at(t[sel])
                total[sel] += np.where(n_tok == 0, 0.0, n_tok * rate / 1e6)
                missing[sel] |= np.isnan(n_tok) | (~found & (n_tok != 0))
                if p == "input":
                    gmult[sel], smult[sel] = g, s
        mult = np.where(geo[idx], np.where(np.isnan(gmult), 1.0, gmult), 1.0)
        fast_unpriced = fast[idx] & np.isnan(smult)
        mult = mult * np.where(fast[idx], smult, 1.0)       # NaN (unpriced) without a fast multiplier
        c = total * mult
        c[missing] = np.nan
        cost[idx] = c
        flag[idx] = np.where(missing, "unpriced", np.where(fast_unpriced, "unpriced_fast", "ok"))
    return turns.with_columns(
        pl.Series("cost_usd", cost, dtype=pl.Float64).fill_nan(None),
        pl.Series("price_flag", flag.tolist(), dtype=pl.String),
    )


def turns_costed(history, *, output: Literal["raw", "best"] = "raw") -> pl.DataFrame:
    """A model's own history priced as it would have been at `history.now`."""
    return price_turns(history.table("turns"), history.table("prices"), as_of=history.now, output=output)
