#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Merge the price catalogs on our side and publish one dated list (#469).

Every Pacer used to fetch LiteLLM (~5 MB), models.dev and Catwalk itself,
merge them, and date each catalog price from whenever *that Mac* first saw
it. This job does the merge once, on a schedule, and records the result in
the price history the app already fetches (site/public/price-history.json),
under a `catalog` section of dated records:

    "catalog": {
      "changedAt": "…",   # when a record was last added or closed
      "checkedAt": "…",   # when the job last confirmed the section (heartbeat)
      "records": [ {model, provider, region, effectiveFrom, effectiveTo,
                    perMTok, derived?, fastMultiplier?, regionalMultiplier?,
                    source, tierAbovePromptTokens?}, … ] }

The merge is a port of the app's, rule for rule, so the list says what an
up-to-date Mac would have computed:

  * `PricingTable.refresh` / `reconcile`: LiteLLM is the primary table, and
    models.dev's and Catwalk's `anthropic` entries vote on the four cost
    fields (a strict majority wins, even against LiteLLM) or fill models
    LiteLLM lacks;
  * `PricingTable.decode`: an entry with a non-number cost field, or no cost
    above zero, is dropped;
  * `CanonicalModelID.parse` and `PricingCatalogIndex`: every spelling of a
    model reduces to (model, provider, region), and one catalog key per
    identity is chosen by a total order;
  * `PriceLedger.catalogTemplates`: every `claude-*` identity on the Claude
    API, Bedrock, Vertex or Foundry, a base record plus one per prompt-size
    tier, unpublished cache-write rates derived (5m 1.25x, 1h 2x input);
  * `PriceLedgerStore.sync` (the catalog half): a record is opened at the
    job's observation time only when a rate vector changes (the open one is
    closed at that instant), and a vector's first record starts at its
    curated start date when the curated history has one.

`PricingCatalogParityTests` (PacerCoreTests) runs this script's `templates`
command and the app's own merge over the same inputs and requires the same
records, so the two cannot drift apart unnoticed.

