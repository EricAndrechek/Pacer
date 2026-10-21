# /// script
# requires-python = ">=3.11"
# ///
"""Write Pacer's curated price history (`price-history.json`) from the
reviewed facts below.

The facts are the output of a hand review: `seed_price_history.py` walked the
git history of LiteLLM and models.dev (see REPORT.md), and every row here was
checked against Anthropic's pricing page as fetched on the `AS_OF` date
(https://platform.claude.com/docs/en/about-claude/pricing). Where a catalog
and the page disagree, the page wins and the note says what the catalog had.

Dates are UTC days. A launch date is the first day either catalog listed the
model (Anthropic's page gives no launch dates); every sample in a real store
falls on or after it. `effectiveTo` is exclusive.

    uv run research/price-history/build_curated.py

writes PacerCore/Sources/PacerCore/Resources/price-history.json.
"""
from __future__ import annotations

import json
import pathlib
import sys

AS_OF = "2026-10-21"
PAGE = "https://platform.claude.com/docs/en/about-claude/pricing"
OUT = pathlib.Path(__file__).resolve().parents[2] / "PacerCore/Sources/PacerCore/Resources/price-history.json"


def rates(i, o, w5, w1h, r):
    return {"input": i, "output": o, "cacheWrite5m": w5, "cacheWrite1h": w1h, "cacheRead": r}


def std(i, o, read_multiplier=0.1):
    """Anthropic's uniform multipliers: 5m write ×1.25, 1h write ×2, read ×0.1
    (×0.05 on Opus/Sonnet 5.5, ×0.025 on Fable/Mythos 5.1)."""
    return rates(i, o, round(i * 1.25, 6), round(i * 2, 6), round(i * read_multiplier, 6))


RECORDS: list[dict] = []


def add(model, start, perMTok, note, end=None, tier=0, fast=None, regional=None):
    row = {"model": model, "effectiveFrom": start, "effectiveTo": end, "perMTok": perMTok,
           "sourceURL": PAGE, "note": note}
    if tier:
        row["tierAbovePromptTokens"] = tier
    if fast is not None:
        row["fastMultiplier"] = fast
    if regional is not None:
        row["regionalMultiplier"] = regional
    RECORDS.append(row)


# The 10% regional / US-residency premium. Anthropic: regional endpoints cost
# 10% more "starting with Claude Sonnet 4.5, Haiku 4.5 and Opus 4.5", and
# inference_geo "us" is 1.1x "for Claude 4.6 and later models" (earlier models
# reject the parameter, so the multiplier only ever reaches Bedrock/Vertex
# regional requests for 4.5).
R = 1.1

# --- Claude 5 generation ------------------------------------------------------
add("claude-fable-5-1", "2026-09-01", std(10, 50, 0.025), regional=R,
    note="Cache reads at 0.025x input ($0.25) from launch.")
add("claude-mythos-5-1", "2026-09-01", std(10, 50, 0.025), regional=R,
    note="Limited availability. Same rates as Fable 5.1, cache reads 0.025x. "
         "Catalogs first listed it 2026-09-03; dated with Fable 5.1's launch.")
add("claude-fable-5", "2026-06-09", std(10, 50), regional=R,
    note="Launched with Mythos 5 on 2026-06-09.")
add("claude-mythos-5", "2026-06-09", std(10, 50), regional=R,
    note="Limited availability, launched with Fable 5. LiteLLM first listed it 2026-08-10.")
add("claude-opus-5-5", "2026-09-22", std(4, 20, 0.05), fast=2.0, regional=R,
    note="Cache reads 0.05x input ($0.20) from launch. Fast mode $8/$40 (2x).")
add("claude-opus-5", "2026-07-24", std(5, 25), fast=2.0, regional=R,
    note="Fast mode (research preview) $10/$50 (2x).")
add("claude-sonnet-5-5", "2026-09-28", std(2, 10, 0.05), regional=R,
    note="Cache reads 0.05x input ($0.10) from launch. Both catalogs carried "
         "$0.20 until 2026-10-07; Anthropic's rate was 0.05x throughout.")
add("claude-sonnet-5", "2026-06-30", std(2, 10), regional=R,
    note="$2/$10 launched as introductory pricing 'through August 31, 2026' and "
         "became the standard price; the scheduled rise to $3/$15 on "
         "2026-09-01 did not happen. LiteLLM listed $3/$15 for its first two "
         "days (2026-06-30..07-02); the introductory rate applied from launch.")
add("claude-haiku-5-5", "2026-10-07", std(0.10, 0.50), regional=R,
    note="Prompts up to 100,000 tokens.")
