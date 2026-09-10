#!/usr/bin/env bash
# Regenerate the embedded pricing snapshot:
#   LiteLLM main + models.dev + catwalk anthropic gap-fill
# — the same merge PricingTable.refresh() performs at runtime, so a
# fresh offline install prices recent models without waiting for the
# first network refresh. Run via `make pricing-snapshot`; commit the
# resulting Resources/litellm-pricing.json.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="PacerCore/Sources/PacerCore/Resources/litellm-pricing.json"
LITE_TMP="$(mktemp -t litellm-snapshot)"
MD_TMP="$(mktemp -t modelsdev-snapshot)"
CW_TMP="$(mktemp -t catwalk-snapshot)"
trap 'rm -f "$LITE_TMP" "$MD_TMP" "$CW_TMP"' EXIT

curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json" \
    -o "$LITE_TMP"
curl -fsSL --max-time 60 "https://models.dev/api.json" -o "$MD_TMP"
curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/charmbracelet/catwalk/main/internal/providers/configs/anthropic.json" \
    -o "$CW_TMP"

LITE_TMP="$LITE_TMP" MD_TMP="$MD_TMP" CW_TMP="$CW_TMP" OUT="$OUT" python3 <<'PY'
import json, os

lite = json.load(open(os.environ["LITE_TMP"]))
md = json.load(open(os.environ["MD_TMP"]))
cw = json.load(open(os.environ["CW_TMP"]))

if len(lite) < 1000:
    raise SystemExit(f"LiteLLM payload suspiciously small ({len(lite)} models) — aborting")

# Approximation of PricingTable.liteLLMMatch: a models.dev id is
# "covered" when any LiteLLM key matches it bidirectionally by
# substring. The runtime merge is the load-bearing one; this only has
# to keep the embedded snapshot from double-carrying entries.
lite_keys_lower = [k.lower() for k in lite]
def covered(mid: str) -> bool:
    ml = mid.lower()
    return any(ml in kl or kl in ml for kl in lite_keys_lower)

def models_dev_entries():
    """models.dev: per-MTok dollars under `cost`, models keyed by id."""
    out = {}
    for mid, model in (md.get("anthropic", {}).get("models", {}) or {}).items():
        cost = model.get("cost") or {}
        entry = {}
        for src, dst in (
            ("input", "input_cost_per_token"),
            ("output", "output_cost_per_token"),
            ("cache_read", "cache_read_input_token_cost"),
            ("cache_write", "cache_creation_input_token_cost"),
        ):
            v = cost.get(src)
            if isinstance(v, (int, float)) and v > 0:
                entry[dst] = v / 1e6
        if not entry:
            continue
        limit = model.get("limit") or {}
        if isinstance(limit.get("context"), int):
            entry["max_input_tokens"] = limit["context"]
        if isinstance(limit.get("output"), int):
            entry["max_output_tokens"] = limit["output"]
        out[mid] = entry
    return out


def catwalk_entries():
    """catwalk: per-MTok dollars under flat keys, models as a list.

    `cost_per_1m_in_cached` is the cache *write* rate (above input) and
    `cost_per_1m_out_cached` is the *read* rate (well below it). Swapping
    them would inflate cache reads ~50x while looking plausible. Mirrors
    `CatwalkCatalog.anthropicEntries`.
    """
    out = {}
    for model in cw.get("models") or []:
        mid = model.get("id")
        if not mid:
            continue
        entry = {}
        for src, dst in (
            ("cost_per_1m_in", "input_cost_per_token"),
            ("cost_per_1m_out", "output_cost_per_token"),
            ("cost_per_1m_in_cached", "cache_creation_input_token_cost"),
            ("cost_per_1m_out_cached", "cache_read_input_token_cost"),
        ):
            v = model.get(src)
            if isinstance(v, (int, float)) and v > 0:
                entry[dst] = v / 1e6
        if not entry:
            continue
        if isinstance(model.get("context_window"), int):
            entry["max_input_tokens"] = model["context_window"]
        if isinstance(model.get("default_max_tokens"), int):
            entry["max_output_tokens"] = model["default_max_tokens"]
        out[mid] = entry
    return out


