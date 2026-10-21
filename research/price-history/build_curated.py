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
    (×0.05 on Opus 5.5 and, from 2026-10-07, Sonnet 5.5, ×0.025 on Fable/Mythos 5.1)."""
    return rates(i, o, round(i * 1.25, 6), round(i * 2, 6), round(i * read_multiplier, 6))


RECORDS: list[dict] = []


RELEASE_NOTES = "https://platform.claude.com/docs/en/release-notes/overview"
GLASSWING = "https://www.anthropic.com/glasswing"
CLAUDE_4 = "https://www.anthropic.com/news/claude-4"


def add(model, start, perMTok, note, end=None, tier=0, fast=None, regional=None,
        speed=None, source=PAGE):
    row = {"model": model, "effectiveFrom": start, "effectiveTo": end, "perMTok": perMTok,
           "sourceURL": source, "note": note}
    if speed:
        row["speed"] = speed
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
# Sonnet 5.5's cache read was $0.20 (0.1x) at launch and was lowered to $0.10
# (0.05x) on 2026-10-07 (release notes, Oct 7; Wayback snapshots of the pricing
# page from 2026-09-28 through 2026-10-06 show $0.20, 2026-10-08 shows $0.10).
# The catalogs were right, and an earlier version of this file was wrong.
add("claude-sonnet-5-5", "2026-09-28", std(2, 10, 0.1), end="2026-10-07", regional=R,
    source=RELEASE_NOTES,
    note="Launch price: cache reads 0.1x input ($0.20). Lowered to $0.10 on "
         "2026-10-07; every other rate unchanged.")
add("claude-sonnet-5-5", "2026-10-07", std(2, 10, 0.05), regional=R, source=RELEASE_NOTES,
    note="Cache reads lowered from $0.20 to $0.10 (0.05x input) on 2026-10-07, per "
         "the release notes; every other rate unchanged.")
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
# Fast mode for Opus 4.7: 2026-05-12 (release notes, "Fast mode now supports
# Claude Opus 4.7") to 2026-07-24 (deprecated Jun 25, removed Jul 24). The
# catalogs listed it from 2026-04-16 to 2026-08-26; the release notes win.
for start, end, fast, note in [
    ("2026-04-16", "2026-05-12", None, "No fast mode yet."),
    ("2026-05-12", "2026-07-24", 6.0,
     "Fast mode at 6x ($30/$150), 2026-05-12 to 2026-07-24 (release notes)."),
    ("2026-07-24", None, None, "Fast mode removed 2026-07-24; standard rates only."),
]:
    add("claude-opus-4-7", start, std(5, 25), end=end, fast=fast, regional=R, note=note,
        source=RELEASE_NOTES if fast else PAGE)
# Opus 4.6: fast mode launched 2026-02-07 at 6x ($30/$150) and was removed
# 2026-06-29 (release notes); requests afterwards run at standard speed.
# Claude Code's fast-mode doc advertised a 50% plan discount until 11:59pm PT
# on 2026-02-16; the API pricing pages never showed it and the file has no
# plan-level promotions, so it is not applied (the note records it).
FAST46 = ("Fast mode at 6x ($30/$150), 2026-02-07 to 2026-06-29 (release notes). Claude "
          "Code's fast-mode doc advertised a 50% plan discount until 2026-02-16; the API "
          "pricing pages do not show it, so it is not applied.")
for start, end, fast, note in [
    ("2026-02-05", "2026-02-07", None, "Standard rates; fast mode not yet available."),
    ("2026-02-07", "2026-06-29", 6.0, FAST46),
    ("2026-06-29", None, None, "Fast mode removed 2026-06-29; requests bill at standard speed."),
]:
    add("claude-opus-4-6", start, std(5, 25), end=end, fast=fast, regional=R, note=note,
        source=RELEASE_NOTES if fast else PAGE)
add("claude-opus-4-6", "2026-02-05", rates(10, 37.5, 12.5, 20, 1.0), end="2026-03-13",
    tier=200_000, regional=R,
    note="1M-context premium over 200k at launch; Claude 4.6 later moved to standard "
         "pricing across the full window. 1h write derived (2x input).")
# Explicit fast records where the multiplier cannot express the price. At fast
# launch a request over 200k prompt tokens was $60/$225 (6x the premium tier);
# that over-200k fast premium was dropped between 2026-02-18 and 2026-02-24
# (2026-02-21 used; the exact day is uncertain), after which fast over 200k is
# $30/$150 -- not 6x the still-premium standard tier (that would be $60/$225).
# Both tiers need a record: a lone upper-tier fast record would also price small
# prompts.
add("claude-opus-4-6", "2026-02-07", rates(30, 150, 37.5, 60, 3.0), end="2026-03-13",
    speed="fast", regional=R, source=RELEASE_NOTES,
    note="Fast mode, 6x standard, including over 200k prompt tokens once the over-200k "
         "fast premium was dropped (about 2026-02-21; uncertain by a few days). Derived "
         "from the 6x rule.")
add("claude-opus-4-6", "2026-02-07", rates(60, 225, 75, 120, 6.0), end="2026-02-21",
    tier=200_000, speed="fast", regional=R, source=RELEASE_NOTES,
    note="Fast mode over 200k prompt tokens at launch: $60/$225. The premium was dropped "
         "between 2026-02-18 and 2026-02-24; 2026-02-21 is an estimate within that range.")
add("claude-sonnet-4-6", "2026-02-17", std(3, 15), regional=R, note="Standard rates.")
add("claude-sonnet-4-6", "2026-02-17", rates(6, 22.5, 7.5, 12, 0.6), end="2026-03-13",
    tier=200_000, regional=R,
    note="1M-context premium over 200k at launch, until 4.6 moved to standard "
         "pricing (models.dev 2026-03-13, LiteLLM 2026-03-27). 1h write derived.")
add("claude-opus-4-5", "2025-11-24", std(5, 25), regional=R, note="Standard rates.")
add("claude-haiku-4-5", "2025-10-15", std(1, 5), regional=R, note="Standard rates.")
add("claude-sonnet-4-5", "2025-09-29", std(3, 15), regional=R,
    note="Standard rates. The 1h write (2x) predates its appearance in LiteLLM (2026-06-17).")
add("claude-sonnet-4-5", "2025-09-29", rates(6, 22.5, 7.5, 12, 0.6), end="2026-04-30",
    tier=200_000, regional=R, source=RELEASE_NOTES,
    note="1M-context (beta) premium over 200k, until the beta was retired 2026-04-30 "
         "(release notes, Mar 30 and Apr 30). Anthropic's 'full window at standard "
         "pricing' covers 4.6 and later only. 1h write derived (2x input).")
# Retirement dates are recorded in notes, not effectiveTo, where the model stays
# available on Bedrock or Google Cloud: those requests price from these global
# records (times the regional multiplier), and a closed window would flag them
# outsideWindow.
add("claude-opus-4-1", "2025-08-05", std(15, 75),
    note="Retired from the Claude API 2026-08-05; still on Bedrock and Google Cloud.")
add("claude-opus-4", "2025-05-22", std(15, 75),
    note="Retired from the Claude API 2026-06-15; still on Google Cloud.")
add("claude-sonnet-4", "2025-05-22", std(3, 15),
    note="Retired from the Claude API 2026-06-15; still on Bedrock and Google Cloud.")
add("claude-sonnet-4", "2025-08-12", rates(6, 22.5, 7.5, 12, 0.6), end="2026-04-30",
    tier=200_000, source=RELEASE_NOTES,
    note="1M-context (beta) premium over 200k, from the beta's start 2025-08-12 until it "
         "was retired 2026-04-30 (release notes, Mar 30 and Apr 30). 1h write derived "
         "(2x input).")

# --- Claude 3 generation, still seen in 2025 transcripts --------------------
# The 1-hour cache write arrived 2025-05-22 (https://www.anthropic.com/news/claude-4).
# The 1h rate on these three rows is therefore not offered before that date; no
# request can carry 1h writes then, so the rate is unreachable there and no
# money is affected.
add("claude-3-7-sonnet", "2025-02-24", std(3, 15), end="2026-02-19",
    note="Retired 2026-02-19. Standard multipliers. 1h write only offered from "
         "2025-05-22 (1h rate unreachable before).")
add("claude-3-5-sonnet", "2025-01-01", std(3, 15), end="2025-10-28",
    note="Retired 2025-10-28. Standard multipliers. In effect before 2025; earlier "
         "history not reviewed. 1h write only offered from 2025-05-22 (1h rate "
         "unreachable before).")
add("claude-3-5-haiku", "2025-01-01", rates(0.80, 4, 1, 1.6, 0.08),
    note="Retired from the Claude API 2026-02-19; still on Google Cloud. In effect "
         "before 2025; earlier history not reviewed. 1h write only offered from "
         "2025-05-22 (1h rate unreachable before). (LiteLLM's $1/$5 before 2025-02-28 "
         "and its $0.80 cache read before 2025-04-08 were catalog errors.)")
add("claude-mythos-preview", "2026-04-07", std(25, 125), regional=R, source=GLASSWING,
    note="Limited-availability research preview, $25/$125 per MTok input/output "
         "(Project Glasswing announcement). Cache rates DERIVED with the standard "
         "multipliers (5m 1.25x, 1h 2x, read 0.1x), not published. Supersedes "
         "LiteLLM's $10/$50 row.")


def main() -> int:
    doc = {"schema": 1, "asOf": AS_OF, "source": PAGE, "records": RECORDS}
    keys = [(r["model"], r.get("speed", "standard"), r.get("tierAbovePromptTokens", 0),
             r["effectiveFrom"]) for r in RECORDS]
    if len(keys) != len(set(keys)):
        print("duplicate record", file=sys.stderr)
        return 1
    OUT.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"wrote {len(RECORDS)} records to {OUT.relative_to(OUT.parents[4])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
