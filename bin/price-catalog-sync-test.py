#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Tests for bin/price-catalog-sync.py (#469). Stdlib unittest, offline.

    uv run bin/price-catalog-sync-test.py        # or: python3 -I bin/price-catalog-sync-test.py

The merge's parity with the app is checked from the other side too:
`PricingCatalogParityTests` (PacerCoreTests) runs the script's `templates`
command and compares it with the app's own merge.
"""
from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
FIXTURES = ROOT / "PacerCore/Tests/PacerCoreTests/PriceSyncFixtures"
SCRIPT = HERE / "price-catalog-sync.py"

sys.dont_write_bytecode = True  # no __pycache__ beside the script in bin/
spec = importlib.util.spec_from_file_location("price_catalog_sync", SCRIPT)
pcs = importlib.util.module_from_spec(spec)
sys.modules["price_catalog_sync"] = pcs
spec.loader.exec_module(pcs)


def load(name):
    return json.loads((FIXTURES / name).read_text())


def utc(s):
    return pcs.parse_date(s)


def merged_fixtures():
    return pcs.merge_catalogs(load("litellm.json"), load("models-dev.json"), load("catwalk.json"), guard=False)


def fixture_templates():
    """The fixtures' merge without `claude-outputonly-1`, whose $0 input the
    first-listing guard refuses (tested on its own below)."""
    return [t for t in merged_fixtures() if t["model"] != "claude-outputonly-1"]


def find(rows, model, provider="anthropic", region="global", tier=0):
    out = [r for r in rows if r["model"] == model and r["provider"] == provider and r["region"] == region
           and int(r.get("tier", r.get("tierAbovePromptTokens", 0)) or 0) == tier]
    return out


def mtok(t, k):
    return pcs.per_mtok(t["rates"][k])


CURATED = {
    "schema": 1,
    "asOf": "2026-11-11",
    "records": [
        {"model": "claude-opus-5-5", "effectiveFrom": "2026-09-22", "effectiveTo": None,
         "perMTok": {"input": 4, "output": 20, "cacheWrite5m": 5.0, "cacheWrite1h": 8, "cacheRead": 0.2},
         "sourceURL": "https://example.com", "note": "curated", "fastMultiplier": 2.0, "regionalMultiplier": 1.1},
        {"model": "claude-sonnet-4-5", "effectiveFrom": "2025-09-29", "effectiveTo": None,
         "perMTok": {"input": 3, "output": 15, "cacheWrite5m": 3.75, "cacheWrite1h": 6, "cacheRead": 0.3},
         "sourceURL": "https://example.com", "note": "curated", "regionalMultiplier": 1.1},
    ],
}


class ParseTests(unittest.TestCase):
    """`CanonicalModelID.parse`, case for case with CanonicalPriceMatchTests."""

    def test_spellings(self):
        cases = {
            "claude-sonnet-5-5": ("claude-sonnet-5-5", "anthropic", "global"),
            "claude-opus-5-5[1m]": ("claude-opus-5-5", "anthropic", "global"),
            "Claude-Opus-5-5[1M]": ("claude-opus-5-5", "anthropic", "global"),
            "claude-haiku-4-5-20251001": ("claude-haiku-4-5", "anthropic", "global"),
            "claude-3-5-sonnet-20241022": ("claude-3-5-sonnet", "anthropic", "global"),
            "us.anthropic.claude-sonnet-4-5-20250929-v1:0": ("claude-sonnet-4-5", "bedrock", "us"),
            "eu.anthropic.claude-opus-5": ("claude-opus-5", "bedrock", "eu"),
            "global.anthropic.claude-sonnet-5": ("claude-sonnet-5", "bedrock", "global"),
            "jp.anthropic.claude-opus-5": ("claude-opus-5", "bedrock", "apac"),
            "au.anthropic.claude-opus-5": ("claude-opus-5", "bedrock", "apac"),
            "us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0": ("claude-sonnet-4-5", "bedrock", "us-gov"),
            "anthropic.claude-haiku-4-5-20251001-v1:0": ("claude-haiku-4-5", "bedrock", "global"),
            "bedrock/us-gov-west-1/anthropic.claude-haiku-4-5-20251001-v1:0": ("claude-haiku-4-5", "bedrock", "us-gov"),
            "bedrock/eu-central-1/anthropic.claude-haiku-4-5-v1:0": ("claude-haiku-4-5", "bedrock", "eu"),
            "bedrock/ap-northeast-1/anthropic.claude-haiku-4-5": ("claude-haiku-4-5", "bedrock", "apac"),
            "claude-sonnet-4-5@20250929": ("claude-sonnet-4-5", "vertex", "global"),
            "vertex_ai/claude-opus-5@default": ("claude-opus-5", "vertex", "global"),
            "azure_ai/claude-opus-5-5": ("claude-opus-5-5", "foundry", "global"),
            "anthropic/claude-opus-5-5": ("claude-opus-5-5", "anthropic", "global"),
            "claude-3-haiku-v2": ("claude-3-haiku", "bedrock", "global"),
            "openrouter/anthropic/claude-opus-5": ("openrouter/anthropic/claude-opus-5", "other", "global"),
        }
        for raw, want in cases.items():
            self.assertEqual(pcs.parse_id(raw), want, raw)

    def test_version_complete_prefix(self):
        self.assertTrue(pcs.version_complete_prefix("claude-opus-4-7", "claude-opus-4-7-thinking"))
        self.assertFalse(pcs.version_complete_prefix("claude-sonnet-5", "claude-sonnet-5-5"))
        self.assertFalse(pcs.version_complete_prefix("claude-sonnet-5", "claude-sonnet-5"))
        self.assertFalse(pcs.version_complete_prefix("claude-sonnet-5", "claude-sonnet-5-"))

    def test_index_prefers_the_plain_key_then_the_shortest(self):
        idx = pcs.CatalogIndex(["claude-haiku-4-5-20251001", "claude-haiku-4-5", "anthropic/claude-haiku-4-5"])
        self.assertEqual(idx.match_key("claude-haiku-4-5-20251001"), "claude-haiku-4-5")
        idx = pcs.CatalogIndex(["bedrock/us-east-1/anthropic.claude-x-v1:0", "us.anthropic.claude-x-v1:0"])
        self.assertEqual(idx.match_key("us.anthropic.claude-x"), "us.anthropic.claude-x-v1:0")
        # A Claude API id may use a partner cloud's global key; never a sibling.
        idx = pcs.CatalogIndex(["vertex_ai/claude-new-1", "claude-sonnet-5"])
        self.assertEqual(idx.match_key("claude-new-1"), "vertex_ai/claude-new-1")
        self.assertIsNone(idx.match_key("claude-sonnet-5-5"))


class MergeTests(unittest.TestCase):
    """The merge over the fixtures, checked by hand."""

    @classmethod
    def setUpClass(cls):
        cls.t = merged_fixtures()

    def one(self, *a, **k):
        rows = find(self.t, *a, **k)
        self.assertEqual(len(rows), 1, (a, k, rows))
        return rows[0]

    def test_a_majority_of_catalogs_overrides_litellm(self):
        r = self.one("claude-opus-5-5")
        self.assertEqual(mtok(r, "cacheRead"), 0.2)       # LiteLLM 0.5, models.dev and Catwalk 0.2
        self.assertEqual((r["fast"], r["regional"], r["source"]), (2.0, 1.1, "litellm"))
        self.assertEqual(r["derived"], [])

    def test_no_majority_keeps_litellm(self):
        self.assertEqual(mtok(self.one("claude-opus-4-7"), "output"), 25)  # models.dev 30, alone

    def test_secondaries_fill_models_litellm_lacks(self):
        fable = self.one("claude-fable-9")
        self.assertEqual(fable["source"], "models.dev")
        self.assertEqual(mtok(fable, "cacheRead"), 0.25)   # models.dev 0.25 vs Catwalk 0.3: first source
        self.assertEqual(mtok(fable, "cacheWrite1h"), 20)  # derived, 2x input
        self.assertEqual(fable["derived"], ["cacheWrite1h"])
        mythos = self.one("claude-mythos-9")
        self.assertEqual((mythos["source"], mtok(mythos, "input"), mtok(mythos, "cacheWrite5m")),
                         ("catwalk", 25, 31.25))

    def test_tiers(self):
        self.assertEqual(mtok(self.one("claude-sonnet-4-5", tier=200_000), "cacheWrite1h"), 12)
        haiku = self.one("claude-haiku-5-5", tier=100_000)
        self.assertEqual((mtok(haiku, "input"), mtok(haiku, "cacheWrite5m"), mtok(haiku, "cacheWrite1h")),
                         (0.5, 0.625, 1))
        self.assertEqual(sorted(haiku["derived"]), ["cacheWrite1h", "cacheWrite5m"])

    def test_partner_cloud_ids(self):
        self.assertEqual(mtok(self.one("claude-sonnet-4-5", "bedrock", "us"), "cacheRead"), 0.33)
        self.assertEqual(mtok(self.one("claude-sonnet-4-5", "bedrock", "apac"), "input"), 3.3)
        self.assertEqual(mtok(self.one("claude-sonnet-4-5", "vertex", "global"), "input"), 3)
        self.assertEqual(mtok(self.one("claude-opus-4-5", "foundry", "global"), "input"), 5)
        self.assertEqual(mtok(self.one("claude-3-7-sonnet", "bedrock", "us-gov"), "input"), 3.6)
        self.assertEqual(mtok(self.one("claude-haiku-4-5", "bedrock", "eu"), "output"), 5.5)
        self.assertEqual(mtok(self.one("claude-3-5-sonnet", "bedrock", "global"), "input"), 3)

    def test_rows_the_app_drops_are_dropped(self):
        models = {r["model"] for r in self.t}
        for gone in ("claude-placeholder-9", "claude-badtype-1", "claude-boolean-1", "claude-halftoken-1",
                     "claude-zero", "claude-nocost", "gpt-4o"):
            self.assertNotIn(gone, models)
        self.assertNotIn("other", {r["provider"] for r in self.t})
        self.assertIn("claude-outputonly-1", models)

    def test_catwalk_reads_both_shapes(self):
        flat = pcs.catwalk_entries({"models": [{"id": "a", "cost_per_1m_in": 10, "cost_per_1m_in_cached": 12.5,
                                                 "cost_per_1m_out_cached": 1}]})
        nested = pcs.catwalk_entries({"models": [{"id": "a", "pricing": {"input": 10, "cache_create": 12.5,
                                                                       "cache_hit": 1}}]})
        self.assertEqual(flat, nested)
        self.assertEqual(flat["a"]["cache_creation_input_token_cost"], 12.5 / 1e6)  # the write rate
        self.assertEqual(flat["a"]["cache_read_input_token_cost"], 1 / 1e6)         # the read rate

    def test_garbage_is_refused(self):
        lite, md, cw = load("litellm.json"), load("models-dev.json"), load("catwalk.json")
        with self.assertRaises(pcs.SyncError):
            pcs.merge_catalogs([], md, cw)
        with self.assertRaises(pcs.SyncError):
            pcs.merge_catalogs({"x": "y"}, md, cw)
        with self.assertRaises(pcs.SyncError):   # a missing secondary would flip votes for one run
            pcs.merge_catalogs(lite, {"openai": {}}, cw)
        with self.assertRaises(pcs.SyncError):   # far fewer Claude ids than a real LiteLLM
            pcs.merge_catalogs(lite, md, cw)


class SyncTests(unittest.TestCase):
    NOW = utc("2026-11-25T18:00:00Z")

    def seed(self):
        doc, report = pcs.sync(copy.deepcopy(CURATED), fixture_templates(), self.NOW)
        return doc, report

    def test_first_run_opens_every_price_and_dates_curated_slots_from_their_curated_start(self):
        doc, report = self.seed()
        rows = doc["catalog"]["records"]
        self.assertEqual(len(rows), len(fixture_templates()))
        self.assertEqual(report["action"], "changed")
        by = {(r["model"], r["provider"], r["region"], r.get("tierAbovePromptTokens", 0)): r for r in rows}
        self.assertEqual(by[("claude-opus-5-5", "anthropic", "global", 0)]["effectiveFrom"], "2026-09-22")
        self.assertEqual(by[("claude-sonnet-4-5", "anthropic", "global", 0)]["effectiveFrom"], "2025-09-29")
        # Another tier of a curated model is another slot: first seen now.
        self.assertEqual(by[("claude-sonnet-4-5", "anthropic", "global", 200000)]["effectiveFrom"],
                         "2026-11-25T18:00:00Z")
        self.assertEqual(by[("claude-sonnet-4-5", "bedrock", "us", 0)]["effectiveFrom"], "2026-11-25T18:00:00Z")
        self.assertTrue(all(r["effectiveTo"] is None for r in rows))
        self.assertEqual(doc["catalog"]["changedAt"], "2026-11-25T18:00:00Z")
        self.assertEqual(doc["catalog"]["checkedAt"], "2026-11-25T18:00:00Z")

    def test_curated_part_and_asof_are_untouched(self):
        doc, _ = self.seed()
        self.assertEqual(doc["records"], CURATED["records"])
        self.assertEqual(doc["asOf"], "2026-11-11")

    def test_unchanged_writes_nothing(self):
        doc, _ = self.seed()
        again, report = pcs.sync(doc, fixture_templates(), self.NOW + timedelta(hours=6))
        self.assertIsNone(again)
        self.assertEqual(report["action"], "unchanged")

    def test_a_quiet_week_writes_a_heartbeat_only(self):
        doc, _ = self.seed()
        later = self.NOW + timedelta(days=7)
        beat, report = pcs.sync(doc, fixture_templates(), later)
        self.assertEqual(report["action"], "heartbeat")
        self.assertEqual(beat["catalog"]["checkedAt"], pcs.fmt_date(later))
        self.assertEqual(beat["catalog"]["changedAt"], doc["catalog"]["changedAt"])
        self.assertEqual(beat["catalog"]["records"], doc["catalog"]["records"])

    def test_a_price_change_closes_the_open_record_and_opens_a_dated_one(self):
        doc, _ = self.seed()
        t = fixture_templates()
        r = find(t, "claude-opus-4-7")[0]
        r["rates"] = dict(r["rates"], output=3e-05)
        later = self.NOW + timedelta(days=3, hours=6)
        after, report = pcs.sync(doc, t, later)
        self.assertEqual((len(report["opened"]), len(report["closed"])), (1, 1))
        rows = [x for x in after["catalog"]["records"]
                if x["model"] == "claude-opus-4-7" and x["provider"] == "anthropic"]
        self.assertEqual(len(rows), 2)
        old, new = sorted(rows, key=lambda x: x["effectiveFrom"])
        self.assertEqual((old["effectiveFrom"], old["effectiveTo"]), ("2026-11-25T18:00:00Z", pcs.fmt_date(later)))
        self.assertEqual((new["effectiveFrom"], new["effectiveTo"], new["perMTok"]["output"]),
                         (pcs.fmt_date(later), None, 30))
        self.assertEqual(after["catalog"]["changedAt"], pcs.fmt_date(later))
        # Every Mac gets the same date: it is the job's observation time, in the file.
        self.assertEqual(len(after["catalog"]["records"]), len(doc["catalog"]["records"]) + 1)

    def test_a_change_back_is_a_third_record_never_an_edit(self):
        doc, _ = self.seed()
        t = fixture_templates()
        r = find(t, "claude-opus-4-7")[0]
        orig = dict(r["rates"])
        r["rates"] = dict(orig, output=3e-05)
        d2, _ = pcs.sync(doc, t, self.NOW + timedelta(days=1))
        r["rates"] = orig
        d3, report = pcs.sync(d2, t, self.NOW + timedelta(days=2))
        rows = [x for x in d3["catalog"]["records"] if x["model"] == "claude-opus-4-7" and x["provider"] == "anthropic"]
        self.assertEqual([x["perMTok"]["output"] for x in sorted(rows, key=lambda x: x["effectiveFrom"])], [25, 30, 25])

    def test_a_model_that_leaves_every_catalog_keeps_its_open_record(self):
        doc, _ = self.seed()
        t = [x for x in fixture_templates() if x["model"] != "claude-fable-9"]
        after, report = pcs.sync(doc, t, self.NOW + timedelta(hours=6))
        self.assertIsNone(after)                       # nothing to write
        later, _ = pcs.sync(doc, t, self.NOW + timedelta(days=8))  # the heartbeat keeps it too
        fable = [x for x in later["catalog"]["records"] if x["model"] == "claude-fable-9"]
        self.assertEqual(len(fable), 1)
        self.assertIsNone(fable[0]["effectiveTo"])

    def test_a_model_that_comes_back_after_a_change_starts_now_not_at_its_curated_start(self):
        doc, _ = self.seed()
        t = fixture_templates()
        r = find(t, "claude-opus-5-5")[0]
        r["rates"] = dict(r["rates"], input=3e-06)
        later = self.NOW + timedelta(days=1)
        after, _ = pcs.sync(doc, t, later)
        rows = sorted((x for x in after["catalog"]["records"] if x["model"] == "claude-opus-5-5"),
                      key=lambda x: x["effectiveFrom"])
        self.assertEqual([x["effectiveFrom"] for x in rows], ["2026-09-22", pcs.fmt_date(later)])

    def test_a_mass_change_or_a_unit_slip_is_refused_unless_accepted(self):
        doc, _ = self.seed()
        scaled = fixture_templates()
        for x in scaled:
            x["rates"] = {k: v * 1000 for k, v in x["rates"].items()}
        with self.assertRaises(pcs.SyncError) as e:
            pcs.sync(copy.deepcopy(doc), scaled, self.NOW + timedelta(days=1))
        self.assertIn("broken catalog", str(e.exception))
        one = fixture_templates()
        x = find(one, "claude-opus-4-7")[0]
        x["rates"] = dict(x["rates"], input=x["rates"]["input"] * 20)
        with self.assertRaises(pcs.SyncError):
            pcs.sync(copy.deepcopy(doc), one, self.NOW + timedelta(days=1))
        after, report = pcs.sync(copy.deepcopy(doc), one, self.NOW + timedelta(days=1), accept_mass_change=True)
        self.assertEqual(len(report["closed"]), 1)

    def test_a_first_listing_at_no_cost_is_refused_unless_accepted(self):
        full = merged_fixtures()   # with claude-outputonly-1: $0 input
        with self.assertRaises(pcs.SyncError) as e:
            pcs.sync(copy.deepcopy(CURATED), full, self.NOW)
        self.assertIn("claude-outputonly-1", str(e.exception))
        self.assertIn("first time", str(e.exception))
        doc, _ = pcs.sync(copy.deepcopy(CURATED), full, self.NOW, accept_mass_change=True)
        self.assertTrue(any(r["model"] == "claude-outputonly-1" for r in doc["catalog"]["records"]))
        # A later zero is a correction, caught by the existing guard.
        doc, _ = self.seed()
        t = fixture_templates()
        x = find(t, "claude-opus-4-7")[0]
        x["rates"] = dict(x["rates"], output=0.0)
        with self.assertRaises(pcs.SyncError):
            pcs.sync(doc, t, self.NOW + timedelta(days=1))

    def test_a_forced_heartbeat_rewrites_only_checkedAt(self):
        doc, _ = self.seed()
        later = self.NOW + timedelta(hours=6)
        self.assertIsNone(pcs.sync(copy.deepcopy(doc), fixture_templates(), later)[0])
        beat, report = pcs.sync(copy.deepcopy(doc), fixture_templates(), later, heartbeat=True)
        self.assertEqual(report["action"], "heartbeat")
        self.assertEqual(beat["catalog"]["checkedAt"], pcs.fmt_date(later))
        self.assertEqual(beat["catalog"]["changedAt"], doc["catalog"]["changedAt"])
        self.assertEqual(beat["catalog"]["records"], doc["catalog"]["records"])
        self.assertEqual(beat["records"], doc["records"])

    def test_a_clock_behind_the_file_stops_the_run(self):
        doc, _ = self.seed()
        t = fixture_templates()
        x = find(t, "claude-opus-4-7")[0]
        x["rates"] = dict(x["rates"], output=3e-05)
        with self.assertRaises(pcs.SyncError):
            pcs.sync(doc, t, self.NOW - timedelta(days=1))

    def test_nothing_lost_catches_a_dropped_or_rewritten_record(self):
        doc, _ = self.seed()
        dropped = copy.deepcopy(doc)
        dropped["catalog"]["records"].pop()
        with self.assertRaises(pcs.SyncError):
            pcs.check_nothing_lost(doc, dropped)
        rewritten = copy.deepcopy(doc)
        rewritten["catalog"]["records"][0]["perMTok"]["input"] = 99
        with self.assertRaises(pcs.SyncError):
            pcs.check_nothing_lost(doc, rewritten)
        curated = copy.deepcopy(doc)
        curated["records"][0]["note"] = "edited"
        with self.assertRaises(pcs.SyncError):
            pcs.check_nothing_lost(doc, curated)

    def test_check_file_refuses_what_the_app_would(self):
        doc, _ = self.seed()
        for mutate in (
            lambda d: d.update(schema=2),
            lambda d: d["catalog"]["records"][0].update(provider="openrouter"),
            lambda d: d["catalog"]["records"][0]["perMTok"].update(input=-1),
            lambda d: d["catalog"]["records"][0].update(effectiveTo="2000-01-01"),
            lambda d: d["catalog"]["records"].append(copy.deepcopy(d["catalog"]["records"][0])),
            lambda d: d["catalog"].update(checkedAt="2000-01-01"),
            lambda d: d["catalog"]["records"][0].update(source="nowhere"),
            lambda d: d["catalog"]["records"][0].update(regionalMultiplier=-1.1),
            lambda d: d["catalog"]["records"][0].update(fastMultiplier=-2),
        ):
            bad = copy.deepcopy(doc)
            mutate(bad)
            with self.assertRaises(pcs.SyncError):
                pcs.check_file(bad)


class FileTests(unittest.TestCase):

    def test_render_keeps_the_real_file_byte_for_byte_and_puts_a_record_per_line(self):
        path = ROOT / "site/public/price-history.json"
        text = path.read_text(encoding="utf-8")
        doc = json.loads(text)
        doc.pop("catalog", None)
        self.assertEqual(pcs.render(doc), json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
        if "catalog" not in json.loads(text):
            self.assertEqual(pcs.render(doc), text)
        seeded, _ = pcs.sync(doc, fixture_templates(), utc("2026-11-25T18:00:00Z"))
        out = pcs.render(seeded)
        self.assertEqual(json.loads(out), seeded)
        plain = pcs.render(doc)
        self.assertTrue(out.startswith(plain.rstrip()[:-1].rstrip()))  # the curated part, unchanged
        lines = [l for l in out.splitlines() if l.startswith('      {"model"')]
        self.assertEqual(len(lines), len(seeded["catalog"]["records"]))

    def test_the_cli_writes_only_on_change_and_never_in_a_dry_run(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "ph.json"
            f.write_text(json.dumps(CURATED, indent=2) + "\n")
            before = f.read_text()
            args = ["--file", str(f), "--litellm", str(FIXTURES / "litellm.json"),
                    "--models-dev", str(FIXTURES / "models-dev.json"), "--catwalk", str(FIXTURES / "catwalk.json"),
                    "--now", "2026-11-25T18:00:00Z"]
            # The fixtures are far smaller than a real LiteLLM, so the guard
            # refuses them: exit 1 and nothing written.
            self.assertEqual(pcs.main(["sync", *args]), 1)
            self.assertEqual(f.read_text(), before)
            saved = pcs.MIN_LITELLM_IDS, pcs.MIN_SECONDARY_ENTRIES
            pcs.MIN_LITELLM_IDS, pcs.MIN_SECONDARY_ENTRIES = 1, 1
            try:
                # The fixtures' $0-input model trips the first-listing guard.
                self.assertEqual(pcs.main(["sync", *args]), 1)
                self.assertEqual(f.read_text(), before)
                args.append("--accept-mass-change")
                self.assertEqual(pcs.main(["sync", "--dry-run", *args]), 0)
                self.assertEqual(f.read_text(), before)
                self.assertEqual(pcs.main(["sync", *args]), 0)
                written = f.read_text()
                self.assertNotEqual(written, before)
                later = [a if a != "2026-11-25T18:00:00Z" else "2026-11-26T00:00:00Z" for a in args]
                self.assertEqual(pcs.main(["sync", *later]), 0)
                self.assertEqual(f.read_text(), written)
                self.assertEqual(pcs.main(["sync", *later, "--heartbeat"]), 0)
                self.assertIn('"checkedAt": "2026-11-26"', f.read_text())
            finally:
                pcs.MIN_LITELLM_IDS, pcs.MIN_SECONDARY_ENTRIES = saved

    def test_graft_publishes_the_release_curated_part_with_the_site_catalog(self):
        site, _ = pcs.sync(copy.deepcopy(CURATED), fixture_templates(), utc("2026-11-25T18:00:00Z"))
        release = copy.deepcopy(CURATED)
        release["asOf"] = "2026-12-01"
        release["records"][0]["note"] = "re-reviewed"
        out = pcs.graft(release, site)
        self.assertEqual(out["records"], release["records"])
        self.assertEqual(out["asOf"], "2026-12-01")
        self.assertEqual(out["catalog"], site["catalog"])
        self.assertNotIn("catalog", pcs.graft(release, {}))

    def test_the_commit_message_names_the_change_and_never_skips_ci(self):
        doc, _ = pcs.sync(copy.deepcopy(CURATED), fixture_templates(), utc("2026-11-25T18:00:00Z"))
        t = fixture_templates()
        x = find(t, "claude-opus-4-7")[0]
        x["rates"] = dict(x["rates"], output=3e-05)
        _, report = pcs.sync(doc, t, utc("2026-11-26T00:41:00Z"))
        msg = pcs.commit_message(report)
        self.assertTrue(msg.startswith("Prices: catalog price list: claude-opus-4-7 (1 opened, 1 closed)"), msg)
        self.assertIn("- closed claude-opus-4-7 anthropic/global from 2026-11-25T18:00:00Z to 2026-11-26T00:41:00Z", msg)
        self.assertIn("curated start date", msg)
        _, beat = pcs.sync(doc, fixture_templates(), utc("2026-12-03T00:00:00Z"))
        for m in (msg, pcs.commit_message(beat)):
            self.assertNotRegex(m.lower(), r"\[(skip|no) ?ci\]|\[ci skip\]|\*\*\*no_ci\*\*\*")

    def test_review_shift_warns_when_a_release_review_would_override_a_list_price(self):
        site, _ = pcs.sync(copy.deepcopy(CURATED), fixture_templates(), utc("2026-11-25T18:00:00Z"))
        # The list saw Opus 5.5's read rate change on 2026-11-20, after the
        # 2026-11-11 review: news, so the list's price wins on Macs today.
        t = fixture_templates()
        x = find(t, "claude-opus-5-5")[0]
        x["rates"] = dict(x["rates"], cacheRead=1e-07)
        site, _ = pcs.sync(site, t, utc("2026-11-26T00:00:00Z"))
        same = copy.deepcopy(site)
        self.assertEqual(pcs.review_shift(same, site), [])
        moved = copy.deepcopy(site)
        moved["asOf"] = "2026-12-01"
        lines = pcs.review_shift(moved, site)
        self.assertEqual(len(lines), 1, lines)
        self.assertIn("claude-opus-5-5", lines[0])
        self.assertIn("2026-11-11 → 2026-12-01", lines[0])
        # A review date pinned on the row keeps it where it was.
        pinned = copy.deepcopy(moved)
        for r in pinned["records"]:
            r["reviewedAt"] = "2026-11-11"
        self.assertEqual(pcs.review_shift(pinned, site), [])

    def test_templates_command_prints_json_rows(self):
        out = subprocess.run([sys.executable, "-I", str(SCRIPT), "templates", "--litellm", str(FIXTURES / "litellm.json"),
                              "--models-dev", str(FIXTURES / "models-dev.json"), "--catwalk",
                              str(FIXTURES / "catwalk.json")], check=True, capture_output=True, text=True).stdout
        rows = json.loads(out)
        self.assertEqual(len(rows), len(merged_fixtures()))
        self.assertTrue(all(r["effectiveFrom"] == "1970-01-01" for r in rows))


if __name__ == "__main__":
    unittest.main(verbosity=1)