# Per-field consensus, mirroring PricingTable.reconcile: a majority of
# sources outvotes any single one INCLUDING LiteLLM, because tiering can
# only fill a gap and never correct a wrong price. No majority keeps
# LiteLLM's value — an arbitrary tie-break dressed up as consensus is
# worse than a known-provenance number.
COST_FIELDS = [
    "input_cost_per_token",
    "output_cost_per_token",
    "cache_creation_input_token_cost",
    "cache_read_input_token_cost",
]

secondaries = [("models.dev", models_dev_entries()), ("catwalk", catwalk_entries())]

def match_key(mid):
    """The key a lookup for `mid` resolves to, mirroring liteLLMMatchKey."""
    if mid in lite:
        return mid
    for prefix in ("anthropic/", "claude-3-5-", "claude-3-", "claude-", "openrouter/openai/"):
        if prefix + mid in lite:
            return prefix + mid
    ml = mid.lower()
    for k in lite:
        kl = k.lower()
        if ml in kl or kl in ml:
            return k
    return None

ids = set()
for _, entries in secondaries:
    ids |= set(entries)

added, corrected, split = [], [], []
for mid in sorted(ids):
    key = match_key(mid)
    primary = dict(lite.get(key) or {}) if key else {}
    winner = dict(primary)
    changed = False

    for field in COST_FIELDS:
        votes = []
        pv = primary.get(field)
        if isinstance(pv, (int, float)) and pv > 0:
            votes.append(("litellm", pv))
        for name, entries in secondaries:
            v = (entries.get(mid) or {}).get(field)
            if isinstance(v, (int, float)) and v > 0:
                votes.append((name, v))
        if not votes:
            continue
        tally = {}
        for _, v in votes:
            for seen in tally:
                if abs(seen - v) < 1e-12:
                    tally[seen] += 1
                    break
            else:
                tally[v] = 1
        best_val, best_n = max(tally.items(), key=lambda kv: kv[1])
        if len(tally) == 1 or best_n * 2 > len(votes):
            if isinstance(pv, (int, float)) and abs(pv - best_val) >= 1e-12:
                corrected.append(f"{mid}.{field}: {pv} -> {best_val} ({best_n}/{len(votes)})")
            if winner.get(field) is None or abs(winner[field] - best_val) >= 1e-12:
                winner[field] = best_val
                changed = True
        elif isinstance(pv, (int, float)):
            split.append(f"{mid}.{field}: " + " ".join(f"{n}={v}" for n, v in votes))
            winner[field] = pv
        else:
            split.append(f"{mid}.{field}: " + " ".join(f"{n}={v}" for n, v in votes))
            winner[field] = votes[0][1]
            changed = True

    if not winner:
        continue
    for field in ("max_input_tokens", "max_output_tokens"):
        if winner.get(field) is None:
            for _, entries in secondaries:
                v = (entries.get(mid) or {}).get(field)
                if v is not None:
                    winner[field] = v
                    break

    if key:
        if changed:
            lite[key] = winner
    else:
        lite[mid] = winner
        added.append(mid)

with open(os.environ["OUT"], "w") as f:
    json.dump(lite, f, indent=1, sort_keys=True)
    f.write("\n")
print(f"wrote {os.environ['OUT']}: {len(lite)} models "
      f"(+{len(added)} added: {sorted(added)})")
if corrected:
    print(f"  consensus overrode LiteLLM on {len(corrected)} field(s):")
    for line in corrected:
        print(f"    {line}")
if split:
    print(f"  no majority on {len(split)} field(s), kept LiteLLM:")
    for line in split:
        print(f"    {line}")
PY
