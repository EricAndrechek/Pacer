# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Tests for the price watch (#330). Offline: every catalog is a synthetic
file built from the curated history itself, so "unchanged" means exactly the
curated rates, and a test changes one number to make a finding.

    uv run research/price-history/test_watch_catalog_prices.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True  # no __pycache__ beside the research scripts
spec = importlib.util.spec_from_file_location("watch", HERE / "watch_catalog_prices.py")
watch = importlib.util.module_from_spec(spec)
sys.modules["watch"] = watch
spec.loader.exec_module(watch)

TODAY = "2026-10-21"
CURATED = json.loads(watch.CURATED.read_text())
RECORDS = CURATED["records"]
SHA = "0123456789abcdef0123456789abcdef01234567"


def open_models() -> dict[tuple, dict]:
    """(model, tier) -> the standard record open on TODAY, for every model
    whose base tier is open (a retired model is not listed anywhere)."""
    out = {}
    for model in sorted({r["model"] for r in RECORDS}):
        if watch.open_record(RECORDS, model, 0, TODAY) is None:
            continue
        for tier in sorted({int(r.get("tierAbovePromptTokens") or 0) for r in RECORDS if r["model"] == model}):
            if (rec := watch.open_record(RECORDS, model, tier, TODAY)):
                out[(model, tier)] = rec
    return out


def display_name(model: str) -> str:
    parts = model.split("-")[1:]
    if parts[0] == "3":
        return f"Claude {parts[2].title()} 3.{parts[1]}"
    if parts[-1] == "preview":
        return f"Claude {parts[0].title()} Preview"
    return f"Claude {parts[0].title()} " + ".".join(parts[1:])


def litellm_fixture() -> dict:
    rows: dict[str, dict] = {}
    names = {0: "", **{t: f"_above_{t // 1000}k_tokens" for (_, t) in open_models() if t}}
    for (model, tier), rec in open_models().items():
        row = rows.setdefault(model, {"litellm_provider": "anthropic", "mode": "chat"})
        r, sfx = rec["perMTok"], names[tier]
        row["input_cost_per_token" + sfx] = r["input"] / 1e6
        row["output_cost_per_token" + sfx] = r["output"] / 1e6
        row["cache_creation_input_token_cost" + sfx] = r["cacheWrite5m"] / 1e6
        row["cache_creation_input_token_cost_above_1hr" + sfx] = r["cacheWrite1h"] / 1e6
        row["cache_read_input_token_cost" + sfx] = r["cacheRead"] / 1e6
        # Batch rates are a different product; the watch must ignore them.
        row["input_cost_per_token_batches" + sfx] = r["input"] / 2e6
    out = dict(rows)
    # A dated alias with the same rates, and a Bedrock row under a plain
    # `claude-` key at a different price: neither may produce a finding.
    first = sorted(rows)[0]
    out[first + "-20260101"] = dict(rows[first])
    out[first + "-v1:0"] = {**rows[first], "litellm_provider": "bedrock",
                            "input_cost_per_token": 99 / 1e6}
    return out


def models_dev_fixture() -> dict:
    models: dict[str, dict] = {}
    for (model, tier), rec in open_models().items():
        r = rec["perMTok"]
        c = {"input": r["input"], "output": r["output"], "cache_read": r["cacheRead"],
             "cache_write": r["cacheWrite5m"]}
        m = models.setdefault(model, {"id": model, "cost": {}})
        if tier == 0:
            m["cost"].update(c)
        else:
            m["cost"].setdefault("tiers", []).append({**c, "tier": {"type": "context", "size": tier}})
    return {"anthropic": {"id": "anthropic", "models": models},
            "openai": {"models": {"gpt-x": {"cost": {"input": 1, "output": 2}}}}}


def page_fixture() -> str:
    lines = ["## Model pricing", "",
             "| Model | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |",
             "| :---- | :---- | :---- | :---- | :---- | :---- |"]
    tiered = {m for (m, t) in open_models() if t}
    for (model, tier), rec in sorted(open_models().items()):
        r = rec["perMTok"]
        name = display_name(model)
        if model in tiered:
            name += f" (for prompts over {tier:,} tokens)" if tier else " (for prompts up to 100,000 tokens)"
        elif model.startswith("claude-3"):
            name += " ([retired, except on Google Cloud](https://example.com/deprecations))"
        cell = lambda v: f"${v:g} / MTok"
        lines.append(f"| {name} | {cell(r['input'])} | {cell(r['cacheWrite5m'])} | {cell(r['cacheWrite1h'])} "
                     f"| {cell(r['cacheRead'])}<sup>1</sup> | {cell(r['output'])} |")
    lines += ["", "*<sup>1 a footnote</sup>*", "", "## Batch processing", "",
              "| Model | Batch input | Batch output |", "| --- | --- | --- |",
              "| Claude Opus 5 | $2.50 / MTok | $12.50 / MTok |"]
    return "\n".join(lines) + "\n"


