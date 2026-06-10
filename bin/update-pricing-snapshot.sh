#!/usr/bin/env bash
# Regenerate the embedded pricing snapshot:
#   LiteLLM main + models.dev anthropic gap-fill
# — the same merge PricingTable.refresh() performs at runtime, so a
# fresh offline install prices recent models without waiting for the
# first network refresh. Run via `make pricing-snapshot`; commit the
# resulting Resources/litellm-pricing.json.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="PacerCore/Sources/PacerCore/Resources/litellm-pricing.json"
LITE_TMP="$(mktemp -t litellm-snapshot)"
MD_TMP="$(mktemp -t modelsdev-snapshot)"
trap 'rm -f "$LITE_TMP" "$MD_TMP"' EXIT

curl -fsSL --max-time 60 \
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json" \
    -o "$LITE_TMP"
curl -fsSL --max-time 60 "https://models.dev/api.json" -o "$MD_TMP"

LITE_TMP="$LITE_TMP" MD_TMP="$MD_TMP" OUT="$OUT" python3 <<'PY'
import json, os

lite = json.load(open(os.environ["LITE_TMP"]))
md = json.load(open(os.environ["MD_TMP"]))

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

added = []
for mid, model in (md.get("anthropic", {}).get("models", {}) or {}).items():
    if covered(mid):
        continue
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
    lite[mid] = entry
    added.append(mid)

with open(os.environ["OUT"], "w") as f:
    json.dump(lite, f, indent=1, sort_keys=True)
    f.write("\n")
print(f"wrote {os.environ['OUT']}: {len(lite)} models "
      f"(+{len(added)} gap-filled from models.dev: {sorted(added)})")
PY
