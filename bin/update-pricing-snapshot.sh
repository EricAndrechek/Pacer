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


# Ordered chain, mirroring PricingTable.gapFill: a later source may only
# supply a price nobody had, never replace one an earlier source gave.
added = []
for name, entries in (("models.dev", models_dev_entries()),
                      ("catwalk", catwalk_entries())):
    for mid, entry in entries.items():
        if covered(mid) or mid in lite:
            continue
        lite[mid] = entry
        added.append(f"{mid} ({name})")

with open(os.environ["OUT"], "w") as f:
    json.dump(lite, f, indent=1, sort_keys=True)
    f.write("\n")
print(f"wrote {os.environ['OUT']}: {len(lite)} models "
      f"(+{len(added)} gap-filled: {sorted(added)})")
PY