def sources(ll=None, md=None, page=None) -> dict:
    return {"litellm": watch.parse_litellm(ll or litellm_fixture()),
            "models.dev": watch.parse_models_dev(md or models_dev_fixture()),
            "page": watch.parse_page(page or page_fixture())[0]}


def a_model() -> str:
    return "claude-opus-5" if ("claude-opus-5", 0) in open_models() else sorted(open_models())[0][0]


class Unchanged(unittest.TestCase):
    def test_catalogs_that_match_the_curated_history_produce_nothing(self):
        findings, _ = watch.find(sources(), RECORDS, TODAY)
        self.assertEqual(findings, [])

    def test_every_open_model_is_read_from_every_source(self):
        s = sources()
        for name, obs in s.items():
            self.assertEqual(set(obs), set(open_models()), name)

    def test_bedrock_rows_and_batch_rates_are_ignored(self):
        obs = watch.parse_litellm(litellm_fixture())
        self.assertTrue(all(o["key"].startswith("claude-") and "-v1:0" not in o["key"] for o in obs.values()))


class Changes(unittest.TestCase):
    def test_a_changed_rate_is_one_finding_with_old_and_new_rates_and_evidence(self):
        model = a_model()
        ll = litellm_fixture()
        old = ll[model]["input_cost_per_token"] * 1e6
        ll[model]["input_cost_per_token"] = (old - 0.5) / 1e6
        findings, _ = watch.find(sources(ll=ll), RECORDS, TODAY)
        self.assertEqual([f.key for f in findings], [f"{model}|base|rates"])
        f = findings[0]
        self.assertEqual(f.differing, ["litellm"])
        f.evidence["litellm"] = watch.litellm_evidence(None, f, TODAY, f"{SHA}@2026-10-20T09:00:00Z")
        body = watch.render(f, TODAY, first=True)
        self.assertIn(model, f.title)
        self.assertIn(watch.money(old), body)                  # the curated (old) rate
        self.assertIn(f"**{watch.money(old - 0.5)}**", body)   # the new rate, marked
        self.assertIn(f"https://github.com/BerriAI/litellm/commit/{SHA}", body)
        self.assertIn("2026-10-20", body)                      # when it changed
        self.assertIn(f"seen {TODAY}", body)                   # when the job saw it
        key, fps = watch.parse_markers(body)
        self.assertEqual((key, fps), (f.key, [f.fingerprint]))

    def test_the_same_change_in_two_catalogs_is_still_one_issue(self):
        model = a_model()
        ll, md = litellm_fixture(), models_dev_fixture()
        ll[model]["output_cost_per_token"] *= 2
        md["anthropic"]["models"][model]["cost"]["output"] *= 2
        findings, _ = watch.find(sources(ll=ll, md=md), RECORDS, TODAY)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].differing, ["litellm", "models.dev"])

    def test_a_model_with_no_curated_row_is_flagged(self):
        md = models_dev_fixture()
        md["anthropic"]["models"]["claude-opus-6"] = {"cost": {"input": 6, "output": 30, "cache_read": 0.6,
                                                               "cache_write": 7.5}}
        findings, _ = watch.find(sources(md=md), RECORDS, TODAY)
        self.assertEqual([f.key for f in findings], ["claude-opus-6|all|uncurated"])
        body = watch.render(findings[0], TODAY, first=True)
        self.assertIn("no row", body)
        self.assertIn("$30", body)

    def test_a_tier_change_is_keyed_by_its_tier(self):
        tiered = [(m, t) for (m, t) in open_models() if t]
        if not tiered:
            self.skipTest("no open tier record in the curated history")
        model, tier = tiered[0]
        page = page_fixture().replace(
            f"over {tier:,} tokens) | ${open_models()[(model, tier)]['perMTok']['input']:g} / MTok",
            f"over {tier:,} tokens) | $9.99 / MTok")
        findings, _ = watch.find(sources(page=page), RECORDS, TODAY)
        self.assertEqual([f.key for f in findings], [f"{model}|over{tier // 1000}k|rates"])
        self.assertEqual(findings[0].differing, ["page"])