add("claude-haiku-5-5", "2026-10-07", std(0.50, 2.50), tier=100_000, regional=R,
    note="A request whose prompt (input + cache reads + cache writes) is over "
         "100,000 tokens pays these on the whole request, cache hits included.")

# --- Claude 4 generation ------------------------------------------------------
add("claude-opus-4-8", "2026-05-28", std(5, 25), fast=2.0, regional=R,
    note="Fast mode (research preview) $10/$50 (2x).")
for start, end, fast, note in [
    ("2026-04-16", "2026-08-26", 6.0,
     "Fast mode at 6x ($30/$150) while LiteLLM listed it (2026-04-16..08-26); "
     "Anthropic's page no longer lists fast mode for Opus 4.7."),
    ("2026-08-26", None, None, "No fast mode."),
]:
    add("claude-opus-4-7", start, std(5, 25), end=end, fast=fast, regional=R, note=note)
# Opus 4.6: a 1M-context premium over 200k until 4.6 moved to standard
# pricing across its window (models.dev dropped it 2026-03-13, LiteLLM
# 2026-03-27; the earlier date is used), and fast mode at 6x for a while.
for start, end, fast in [("2026-02-05", "2026-02-23", None),
                         ("2026-02-23", "2026-08-26", 6.0),
                         ("2026-08-26", None, None)]:
    add("claude-opus-4-6", start, std(5, 25), end=end, fast=fast, regional=R,
        note="Fast mode at 6x ($30/$150) while LiteLLM listed it (2026-02-23..08-26)."
        if fast else "Standard rates.")
add("claude-opus-4-6", "2026-02-05", rates(10, 37.5, 12.5, 20, 1.0), end="2026-03-13",
    tier=200_000, regional=R,
    note="1M-context premium over 200k at launch; Claude 4.6 later moved to standard "
         "pricing across the full window. 1h write derived (2x input).")
add("claude-sonnet-4-6", "2026-02-17", std(3, 15), regional=R, note="Standard rates.")
add("claude-sonnet-4-6", "2026-02-17", rates(6, 22.5, 7.5, 12, 0.6), end="2026-03-13",
    tier=200_000, regional=R,
    note="1M-context premium over 200k at launch, until 4.6 moved to standard "
         "pricing (models.dev 2026-03-13, LiteLLM 2026-03-27). 1h write derived.")
add("claude-opus-4-5", "2025-11-24", std(5, 25), regional=R, note="Standard rates.")
add("claude-haiku-4-5", "2025-10-15", std(1, 5), regional=R, note="Standard rates.")
add("claude-sonnet-4-5", "2025-09-29", std(3, 15), regional=R,
    note="Standard rates. The 1h write (2x) predates its appearance in LiteLLM (2026-06-17).")
add("claude-sonnet-4-5", "2025-09-29", rates(6, 22.5, 7.5, 12, 0.6), tier=200_000, regional=R,
    note="1M-context (beta) premium over 200k; Anthropic's 'full window at standard "
         "pricing' covers 4.6 and later only. 1h write derived (2x input).")
add("claude-opus-4-1", "2025-08-05", std(15, 75), note="Retired except on Bedrock and Google Cloud.")
add("claude-opus-4", "2025-05-22", std(15, 75), note="Retired except on Google Cloud.")
add("claude-sonnet-4", "2025-05-22", std(3, 15), note="Retired except on Bedrock and Google Cloud.")
add("claude-sonnet-4", "2025-05-22", rates(6, 22.5, 7.5, 12, 0.6), tier=200_000,
    note="1M-context (beta) premium over 200k. 1h write derived (2x input).")

# --- Claude 3 generation, still seen in 2025 transcripts --------------------
add("claude-3-7-sonnet", "2025-02-24", std(3, 15),
    note="Retired; not on the current page. Standard multipliers.")
add("claude-3-5-sonnet", "2025-01-01", std(3, 15),
    note="Retired; not on the current page. Standard multipliers. In effect before "
         "2025; earlier history not reviewed.")
add("claude-3-5-haiku", "2025-01-01", rates(0.80, 4, 1, 1.6, 0.08),
    note="Retired except on Google Cloud. In effect before 2025; earlier history not "
         "reviewed. (LiteLLM's $1/$5 before 2025-02-28 and its $0.80 cache read "
         "before 2025-04-08 were catalog errors.)")


def main() -> int:
    doc = {"schema": 1, "asOf": AS_OF, "source": PAGE, "records": RECORDS}
    keys = [(r["model"], r.get("tierAbovePromptTokens", 0), r["effectiveFrom"]) for r in RECORDS]
    if len(keys) != len(set(keys)):
        print("duplicate record", file=sys.stderr)
        return 1
    OUT.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"wrote {len(RECORDS)} records to {OUT.relative_to(OUT.parents[4])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