What it never does: touch the curated `records`, the top-level `asOf` (the
app reads it as every curated row's review date), or any record it wrote
before beyond closing it. A model that leaves every catalog keeps its last
record open, as on a Mac. Which record prices a request (curated beats
catalog, except a catalog change after the curated review) stays the app's
call, in `PriceLedger.precedence`; the file carries both, labelled.

Commands:

    uv run bin/price-catalog-sync.py sync [--dry-run] [--file F] [--now ISO]
        [--litellm F --models-dev F --catwalk F] [--accept-mass-change]
        [--summary F]
    uv run bin/price-catalog-sync.py templates --litellm F --models-dev F --catwalk F
    uv run bin/price-catalog-sync.py graft --release R --site S --out O

`sync` exits 0 when it wrote the file (or, with --dry-run, would have) or
found nothing to change, and 1 when a catalog is unusable or a run looks
wrong: it then writes nothing. Stdlib only; `python3 -I` runs it too.
"""
from __future__ import annotations

import argparse
import copy
import json
import math
import re
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SITE_FILE = ROOT / "site/public/price-history.json"

# The URLs the app reads (PricingTable.liteLLMURL, ModelsDevCatalog.url,
# CatwalkCatalog.url).
LITELLM_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
MODELS_DEV_URL = "https://models.dev/api.json"
CATWALK_URL = "https://raw.githubusercontent.com/charmbracelet/catwalk/main/internal/providers/configs/anthropic.json"
UA = "pacer-price-catalog-sync (+https://github.com/EricAndrechek/Pacer)"

# The section is re-confirmed at least this often even when nothing changed,
# so a Mac can tell a quiet week from a broken job (`checkedAt`; the app
# falls back to the catalogs when it is older than 10 days,
# `PriceSources.listStaleAfter`).
HEARTBEAT = timedelta(days=7)

# Garbage guards. A run that would close more than this share of the open
# records at once, or move any rate by more than this factor, is refused:
# a unit slip or a broken upstream commit must not become permanent history.
MASS_CHANGE_SHARE = 0.25
MAX_FACTOR = 10.0
# The least a healthy catalog yields (LiteLLM: tracked Claude identities;
# the others: Anthropic entries). Well under today's counts.
MIN_LITELLM_IDS = 40
MIN_SECONDARY_ENTRIES = 5

PROVIDERS = ("anthropic", "bedrock", "vertex", "foundry", "other")
REGIONS = ("global", "us", "us-gov", "eu", "apac")
SOURCES = ("curated", "litellm", "models.dev", "catwalk", "fallback")
RATE_KEYS = ("input", "output", "cacheWrite5m", "cacheWrite1h", "cacheRead")


class SyncError(Exception):
    """A run that must write nothing and fail the workflow."""


# --------------------------------------------------------------- numbers

def ns_number(v) -> float | None:
    """`(v as? NSNumber)?.doubleValue`: JSON booleans are NSNumbers too."""
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    return None


def ns_int(v) -> int | None:
    """`(v as? NSNumber)?.intValue`: truncates."""
    n = ns_number(v)
    return None if n is None or not math.isfinite(n) else int(n)


# ------------------------------------------------- CanonicalModelID.parse

BEDROCK_GEO = (("us-gov.", "us-gov"), ("global.", "global"), ("apac.", "apac"),
               ("us.", "us"), ("eu.", "eu"), ("jp.", "apac"), ("au.", "apac"))
_V_SUFFIX = re.compile(r"-v\d+(:\d+)?$")
_DATE_PIN = re.compile(r"-\d{8}$")
_PARSE_CACHE: dict[str, tuple[str, str, str]] = {}


def parse_id(raw: str) -> tuple[str, str, str]:
    """(model, provider, region), exactly as `CanonicalModelID.uncachedParse`."""
    hit = _PARSE_CACHE.get(raw)
    if hit is not None:
        return hit
    s = raw.strip().lower()
    if "[" in s:
        s = s[:s.index("[")]
    provider, region = "anthropic", "global"
    if s.startswith("anthropic/"):
        s = s[len("anthropic/"):]
    elif s.startswith("vertex_ai/"):
        provider, s = "vertex", s[len("vertex_ai/"):]
    elif s.startswith("azure_ai/"):
        provider, s = "foundry", s[len("azure_ai/"):]
    elif s.startswith("bedrock/"):
        provider, s = "bedrock", s[len("bedrock/"):]
        if "/" in s:
            aws, s = s.split("/", 1)
            region = ("us-gov" if aws.startswith("us-gov") else "us" if aws.startswith("us-")
                      else "eu" if aws.startswith("eu-") else "apac" if aws.startswith("ap-")
                      else "global")
    if "/" in s:
        out = (s, "other", "global")
        _PARSE_CACHE[raw] = out
        return out
    for prefix, geo in BEDROCK_GEO:
        if s.startswith(prefix + "anthropic."):
            provider, region = "bedrock", geo
            s = s[len(prefix) + len("anthropic."):]
            break
    if s.startswith("anthropic."):
        provider, s = "bedrock", s[len("anthropic."):]
    if "@" in s:
        if provider == "anthropic":
            provider = "vertex"
        s = s[:s.index("@")]
    if (m := _V_SUFFIX.search(s)):
        if provider == "anthropic":
            provider = "bedrock"
        s = s[:m.start()]
    if (m := _DATE_PIN.search(s)):
        s = s[:m.start()]
    out = (s, provider, region)
    _PARSE_CACHE[raw] = out
    return out


def version_complete_prefix(model: str, other: str) -> bool:
    """`CanonicalModelID.isVersionCompletePrefix(of:)`."""
    if len(other) <= len(model) or not other.startswith(model):
        return False
    rest = other[len(model):]
    if rest[0] != "-" or len(rest) < 2:
        return False
    return not rest[1].isnumeric()


# ---------------------------------------------------- PricingCatalogIndex

class CatalogIndex:
    """`PricingCatalogIndex`: one key per identity, by a total order."""

    def __init__(self, keys):
        best: dict[tuple, str] = {}
        for key in keys:
            ident = parse_id(key)
            cur = best.get(ident)
            if cur is None or self._ranks(key, cur, ident):
                best[ident] = key
        self.key_by_id = best
        cands: dict[tuple, list] = {}
        for ident in best:
            cands.setdefault((ident[1], ident[2]), []).append(ident)
        for v in cands.values():
            v.sort(key=lambda i: (-len(i[0]), i[0]))
        self.prefix = cands

    @staticmethod
    def _ranks(a: str, b: str, ident: tuple) -> bool:
        a_plain, b_plain = a.lower() == ident[0], b.lower() == ident[0]
        if a_plain != b_plain:
            return a_plain
        if len(a) != len(b):
            return len(a) < len(b)
        return a < b

    def entries(self) -> list[tuple[tuple, str]]:
        return sorted(self.key_by_id.items(), key=lambda kv: kv[1])

    def match_key(self, raw: str) -> str | None:
        ident = parse_id(raw)
        if ident in self.key_by_id:
            return self.key_by_id[ident]
        for cand in self.prefix.get((ident[1], ident[2]), []):
            if version_complete_prefix(cand[0], ident[0]):
                return self.key_by_id[cand]
        if ident[1] != "anthropic" or ident[2] != "global":
            return None
        for provider in ("vertex", "foundry", "bedrock"):
            k = self.key_by_id.get((ident[0], provider, "global"))
            if k is not None:
                return k
        return None


# ------------------------------------------------- LiteLLMModelPricing

DOUBLE_FIELDS = (
    "input_cost_per_token", "output_cost_per_token",
    "cache_creation_input_token_cost", "cache_creation_input_token_cost_above_1hr",
    "cache_read_input_token_cost",
    "input_cost_per_token_above_200k_tokens", "output_cost_per_token_above_200k_tokens",
    "cache_creation_input_token_cost_above_200k_tokens", "cache_read_input_token_cost_above_200k_tokens",
    "cache_creation_input_token_cost_above_1hr_above_200k_tokens",
    "input_cost_per_token_above_100k_tokens", "output_cost_per_token_above_100k_tokens",
    "cache_creation_input_token_cost_above_100k_tokens", "cache_read_input_token_cost_above_100k_tokens",
)
INT_FIELDS = ("max_input_tokens", "max_output_tokens")
USABLE = ("input_cost_per_token", "output_cost_per_token",
          "cache_creation_input_token_cost", "cache_read_input_token_cost")


def decode_entry(value) -> dict | None:
    """One catalog row as `JSONDecoder` reads `LiteLLMModelPricing`, or None
    when it would be dropped (a field of the wrong type fails the whole row;
    no cost above zero is a placeholder)."""
    if not isinstance(value, dict):
        return None
    out: dict = {}
    for f in DOUBLE_FIELDS:
        v = value.get(f)
        if v is None:
            out[f] = None
        elif isinstance(v, bool) or not isinstance(v, (int, float)):
            return None
        else:
            out[f] = float(v)
    for f in INT_FIELDS:
        v = value.get(f)
        if v is None:
            continue
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            return None
        if isinstance(v, float) and not v.is_integer():
            return None
    src = value.get("pacer_source")
    if src is not None and not isinstance(src, str):
        return None
    out["pacer_source"] = src
    pse = value.get("provider_specific_entry")
    nums = {}
    if isinstance(pse, dict):
        for k, v in pse.items():
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                nums[k] = float(v)
    out["provider_specific_entry"] = nums
    if not any((out[f] or 0) > 0 for f in USABLE):
        return None
    return out


def decode_table(raw: dict) -> dict[str, dict]:
    """`PricingTable.decode(json:)`."""
    return {k: e for k, v in raw.items() if k != "sample_spec" and (e := decode_entry(v)) is not None}


# ------------------------------------------- models.dev and Catwalk adapters

def models_dev_entries(root) -> dict[str, dict]:
    """`ModelsDevCatalog.anthropicEntries`."""
    if not isinstance(root, dict) or not isinstance(root.get("anthropic"), dict):
        return {}
    models = root["anthropic"].get("models")
    if not isinstance(models, dict):
        return {}
    out = {}
    for mid, model in models.items():
        if not isinstance(model, dict) or not isinstance(model.get("cost"), dict):
            continue
        cost = model["cost"]

        def per_token(k):
            v = ns_number(cost.get(k))
            return v / 1_000_000 if v is not None and v > 0 else None

        entry = {}
        for src, dst in (("input", "input_cost_per_token"), ("output", "output_cost_per_token"),
                         ("cache_read", "cache_read_input_token_cost"),
                         ("cache_write", "cache_creation_input_token_cost")):
            if (v := per_token(src)) is not None:
                entry[dst] = v
        if not entry:
            continue
        limit = model.get("limit")
        if isinstance(limit, dict):
            if (c := ns_int(limit.get("context"))) is not None:
                entry["max_input_tokens"] = c
            if (o := ns_int(limit.get("output"))) is not None:
                entry["max_output_tokens"] = o
        out[mid] = entry
    return out


def catwalk_entries(root) -> dict[str, dict]:
    """`CatwalkCatalog.anthropicEntries`. Two shapes: the flat one, where
    `cost_per_1m_in_cached` is the cache WRITE rate and
    `cost_per_1m_out_cached` the READ rate, and the `pricing` object Catwalk
    moved to (input, output, cache_create = 5m write, cache_hit = read)."""
    if not isinstance(root, dict) or not isinstance(root.get("models"), list):
        return {}
    out = {}
    for model in root["models"]:
        if not isinstance(model, dict):
            continue
        mid = model.get("id")
        if not isinstance(mid, str) or not mid:
            continue

        pricing = model.get("pricing") if isinstance(model.get("pricing"), dict) else {}

        def per_token(flat, nested):
            v = ns_number(model[flat] if flat in model else pricing.get(nested))
            return v / 1_000_000 if v is not None and v > 0 else None

        entry = {}
        for flat, nested, dst in (("cost_per_1m_in", "input", "input_cost_per_token"),
                                  ("cost_per_1m_out", "output", "output_cost_per_token"),
                                  ("cost_per_1m_in_cached", "cache_create", "cache_creation_input_token_cost"),
                                  ("cost_per_1m_out_cached", "cache_hit", "cache_read_input_token_cost")):
            if (v := per_token(flat, nested)) is not None:
                entry[dst] = v
        if not entry:
            continue
        if (c := ns_int(model.get("context_window"))) is not None:
            entry["max_input_tokens"] = c
        if (o := ns_int(model.get("default_max_tokens"))) is not None:
            entry["max_output_tokens"] = o
        out[mid] = entry
    return out


# ------------------------------------------------ PricingTable.reconcile

COST_FIELDS = ("input_cost_per_token", "output_cost_per_token",
               "cache_creation_input_token_cost", "cache_read_input_token_cost")


def reconcile(secondaries: list[tuple[str, dict | None]], raw: dict, covered: dict) -> dict:
    """Per-field consensus, exactly as `PricingTable.reconcile`."""
    merged = dict(raw)
    ids = sorted({k for _, entries in secondaries for k in (entries or {})})
    index = CatalogIndex(covered.keys())
    for mid in ids:
        primary_key = index.match_key(mid)
        primary = merged.get(primary_key) if primary_key is not None else None
        if not isinstance(primary, dict):
            primary = None
        winner = dict(primary) if primary else {}
        changed = False
        for field in COST_FIELDS:
            votes = []
            pv = ns_number(primary.get(field)) if primary else None
            if pv is not None and pv > 0:
                votes.append(("litellm", pv))
            for name, entries in secondaries:
                v = ns_number(((entries or {}).get(mid) or {}).get(field))
                if v is not None and v > 0:
                    votes.append((name, v))
            if not votes:
                continue
            tally: list[list] = []
            for _, v in votes:
                for t in tally:
                    if abs(t[0] - v) < 1e-12:
                        t[1] += 1
                        break
                else:
                    tally.append([v, 1])
            best = max(tally, key=lambda t: t[1])  # the first of equals, as Swift's max(by:)
            majority = best[1] * 2 > len(votes)
            primary_value = ns_number(primary.get(field)) if primary else None
            if len(tally) == 1 or majority:
                current = ns_number(winner[field]) if field in winner else None
                if field not in winner or abs((math.nan if current is None else current) - best[0]) >= 1e-12:
                    winner[field] = best[0]
                    changed = True
            elif primary_value is not None:
                winner[field] = primary_value
            else:
                winner[field] = votes[0][1]
                changed = True
        if not winner:
            continue
        for field in ("max_input_tokens", "max_output_tokens"):
            if field not in winner:
                for _, entries in secondaries:
                    row = (entries or {}).get(mid)
                    if row is not None and field in row:
                        winner[field] = row[field]
                        break
        if primary_key is not None:
            if changed:
                merged[primary_key] = winner
        else:
            for name, entries in secondaries:
                if (entries or {}).get(mid) is not None:
                    winner["pacer_source"] = name
                    break
            merged[mid] = winner
    return merged


# ------------------------------------------- PriceLedger.catalogTemplates

def tracked(ident: tuple) -> bool:
    return ident[1] != "other" and ident[0].startswith("claude-")


def templates_for(ident: tuple, p: dict, source: str) -> list[dict]:
    """`PriceLedger.templates(for:pricing:source:)`: per-token rates."""
    fast = p["provider_specific_entry"].get("fast")
    regional = p["provider_specific_entry"].get("us")

    def rates(i, o, read, w5m, w1h):
        i0 = i if i is not None else 0.0
        derived = []
        if w5m is None:
            derived.append("cacheWrite5m")
        if w1h is None:
            derived.append("cacheWrite1h")
        return {"input": i0, "output": o if o is not None else 0.0,
                "cacheRead": read if read is not None else 0.0,
                "cacheWrite5m": w5m if w5m is not None else i0 * 1.25,
                "cacheWrite1h": w1h if w1h is not None else i0 * 2}, derived

    def record(tier, r):
        return {"model": ident[0], "provider": ident[1], "region": ident[2], "tier": tier,
                "rates": r[0], "derived": r[1], "fast": fast, "regional": regional,
                "source": source}

    base = record(0, rates(p["input_cost_per_token"], p["output_cost_per_token"],
                           p["cache_read_input_token_cost"], p["cache_creation_input_token_cost"],
                           p["cache_creation_input_token_cost_above_1hr"]))
    out = [base]
    b = base["rates"]
    for threshold, i, o, read, w5m, w1h in (
        (100_000, p["input_cost_per_token_above_100k_tokens"], p["output_cost_per_token_above_100k_tokens"],
         p["cache_read_input_token_cost_above_100k_tokens"],
         p["cache_creation_input_token_cost_above_100k_tokens"], None),
        (200_000, p["input_cost_per_token_above_200k_tokens"], p["output_cost_per_token_above_200k_tokens"],
         p["cache_read_input_token_cost_above_200k_tokens"],
         p["cache_creation_input_token_cost_above_200k_tokens"],
         p["cache_creation_input_token_cost_above_1hr_above_200k_tokens"]),
    ):
        if not any((x or 0) > 0 for x in (i, o, read, w5m)):
            continue
        ti = i if i is not None else b["input"]
        out.append(record(threshold, rates(ti, o if o is not None else b["output"],
                                           read if read is not None else b["cacheRead"], w5m, w1h)))
    return out


def merge_catalogs(litellm_raw, models_dev_raw, catwalk_raw, guard: bool = True) -> list[dict]:
    """What `PricingTable.refresh` + `PriceLedger.catalogTemplates` produce
    from the three payloads, minus the app's built-in fallback rows (those
    stay in the app: they cover only what no catalog lists). Raises SyncError
    on a payload the app would refuse or, with `guard`, one that looks broken
    (`templates`, the parity tool, runs unguarded on small fixtures)."""
    if not isinstance(litellm_raw, dict):
        raise SyncError("LiteLLM: not a JSON object")
    lite = decode_table(litellm_raw)
    if not lite:
        raise SyncError("LiteLLM: no usable entries")
    md = models_dev_entries(models_dev_raw)
    cw = catwalk_entries(catwalk_raw)
    # The app treats a secondary that fails as missing and merges without it;
    # here that would flip consensus votes for one run and write the flip
    # into history for good, so a missing source stops the run instead.
    if guard and len(md) < MIN_SECONDARY_ENTRIES:
        raise SyncError(f"models.dev: {len(md)} Anthropic entries (expected at least {MIN_SECONDARY_ENTRIES})")
    if guard and len(cw) < MIN_SECONDARY_ENTRIES:
        raise SyncError(f"Catwalk: {len(cw)} Anthropic entries (expected at least {MIN_SECONDARY_ENTRIES})")
    merged = decode_table(reconcile([("models.dev", md), ("catwalk", cw)], litellm_raw, lite))
    out = []
    for ident, key in CatalogIndex(merged.keys()).entries():
        if not tracked(ident):
            continue
        p = merged[key]
        src = p["pacer_source"] if p["pacer_source"] in SOURCES else "litellm"
        out.extend(templates_for(ident, p, src))
    n_ids = len({(t["model"], t["provider"], t["region"]) for t in out if t["source"] == "litellm"})
    if guard and n_ids < MIN_LITELLM_IDS:
        raise SyncError(f"LiteLLM: {n_ids} Claude identities (expected at least {MIN_LITELLM_IDS})")
    out.sort(key=slot_order)
    return out


# ----------------------------------------------------------- the file

def parse_date(s: str) -> datetime:
    """`CuratedPriceHistory.date`: YYYY-MM-DD (UTC midnight) or ISO 8601."""
    if not isinstance(s, str):
        raise SyncError(f"not a date: {s!r}")
    try:
        if len(s) == 10:
            return datetime.strptime(s, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError as e:
        raise SyncError(f"not a date: {s!r}") from e
    if d.tzinfo is None:
        raise SyncError(f"a date with no time zone: {s!r}")
    return d.astimezone(timezone.utc)


def fmt_date(d: datetime) -> str:
    d = d.astimezone(timezone.utc).replace(microsecond=0)
    if d.hour == d.minute == d.second == 0:
        return d.strftime("%Y-%m-%d")
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def per_mtok(v: float) -> float:
    """Per-token to the file's per-MTok, rounded far below the app's 1e-15
    per-token comparison so a value reads as `3`, not `3.0000000000000004`."""
    x = round(v * 1_000_000, 10)
    return int(x) if x == int(x) and abs(x) < 1e15 else x


def slot_of(r: dict) -> tuple:
    return (r["model"], r["provider"], r["region"], "standard", int(r.get("tier") or 0))


def slot_order(r: dict) -> tuple:
    return slot_of(r) + (r.get("from_ts", 0),)


def row_to_internal(row: dict) -> dict:
    """A `catalog.records` row as the job works with it (per-token rates)."""
    rates = {k: float(row["perMTok"][k]) / 1_000_000 for k in RATE_KEYS}
    frm = parse_date(row["effectiveFrom"])
    to = parse_date(row["effectiveTo"]) if row.get("effectiveTo") else None
    return {"model": row["model"], "provider": row.get("provider", "anthropic"),
            "region": row.get("region", "global"), "tier": int(row.get("tierAbovePromptTokens") or 0),
            "rates": rates, "derived": list(row.get("derived") or []),
            "fast": row.get("fastMultiplier"), "regional": row.get("regionalMultiplier"),
            "source": row.get("source", "litellm"), "from": frm, "to": to,
            "from_ts": frm.timestamp(), "row": row}


def internal_to_row(r: dict) -> dict:
    row = {"model": r["model"], "provider": r["provider"], "region": r["region"]}
    if r["tier"]:
        row["tierAbovePromptTokens"] = r["tier"]
    row["effectiveFrom"] = fmt_date(r["from"])
    row["effectiveTo"] = fmt_date(r["to"]) if r["to"] else None
    row["perMTok"] = {k: per_mtok(r["rates"][k]) for k in RATE_KEYS}
    if r["derived"]:
        row["derived"] = sorted(r["derived"])
    if r["fast"] is not None:
        row["fastMultiplier"] = r["fast"]
    if r["regional"] is not None:
        row["regionalMultiplier"] = r["regional"]
    row["source"] = r["source"]
    return row


def same_price(a: dict, b: dict) -> bool:
    """`PriceRecordValue.samePrice`: the five rates within 1e-15 per token,
    and the same fast and regional multipliers."""
    return (all(abs(a["rates"][k] - b["rates"][k]) < 1e-15 for k in RATE_KEYS)
            and a["fast"] == b["fast"] and a["regional"] == b["regional"])


def curated_starts(records: list) -> dict[tuple, datetime]:
    """Each curated slot's earliest start (`PriceLedgerStore`'s curatedStart)."""
    out: dict[tuple, datetime] = {}
    for r in records:
        slot = (r["model"].lower(), r.get("provider") or "anthropic", r.get("region") or "global",
                r.get("speed") or "standard", int(r.get("tierAbovePromptTokens") or 0))
        d = parse_date(r["effectiveFrom"])
        out[slot] = min(out.get(slot, d), d)
    return out


def fold(existing: list[dict], templates: list[dict], curated: list, now: datetime):
    """`PriceLedgerStore.sync`'s catalog half over the published records.
    Returns (records, opened, closed)."""
    records = [dict(r) for r in existing]
    by_slot: dict[tuple, list[dict]] = {}
    for r in records:
        by_slot.setdefault(slot_of(r), []).append(r)
    starts = curated_starts(curated)
    opened, closed = [], []
    for t in templates:
        slot = slot_of(t)
        history = by_slot.get(slot, [])
        open_ = max((r for r in history if r["to"] is None), key=lambda r: r["from"], default=None)
        if open_ is not None:
            if same_price(open_, t):
                continue
            if open_["from"] >= now:
                # The app corrects a record opened this very instant in place;
                # a published record is never rewritten, so a clock behind the
                # file stops the run instead.
                raise SyncError(f"{t['model']} [{t['provider']}/{t['region']}]: the open record starts "
                                f"{fmt_date(open_['from'])}, not before this run ({fmt_date(now)})")
            open_["to"] = now
            closed.append(dict(open_))
        start = min(starts[slot], now) if not history and slot in starts else now
        new = dict(t, **{"from": start, "to": None, "from_ts": start.timestamp(), "first": not history})
        records.append(new)
        by_slot.setdefault(slot, []).append(new)
        opened.append(new)
    records.sort(key=slot_order)
    return records, opened, closed


def suspicious(opened: list, closed: list, existing_open: int, templates_by_slot: dict) -> list[str]:
    """Why a run looks like garbage rather than a price change, if it does.

    A model's first record is checked too, not only corrections: a first
    listing at a zero input or output rate would bill that model at $0 on
    every Mac, and a later fix to it would then trip the tenfold guard."""
    why = []
    for new in opened:
        if not new.get("first"):
            continue
        for k in ("input", "output"):
            if new["rates"][k] <= 0:
                why.append(f"{new['model']} [{new['provider']}/{new['region']}] is listed for the first time "
                           f"with {k} at ${per_mtok(new['rates'][k])} per MTok")
    if existing_open and len(closed) > MASS_CHANGE_SHARE * existing_open:
        why.append(f"{len(closed)} of {existing_open} open prices would change in one run")
    for old in closed:
        new = templates_by_slot.get(slot_of(old))
        if new is None:
            continue
        for k in RATE_KEYS:
            a, b = old["rates"][k], new["rates"][k]
            if a > 0 and b > 0 and max(a / b, b / a) > MAX_FACTOR:
                why.append(f"{old['model']} [{old['provider']}/{old['region']}] {k}: "
                           f"${per_mtok(a)} → ${per_mtok(b)} per MTok")
            elif (a > 0) != (b > 0) and k in ("input", "output"):
                why.append(f"{old['model']} [{old['provider']}/{old['region']}] {k}: "
                           f"${per_mtok(a)} → ${per_mtok(b)} per MTok")
    return why


# ------------------------------------------------------------- checks

def record_id(prefix: str, model: str, provider: str, region: str, speed: str, tier: int, frm: datetime) -> str:
    return "|".join([prefix, model, provider, region, speed, str(tier), str(round(frm.timestamp()))])


def check_file(doc: dict) -> None:
    """What the app's decoder requires of the whole file (CuratedPriceHistory
    .decode, the curated rows as 0.9.4 reads them too); raises SyncError."""
    if not isinstance(doc, dict) or doc.get("schema") != 1:
        raise SyncError("not a schema-1 price history")
    parse_date(doc.get("asOf"))
    recs = doc.get("records")
    if not isinstance(recs, list) or not recs:
        raise SyncError("no curated records")
    ids = set()
    for r in recs:
        _check_row(r, curated=True)
        rid = record_id("curated", r["model"].lower(), r.get("provider") or "anthropic",
                        r.get("region") or "global", r.get("speed") or "standard",
                        int(r.get("tierAbovePromptTokens") or 0), parse_date(r["effectiveFrom"]))
        if rid in ids:
            raise SyncError(f"duplicate curated record {rid}")
        ids.add(rid)
    cat = doc.get("catalog")
    if cat is None:
        return
    if not isinstance(cat, dict) or not isinstance(cat.get("records"), list):
        raise SyncError("catalog is not an object with records")
    changed, checked = parse_date(cat.get("changedAt")), parse_date(cat.get("checkedAt"))
    if checked < changed:
        raise SyncError("catalog.checkedAt is before catalog.changedAt")
    ids = set()
    for r in cat["records"]:
        _check_row(r, curated=False)
        rid = record_id("list", r["model"], r["provider"], r["region"], "standard",
                        int(r.get("tierAbovePromptTokens") or 0), parse_date(r["effectiveFrom"]))
        if rid in ids:
            raise SyncError(f"duplicate catalog record {rid}")
        ids.add(rid)


def _check_row(r, curated: bool) -> None:
    if not isinstance(r, dict) or not isinstance(r.get("model"), str) or not r["model"]:
        raise SyncError(f"a record with no model: {r!r}")
    who = r["model"]
    if (r.get("provider") or "anthropic") not in PROVIDERS or (r.get("region") or "global") not in REGIONS:
        raise SyncError(f"{who}: unknown provider or region")
    if (r.get("speed") or "standard") not in ("standard", "fast"):
        raise SyncError(f"{who}: unknown speed")
    if not curated and r.get("source") not in SOURCES:
        raise SyncError(f"{who}: unknown source {r.get('source')!r}")
    rates = r.get("perMTok")
    if not isinstance(rates, dict):
        raise SyncError(f"{who}: no perMTok")
    for k in RATE_KEYS:
        v = rates.get(k)
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0:
            raise SyncError(f"{who}: perMTok.{k} is not a non-negative number")
    frm = parse_date(r.get("effectiveFrom"))
    if r.get("effectiveTo") is not None and parse_date(r["effectiveTo"]) <= frm:
        raise SyncError(f"{who}: effectiveTo is not after effectiveFrom")
    for k in ("fastMultiplier", "regionalMultiplier"):
        v = r.get(k)
        if v is not None and (isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0):
            raise SyncError(f"{who}: {k} is not a non-negative number")
    d = r.get("derived")
    if d is not None and (not isinstance(d, list) or any(x not in ("cacheWrite5m", "cacheWrite1h") for x in d)):
        raise SyncError(f"{who}: derived names an unknown rate")


def check_nothing_lost(before: dict, after: dict) -> None:
    """Never write a file that drops a model or rewrites history: the curated
    part is untouched, and every published record is still there with the
    same price and start (closing an open record is the only edit)."""
    if before.get("records") != after.get("records") or before.get("asOf") != after.get("asOf"):
        raise SyncError("the curated records or asOf would change")
    old = (before.get("catalog") or {}).get("records") or []
    new = after["catalog"]["records"]
    if len(new) < len(old):
        raise SyncError(f"the catalog would shrink from {len(old)} to {len(new)} records")
    remaining = list(new)
    for r in old:
        for i, n in enumerate(remaining):
            if all(n.get(k) == r.get(k) for k in r if k != "effectiveTo") and \
                    (n.get("effectiveTo") == r.get("effectiveTo") or r.get("effectiveTo") is None):
                del remaining[i]
                break
        else:
            raise SyncError(f"the record {r['model']} [{r.get('provider')}/{r.get('region')}] "
                            f"from {r['effectiveFrom']} would be lost or rewritten")
    open_old = {slot_of(row_to_internal(r)) for r in old if r.get("effectiveTo") is None}
    open_new = {slot_of(row_to_internal(r)) for r in new if r.get("effectiveTo") is None}
    if not open_old <= open_new:
        raise SyncError(f"{len(open_old - open_new)} model(s) would be left with no open price")


# ------------------------------------------------------------- render

def render(doc: dict) -> str:
    """The file as the repo keeps it: two-space JSON (which reproduces the
    curated part byte for byte), with one catalog record per line so a price
    change is a two-line diff."""
    cat = doc.get("catalog")
    if cat is None:
        return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
    mark = "\u0000catalog-records\u0000"
    shell = dict(doc)
    shell["catalog"] = dict(cat, records=mark)
    text = json.dumps(shell, indent=2, ensure_ascii=False)
    rows = ",\n".join("      " + json.dumps(r, ensure_ascii=False) for r in cat["records"])
    body = "[\n" + rows + "\n    ]" if rows else "[]"
    return text.replace(json.dumps(mark), body) + "\n"


# ---------------------------------------------------------------- sync

def sync(doc: dict, templates: list[dict], now: datetime, accept_mass_change: bool = False,
         heartbeat: bool = False):
    """The new document (or None when nothing needs writing) and a report.

    `heartbeat` re-confirms the list now even when nothing changed and the
    last check is recent: a fresh `checkedAt` is what makes every Mac take
    this copy over the one it cached (`CuratedPriceHistory.refresh` refuses
    an older one), so a hand correction of the list reaches them at once."""
    before = copy.deepcopy(doc)
    check_file(before)
    cat = doc.get("catalog") or {}
    existing = [row_to_internal(r) for r in cat.get("records") or []]
    records, opened, closed = fold(existing, templates, doc["records"], now)
    open_before = sum(1 for r in existing if r["to"] is None)
    by_slot = {slot_of(t): t for t in templates}
    why = suspicious(opened, closed, open_before, by_slot)
    report = {"opened": [internal_to_row(r) for r in opened], "closed": [internal_to_row(r) for r in closed],
              "records": len(records), "suspicious": why, "templates": len(templates)}
    if why and not accept_mass_change:
        raise SyncError("refusing a run that looks like a broken catalog, not a price change:\n  "
                        + "\n  ".join(why) + "\n(re-run with --accept-mass-change once checked)")
    changed = bool(opened or closed)
    checked_at = parse_date(cat["checkedAt"]) if cat.get("checkedAt") else None
    heartbeat = heartbeat or checked_at is None or now - checked_at >= HEARTBEAT
    if not changed and not heartbeat:
        report["action"] = "unchanged"
        return None, report
    after = dict(doc)
    new_cat = {
        "changedAt": fmt_date(now) if changed or not cat.get("changedAt") else cat["changedAt"],
        "checkedAt": fmt_date(now),
        "records": [internal_to_row(r) for r in records],
    }
    after["catalog"] = new_cat
    check_file(after)
    check_nothing_lost(before, after)
    report["action"] = "changed" if changed else "heartbeat"
    return after, report


# --------------------------------------------------------------- graft

def graft(release: dict, site: dict) -> dict:
    """The copy a release publishes: the release's curated part, with the
    site's catalog section when it is the newer one (a release's bundled copy
    carries none; the job keeps it on the site)."""
    out = dict(release)
    rc, sc = release.get("catalog"), site.get("catalog")
    def stamp(c):
        return parse_date(c["checkedAt"]) if c else datetime.min.replace(tzinfo=timezone.utc)
    if sc is not None and stamp(sc) >= stamp(rc):
        out["catalog"] = sc
    check_file(out)
    return out


# ---------------------------------------------------------------- main

def fetch_json(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=90) as r:
        if r.status != 200:
            raise SyncError(f"{url}: HTTP {r.status}")
        data = r.read()
    try:
        return json.loads(data)
    except ValueError as e:
        raise SyncError(f"{url}: not JSON ({e})") from e


def load_sources(args) -> tuple:
    def one(path, url, name):
        try:
            if path:
                return json.loads(Path(path).read_text(encoding="utf-8"))
            return fetch_json(url)
        except SyncError:
            raise
        except Exception as e:  # network, file, JSON
            raise SyncError(f"{name}: could not be read ({e})") from e
    return (one(args.litellm, LITELLM_URL, "LiteLLM"), one(args.models_dev, MODELS_DEV_URL, "models.dev"),
            one(args.catwalk, CATWALK_URL, "Catwalk"))


def summary_text(report: dict, dry: bool) -> str:
    lines = [f"## Price catalog sync: {report['action']}{' (dry run: nothing written)' if dry else ''}", "",
             f"{report['templates']} merged catalog price(s); the list holds {report['records']} "
             f"catalog record(s).", ""]
    for title, rows in (("Opened", report["opened"]), ("Closed", report["closed"])):
        if not rows:
            continue
        lines += [f"**{title}** ({len(rows)}):", ""]
        for r in rows[:200]:
            p = r["perMTok"]
            tier = f" over {r['tierAbovePromptTokens'] // 1000}k" if r.get("tierAbovePromptTokens") else ""
            until = f" to {r['effectiveTo']}" if r.get("effectiveTo") else ""
            lines.append(f"- `{r['model']}` {r['provider']}/{r['region']}{tier}, {r['effectiveFrom']}{until}: "
                         f"${p['input']} in, ${p['output']} out, ${p['cacheRead']} read [{r['source']}]")
        if len(rows) > 200:
            lines.append(f"- … and {len(rows) - 200} more")
        lines.append("")
    return "\n".join(lines) + "\n"


def review_shift(release: dict, site: dict) -> list[str]:
    """List prices a release would retroactively override (for `ship.sh`).

    An open curated record's review date is its `reviewedAt`, or the file's
    `asOf`. The app lets a list record that opened after the review, with a
    different price, beat that curated record (`PriceLedger.precedence`). A
    release whose review date moves past such a record turns it back into
    "known to the reviewer", and the curated price then wins over the list's
    for its whole window, history included. Sometimes that is the point; it
    should never be a surprise."""
    def review(doc, row):
        return parse_date(row.get("reviewedAt") or doc["asOf"])

    def key(row):
        return (row["model"].lower(), row.get("provider") or "anthropic", row.get("region") or "global",
                row.get("speed") or "standard", int(row.get("tierAbovePromptTokens") or 0), row["effectiveFrom"])

    old = {key(r): r for r in site.get("records") or []}
    listed = [row_to_internal(r) for r in (site.get("catalog") or {}).get("records") or []]
    out = []
    for row in release.get("records") or []:
        if row.get("effectiveTo") is not None or key(row) not in old:
            continue
        before, after = review(site, old[key(row)]), review(release, row)
        if after <= before:
            continue
        cur = row_to_internal(dict(row, source="curated"))
        for r in listed:
            if slot_of(r) == slot_of(cur) and before < r["from"] <= after and not same_price(r, cur):
                p, q = r["row"]["perMTok"], row["perMTok"]
                out.append(f"{row['model']} [{r['provider']}/{r['region']}]: the list's ${p['input']}/${p['output']} "
                           f"(read ${p['cacheRead']}) from {r['row']['effectiveFrom']} would give way to the curated "
                           f"${q['input']}/${q['output']} (read ${q['cacheRead']}): the review date moves "
                           f"{fmt_date(before)} → {fmt_date(after)}")
    return out


def commit_message(report: dict) -> str:
    """The bot commit's message: what changed, model by model. Never a
    bracketed skip-CI marker: Workers Builds honours one, and the site would
    not deploy the new list."""
    if report["action"] == "heartbeat":
        return ("Prices: price list re-checked, no catalog price changed\n\n"
                "bin/price-catalog-sync.py's weekly heartbeat (catalog.checkedAt), so a Mac\n"
                "can tell a quiet week from a stopped job.\n")
    changed = sorted({f"{r['model']}" for r in report["opened"] + report["closed"]})
    head = ", ".join(changed[:3]) + (f" and {len(changed) - 3} more" if len(changed) > 3 else "")
    lines = [f"Prices: catalog price list: {head} ({len(report['opened'])} opened, "
             f"{len(report['closed'])} closed)", "",
             "Merged from LiteLLM, models.dev and Catwalk by bin/price-catalog-sync.py. A change",
             "is dated by this run, so every Mac prices it from the same instant; a model's first",
             "record starts at its curated start date where the curated history has one, else at",
             "this run.", ""]
    for title, rows in (("Closed", report["closed"]), ("Opened", report["opened"])):
        for r in rows[:60]:
            p = r["perMTok"]
            tier = f" >{r['tierAbovePromptTokens'] // 1000}k" if r.get("tierAbovePromptTokens") else ""
            lines.append(f"- {title.lower()} {r['model']} {r['provider']}/{r['region']}{tier} "
                         f"from {r['effectiveFrom']}{' to ' + r['effectiveTo'] if r.get('effectiveTo') else ''}: "
                         f"${p['input']} in, ${p['output']} out, ${p['cacheRead']} read [{r['source']}]")
        if len(rows) > 60:
            lines.append(f"- … and {len(rows) - 60} more {title.lower()}")
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("sync", "templates"):
        p = sub.add_parser(name)
        p.add_argument("--litellm")
        p.add_argument("--models-dev")
        p.add_argument("--catwalk")
        if name == "sync":
            p.add_argument("--file", default=str(SITE_FILE))
            p.add_argument("--now", help="the observation time (default: now, UTC)")
            p.add_argument("--dry-run", action="store_true", help="report, write nothing")
            p.add_argument("--accept-mass-change", action="store_true")
            p.add_argument("--heartbeat", action="store_true",
                           help="write a fresh catalog.checkedAt even when nothing changed")
            p.add_argument("--summary", help="append a Markdown report here (GITHUB_STEP_SUMMARY)")
            p.add_argument("--message", help="when the file is written, write a commit message for it here")
    g = sub.add_parser("graft")
    g.add_argument("--release", required=True)
    g.add_argument("--site", required=True)
    g.add_argument("--out", required=True)
    r = sub.add_parser("review-shift", help="warn where a release's curated review date would retroactively "
                                            "beat a different list price")
    r.add_argument("--release", required=True)
    r.add_argument("--site", required=True)
    c = sub.add_parser("same-curated", help="exit 0 when two copies hold the same curated prices")
    c.add_argument("a")
    c.add_argument("b")
    args = ap.parse_args(argv)

    if args.cmd == "review-shift":
        try:
            release, site = (json.loads(Path(x).read_text(encoding="utf-8")) for x in (args.release, args.site))
            lines = review_shift(release, site)
        except (OSError, ValueError, SyncError) as e:
            print(f"review-shift: could not compare ({e})", file=sys.stderr)
            return 2
        for line in lines:
            print(line)
        return 3 if lines else 0

    if args.cmd == "same-curated":
        # What 0.9.3 and earlier read of the file (the legacy mirror's only
        # readers): everything but the price list. Between releases the job
        # moves main's list on and the mirror keeps the last release's.
        try:
            a, b = (json.loads(Path(x).read_text(encoding="utf-8")) for x in (args.a, args.b))
        except (OSError, ValueError):
            return 1
        strip = lambda d: {k: v for k, v in d.items() if k != "catalog"} if isinstance(d, dict) else d
        return 0 if strip(a) == strip(b) else 1

    try:
        if args.cmd == "graft":
            text = Path(args.release).read_text(encoding="utf-8")
            release = json.loads(text)
            try:
                site = json.loads(Path(args.site).read_text(encoding="utf-8"))
            except FileNotFoundError:
                site = {}
            out = graft(release, site)
            # Nothing to carry over: the release's bytes, exactly as before.
            Path(args.out).write_text(render(out) if out.get("catalog") != release.get("catalog") else text,
                                      encoding="utf-8")
            return 0

        lite, md, cw = load_sources(args)
        templates = merge_catalogs(lite, md, cw, guard=args.cmd == "sync")
        if args.cmd == "templates":
            rows = [dict(internal_to_row(dict(t, **{"from": datetime.fromtimestamp(0, timezone.utc),
                                                     "to": None})), effectiveFrom="1970-01-01")
                    for t in templates]
            json.dump(rows, sys.stdout, indent=1)
            sys.stdout.write("\n")
            return 0

        path = Path(args.file)
        doc = json.loads(path.read_text(encoding="utf-8"))
        now = parse_date(args.now) if args.now else datetime.now(timezone.utc)
        now = now.replace(microsecond=0)
        after, report = sync(doc, templates, now, accept_mass_change=args.accept_mass_change,
                             heartbeat=args.heartbeat)
        print(f"price-catalog-sync: {report['action']}: {len(report['opened'])} opened, "
              f"{len(report['closed'])} closed, {report['records']} catalog record(s) from "
              f"{report['templates']} merged price(s)")
        for r in report["closed"]:
            print(f"  closed {r['model']} [{r['provider']}/{r['region']}] tier {r.get('tierAbovePromptTokens', 0)}")
        if args.summary:
            with open(args.summary, "a", encoding="utf-8") as f:
                f.write(summary_text(report, args.dry_run))
        if after is not None and not args.dry_run:
            path.write_text(render(after), encoding="utf-8")
            if args.message:
                Path(args.message).write_text(commit_message(report), encoding="utf-8")
        return 0
    except SyncError as e:
        print(f"price-catalog-sync: {e}", file=sys.stderr)
        if getattr(args, "summary", None):
            with open(args.summary, "a", encoding="utf-8") as f:
                f.write(f"## Price catalog sync: failed\n\n```\n{e}\n```\n\nNothing was written.\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