class Pages(unittest.TestCase):
    def test_page_names_links_footnotes_and_tiers(self):
        page = "\n".join([
            "| Model | Base input tokens | 5m cache writes | 1h cache writes | Cache hits and refreshes | Output tokens |",
            "| :-- | :-- | :-- | :-- | :-- | :-- |",
            "| Claude Fable 5.1 | $10 / MTok | $12.50 / MTok | $20 / MTok | $0.25 / MTok<sup>1</sup> | $50 / MTok |",
            "| Claude Opus 4 ([retired](https://x.test/d)) | $15 / MTok | $18.75 / MTok | $30 / MTok | $1.50 / MTok | $75 / MTok |",
            "| Claude Haiku 3.5 ([retired, except on Google Cloud](https://x.test/d)) | $0.80 / MTok | $1 / MTok | $1.60 / MTok | $0.08 / MTok | $4 / MTok |",
            "| Claude Haiku 5.5 (for prompts over 100,000 tokens) | $0.50 / MTok | $0.625 / MTok | $1 / MTok | $0.05 / MTok | $2.50 / MTok |",
            "| Claude Sonnet 5 | $2 / MTok<sup>3</sup> | $2.50 / MTok | $4 / MTok | $0.20 / MTok | $10 / MTok<sup>3</sup> |",
        ])
        obs, skipped = watch.parse_page(page)
        self.assertEqual(skipped, [])
        self.assertEqual(obs[("claude-fable-5-1", 0)]["rates"]["cacheRead"], 0.25)
        self.assertEqual(obs[("claude-opus-4", 0)]["rates"]["output"], 75)
        self.assertEqual(obs[("claude-3-5-haiku", 0)]["rates"]["input"], 0.8)
        self.assertEqual(obs[("claude-haiku-5-5", 100_000)]["rates"]["cacheWrite5m"], 0.625)
        self.assertEqual(obs[("claude-sonnet-5", 0)]["rates"]["output"], 10)


class Dedup(unittest.TestCase):
    def setUp(self):
        ll = litellm_fixture()
        ll[a_model()]["input_cost_per_token"] /= 2
        self.f = watch.find(sources(ll=ll), RECORDS, TODAY)[0][0]

    def issue(self, state, fp, n=7):
        return {"number": n, "state": state, "key": self.f.key, "fingerprint": fp}

    def test_no_issue_yet_opens_one(self):
        self.assertEqual(watch.decide(self.f, []), ("open", None))

    def test_an_open_issue_with_the_same_news_gets_nothing(self):
        self.assertEqual(watch.decide(self.f, [self.issue("open", self.f.fingerprint)]), ("skip", 7))

    def test_an_open_issue_with_older_news_gets_a_comment(self):
        self.assertEqual(watch.decide(self.f, [self.issue("open", "0ld")]), ("comment", 7))

    def test_a_closed_issue_with_the_same_news_is_not_raised_again(self):
        self.assertEqual(watch.decide(self.f, [self.issue("closed", self.f.fingerprint)]), ("skip", 7))

    def test_a_new_change_after_a_closed_issue_opens_a_new_one(self):
        self.assertEqual(watch.decide(self.f, [self.issue("closed", "0ld")]), ("open", None))


class Cli(unittest.TestCase):
    def run_cli(self, ll=None, md=None, page=None, existing=None):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "ll.json").write_text(json.dumps(ll or litellm_fixture()))
            (d / "md.json").write_text(json.dumps(md or models_dev_fixture()))
            (d / "page.md").write_text(page or page_fixture())
            (d / "issues.json").write_text(json.dumps(existing or []))
            argv = ["--offline", "--dry-run", "--today", TODAY,
                    "--litellm", str(d / "ll.json"), "--models-dev", str(d / "md.json"),
                    "--page", str(d / "page.md"), "--existing-issues", str(d / "issues.json"),
                    "--litellm-commit", f"{SHA}@2026-10-20T09:00:00Z",
                    "--models-dev-commit", f"{SHA[::-1]}@2026-10-19T12:00:00Z"]

            def refuse(*_a, **_k):
                raise AssertionError("a dry run wrote to GitHub")

            watch.Net.send = refuse
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = watch.main(argv)
            return code, out.getvalue()

    def test_unchanged_dry_run_reports_nothing(self):
        code, out = self.run_cli()
        self.assertEqual(code, 0)
        self.assertIn("No differences from the curated price history.", out)
        self.assertNotIn("would open", out)

    def test_changed_dry_run_shows_the_issue_and_writes_nothing(self):
        ll = litellm_fixture()
        ll[a_model()]["input_cost_per_token"] /= 2
        code, out = self.run_cli(ll=ll)
        self.assertEqual(code, 0)
        self.assertEqual(out.count("would open"), 1)
        self.assertIn(f"{a_model()}|base|rates", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
