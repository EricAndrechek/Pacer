#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Catch catalog price changes the curated price history doesn't have yet (#330).

Pacer prices every request from a dated ledger. Its exact dates come only from
the curated `price-history.json`; a catalog change it doesn't cover is dated by
whenever each install first sees it, and a model with no curated row at all is
priced at today's catalog rate for all of its history. This job closes that gap
by telling a maintainer, the day it happens.

Daily, it reads the first-party Anthropic rows of the catalogs Pacer itself
reads (LiteLLM, models.dev) plus Anthropic's pricing page, and flags:

  (a) a rate vector that differs from the curated record open today;
  (b) a first-party model with no curated row at all.

Each finding becomes one GitHub issue (keyed by model, tier and kind, so a
change seen by two sources is one issue). When the same key is already open
and the evidence has moved on, it comments instead; when the evidence is the
same, it does nothing. An issue closed with the same evidence is never raised
again, so closing as "not planned" is how a maintainer dismisses a known
difference.

Stdlib only.

    uv run research/price-history/watch_catalog_prices.py --dry-run
    uv run research/price-history/watch_catalog_prices.py --offline --dry-run \\
        --litellm F --models-dev F --page F --existing-issues F

`--dry-run` never writes to GitHub. `--offline` never touches the network:
sources come from files, evidence commits from `--*-commit`, existing issues
from `--existing-issues`. The tests (`test_watch_catalog_prices.py`) run both.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CURATED = ROOT / "PacerCore/Sources/PacerCore/Resources/price-history.json"

# The same URLs the app reads (PricingTable / ModelsDevCatalog), so the job
# sees what every install sees.
LITELLM_REPO, LITELLM_PATH = "BerriAI/litellm", "model_prices_and_context_window.json"
LITELLM_URL = f"https://raw.githubusercontent.com/{LITELLM_REPO}/main/{LITELLM_PATH}"
MODELS_DEV_REPO, MODELS_DEV_DIR = "sst/models.dev", "providers/anthropic/models"
MODELS_DEV_URL = "https://models.dev/api.json"
PAGE_URL = "https://platform.claude.com/docs/en/about-claude/pricing"
PAGE_MD_URL = PAGE_URL + ".md"
RELEASE_NOTES_URL = "https://platform.claude.com/docs/en/release-notes/overview"

LABEL = "area:pricing"
MARK_KEY = "price-watch:key="
MARK_FP = "price-watch:fingerprint="
UA = "pacer-price-watch (+https://github.com/EricAndrechek/Pacer)"

FIELDS = ("input", "output", "cacheWrite5m", "cacheWrite1h", "cacheRead")
FIELD_LABEL = {
    "input": "Input", "output": "Output", "cacheWrite5m": "5m cache write",
    "cacheWrite1h": "1h cache write", "cacheRead": "Cache read",
}
SOURCES = ("litellm", "models.dev", "page")
SOURCE_LABEL = {"litellm": "LiteLLM", "models.dev": "models.dev", "page": "Pricing page"}

Rates = dict  # field -> USD per million tokens
Observed = dict  # (model, tier) -> {"rates": Rates, "key": catalog key}


# ------------------------------------------------------------------ helpers

def canon(key: str) -> str:
    """A catalog key as the model id the curated file uses."""
    k = key.lower().strip()
    if k.startswith("anthropic/"):
        k = k[len("anthropic/"):]
    k = re.sub(r"\[[^\]]*\]$", "", k)    # [1m]
    k = re.sub(r"-v\d+:\d+$", "", k)     # Bedrock-style suffix on a plain key
    k = re.sub(r"-\d{8}$", "", k)        # date pin
    k = re.sub(r"-latest$", "", k)       # alias
    return k


def per_mtok(per_token) -> float | None:
    if not isinstance(per_token, (int, float)) or per_token <= 0:
        return None
    return round(per_token * 1_000_000, 6)


def mtok(v) -> float | None:
    if not isinstance(v, (int, float)) or v <= 0:
        return None
    return round(float(v), 6)


def same(a: float, b: float) -> bool:
    return abs(a - b) <= 1e-9 * max(1.0, abs(a), abs(b))


def money(v: float | None) -> str:
    if v is None:
        return "—"
    s = f"{v:.6f}".rstrip("0").rstrip(".")
    if "." in s and len(s.split(".")[1]) == 1:
        s += "0"
    return f"${s}"


def tier_label(tier: int) -> str:
    return "standard" if tier == 0 else f"prompts over {tier // 1000}k"


def keep(rates: Rates) -> bool:
    """A usable vector: placeholder rows with no input or output are skipped."""
    return rates.get("input") is not None or rates.get("output") is not None


# ------------------------------------------------------------------ sources

LL_BASE = {
    "input_cost_per_token": "input",
    "output_cost_per_token": "output",
    "cache_creation_input_token_cost": "cacheWrite5m",
    "cache_creation_input_token_cost_above_1hr": "cacheWrite1h",
    "cache_read_input_token_cost": "cacheRead",
}
LL_TIER = re.compile(r"^(.*)_above_(\d+)k_tokens$")


def parse_litellm(data: dict) -> Observed:
    """First-party rows only: `claude-*` / `anthropic/claude-*` keys that
    LiteLLM files under the `anthropic` provider (a Bedrock row can carry a
    plain `claude-` key)."""
    by_id: dict[tuple, dict[str, Rates]] = {}
    for key, v in data.items():
        if not isinstance(v, dict) or v.get("litellm_provider") != "anthropic":
            continue
        if not (key.startswith("claude-") or key.startswith("anthropic/claude-")):
            continue
        vectors: dict[int, Rates] = {}
        for f, val in v.items():
            if f in LL_BASE:
                if (x := per_mtok(val)) is not None:
                    vectors.setdefault(0, {})[LL_BASE[f]] = x
            elif (m := LL_TIER.match(f)) and m.group(1) in LL_BASE:
                if (x := per_mtok(val)) is not None:
                    vectors.setdefault(int(m.group(2)) * 1000, {})[LL_BASE[m.group(1)]] = x
        cid = canon(key)
        for tier, rates in vectors.items():
            if tier == 0 and not keep(rates):
                continue
            by_id.setdefault((cid, tier), {})[key] = rates
    return {k: _primary(k[0], keys) for k, keys in by_id.items()}


def _primary(cid: str, keys: dict[str, Rates]) -> dict:
    """The key named exactly like the model wins; a dated alias otherwise."""
    for pref in (cid, "anthropic/" + cid):
        if pref in keys:
            return {"rates": keys[pref], "key": pref}
    k = sorted(keys)[0]
    return {"rates": keys[k], "key": k}


def _md_rates(c: dict) -> Rates:
    r = {}
    for src, dst in (("input", "input"), ("output", "output"),
                     ("cache_read", "cacheRead"), ("cache_write", "cacheWrite5m")):
        if (x := mtok(c.get(src))) is not None:
            r[dst] = x
    return r


def parse_models_dev(data: dict) -> Observed:
    """The `anthropic` provider of models.dev's api.json, per-MTok dollars.
    `cache_write` is the 5-minute rate; there is no 1-hour rate to compare."""
    models = ((data.get("anthropic") or {}).get("models")) or {}
    by_id: dict[tuple, dict[str, Rates]] = {}
    for key, m in models.items():
        cost = m.get("cost") if isinstance(m, dict) else None
        if not isinstance(cost, dict):
            continue
        cid = canon(key)
        base = _md_rates(cost)
        if keep(base):
            by_id.setdefault((cid, 0), {})[key] = base
        for t in cost.get("tiers") or []:
            size = (t.get("tier") or {}).get("size") if isinstance(t, dict) else None
            if isinstance(size, int) and (r := _md_rates(t)):
                by_id.setdefault((cid, size), {})[key] = r
        if isinstance(cost.get("context_over_200k"), dict):
            if r := _md_rates(cost["context_over_200k"]):
                by_id.setdefault((cid, 200_000), {})[key] = r
    return {k: _primary(k[0], keys) for k, keys in by_id.items()}


PAGE_COLUMNS = {
    "base input tokens": "input", "5m cache writes": "cacheWrite5m",
    "1h cache writes": "cacheWrite1h", "cache hits and refreshes": "cacheRead",
    "output tokens": "output",
}


def page_model_id(name: str) -> str | None:
    """"Claude Opus 4.5" → claude-opus-4-5; the 3.x generation keeps its
    old order ("Claude Haiku 3.5" → claude-3-5-haiku)."""
    m = re.match(r"^Claude\s+(Opus|Sonnet|Haiku|Fable|Mythos)\s+(\d+)(?:\.(\d+))?$", name, re.I)
    if m:
        fam, major, minor = m.group(1).lower(), m.group(2), m.group(3)
        if major == "3":
            return f"claude-3-{minor}-{fam}" if minor else f"claude-3-{fam}"
        return f"claude-{fam}-{major}" + (f"-{minor}" if minor else "")
    m = re.match(r"^Claude\s+(Opus|Sonnet|Haiku|Fable|Mythos)\s+Preview$", name, re.I)
    return f"claude-{m.group(1).lower()}-preview" if m else None


def parse_page(text: str) -> tuple[Observed, list[str]]:
    """The "Model pricing" table of the pricing page's Markdown rendering."""
    out: Observed = {}
    skipped: list[str] = []
    lines = text.splitlines()
    cols = None
    for line in lines:
        if not line.lstrip().startswith("|"):
            if cols is not None:
                break  # end of the table
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if cols is None:
            lowered = [c.lower() for c in cells]
            if "base input tokens" in lowered:
                cols = {i: PAGE_COLUMNS[c] for i, c in enumerate(lowered) if c in PAGE_COLUMNS}
            continue
        if set(cells[0]) <= set(":- "):
            continue  # the separator row
        name = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", cells[0])
        tier = 0
        if (t := re.search(r"over ([\d,]+) tokens", name)):
            tier = int(t.group(1).replace(",", ""))
        name = re.sub(r"\s*\([^)]*\)", "", name).strip()
        cid = page_model_id(name)
        if cid is None:
            skipped.append(name)
            continue
        rates = {}
        for i, f in cols.items():
            if i < len(cells) and (p := re.search(r"\$\s*([\d.,]+)", cells[i])):
                rates[f] = round(float(p.group(1).replace(",", "")), 6)
        if keep(rates):
            out[(cid, tier)] = {"rates": rates, "key": name}
    return out, skipped


# ------------------------------------------------------------------ curated

def open_record(records: list[dict], model: str, tier: int, today: str) -> dict | None:
    """The standard-speed record in force today for this model and tier."""
    best = None
    for r in records:
        if r.get("model") != model or r.get("speed"):
            continue
        if int(r.get("tierAbovePromptTokens") or 0) != tier:
            continue
        if r["effectiveFrom"] > today or (r.get("effectiveTo") and r["effectiveTo"] <= today):
            continue
        if best is None or r["effectiveFrom"] > best["effectiveFrom"]:
            best = r
    return best


# ------------------------------------------------------------------ findings

@dataclass
class Finding:
    kind: str                       # "rates" | "uncurated"
    model: str
    tier: int                       # 0 = standard; -1 = every tier (uncurated)
    record: dict | None             # the curated record open today
    observed: dict                  # source -> {tier: {"rates", "key"}}
    differing: list                 # sources whose rates differ
    notes: list = field(default_factory=list)
    evidence: dict = field(default_factory=dict)  # source -> text

    @property
    def key(self) -> str:
        t = "all" if self.tier < 0 else ("base" if self.tier == 0 else f"over{self.tier // 1000}k")
        return f"{self.model}|{t}|{self.kind}"

    @property
    def fingerprint(self) -> str:
        """What the differing sources say. The same fingerprint is the same
        news; a new one (a second source agreeing, or a further change) is
        worth a comment."""
        body = {s: {str(t): v["rates"] for t, v in sorted(self.observed[s].items())}
                for s in sorted(self.differing)}
        raw = json.dumps({"key": self.key, "says": body}, sort_keys=True)
        return hashlib.sha1(raw.encode()).hexdigest()[:12]

    @property
    def title(self) -> str:
        if self.kind == "uncurated":
            return f"Price watch: no curated price history for {self.model}"
        t = "" if self.tier == 0 else f" ({tier_label(self.tier)})"
        return f"Price watch: {self.model}{t} differs from the curated price history"


def find(sources: dict[str, Observed], records: list[dict], today: str) -> tuple[list[Finding], list[str]]:
    curated = {r["model"] for r in records}
    findings: list[Finding] = []
    notes: list[str] = []
    models = sorted({m for obs in sources.values() for (m, _) in obs})
    for model in models:
        seen = {s: {t: v for (m, t), v in obs.items() if m == model} for s, obs in sources.items()}
        seen = {s: v for s, v in seen.items() if v}
        if model not in curated:
            findings.append(Finding("uncurated", model, -1, None, seen, sorted(seen)))
            continue
        tiers = sorted({t for v in seen.values() for t in v}
                       | {int(r.get("tierAbovePromptTokens") or 0) for r in records
                          if r["model"] == model and open_record(records, model,
                                                                 int(r.get("tierAbovePromptTokens") or 0), today)})
        if open_record(records, model, 0, today) is None:
            notes.append(f"{model}: listed by {', '.join(SOURCE_LABEL[s] for s in sorted(seen))}, "
                         f"but every curated record has ended (retired).")
            continue
        for tier in tiers:
            rec = open_record(records, model, tier, today)
            differing, why = [], []
            for s, by_tier in seen.items():
                obs = by_tier.get(tier)
                if obs is None:
                    if rec is not None and tier != 0 and 0 in by_tier:
                        differing.append(s)
                        why.append(f"{SOURCE_LABEL[s]} no longer lists this tier.")
                    continue
                if rec is None:
                    differing.append(s)
                    why.append(f"{SOURCE_LABEL[s]} lists a tier the curated history has no open record for.")
                    continue
                cur = rec["perMTok"]
                if any(f in cur and not same(obs["rates"][f], cur[f]) for f in obs["rates"]):
                    differing.append(s)
            if differing:
                observed = {s: {tier: v[tier]} for s, v in seen.items() if tier in v}
                for s in differing:
                    observed.setdefault(s, {})
                findings.append(Finding("rates", model, tier, rec, observed, sorted(differing), why))
    return sorted(findings, key=lambda f: f.key), notes


# ------------------------------------------------------------------ network

class Net:
    def __init__(self, offline: bool, token: str | None):
        self.offline = offline
        self.token = token
        self.raw_cache: dict[str, bytes] = {}

    def get(self, url: str, auth: bool = False) -> bytes:
        if self.offline:
            raise RuntimeError("offline")
        headers = {"User-Agent": UA}
        if auth:
            headers["Accept"] = "application/vnd.github+json"
            if self.token:
                headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read()

    def api(self, path: str):
        return json.loads(self.get("https://api.github.com" + path, auth=True))

    def send(self, method: str, path: str, payload: dict):
        req = urllib.request.Request(
            "https://api.github.com" + path, method=method,
            data=json.dumps(payload).encode(),
            headers={"User-Agent": UA, "Accept": "application/vnd.github+json",
                     "Authorization": f"Bearer {self.token}",
                     "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"{}")


def commit_link(repo: str, sha: str, when: str) -> str:
    return f"[`{sha[:10]}`](https://github.com/{repo}/commit/{sha}) ({when[:10]})"


def litellm_evidence(net: Net, f: Finding, today: str, override: str | None) -> str:
    """The first LiteLLM commit whose row says what it says today: a bisect over
    the last 45 days of commits to the price file, a handful of fetches."""
    if override:
        sha, _, when = override.partition("@")
        return f"changed in {commit_link(LITELLM_REPO, sha, when or today)}"
    tier = f.tier if f.tier >= 0 else 0
    want = (f.observed.get("litellm") or {}).get(tier)
    since = (date.fromisoformat(today) - timedelta(days=45)).isoformat() + "T00:00:00Z"
    try:
        commits = []
        for page in range(1, 6):  # LiteLLM commits to this file several times a day
            batch = net.api(f"/repos/{LITELLM_REPO}/commits?path={LITELLM_PATH}"
                            f"&since={since}&per_page=100&page={page}")
            commits += [(c["sha"], c["commit"]["committer"]["date"]) for c in batch]
            if len(batch) < 100:
                break
        commits = commits[::-1]  # oldest first
        if not commits:
            return "no commit to the price file in the last 45 days"

        def says(i: int) -> bool:
            sha = commits[i][0]
            if sha not in net.raw_cache:
                net.raw_cache[sha] = net.get(
                    f"https://raw.githubusercontent.com/{LITELLM_REPO}/{sha}/{LITELLM_PATH}")
            row = parse_litellm(json.loads(net.raw_cache[sha])).get((f.model, tier))
            if want is None:
                return row is None
            return row is not None and row["rates"] == want["rates"]

        if says(0):
            sha, when = commits[0]
            return f"already so at {commit_link(LITELLM_REPO, sha, when)}, the oldest commit checked"
        lo, hi = 0, len(commits) - 1
        if not says(hi):
            sha, when = commits[hi]
            return f"latest commit {commit_link(LITELLM_REPO, sha, when)}"
        while hi - lo > 1:
            mid = (lo + hi) // 2
            lo, hi = (lo, mid) if says(mid) else (mid, hi)
        sha, when = commits[hi]
        return f"changed in {commit_link(LITELLM_REPO, sha, when)}"
    except (urllib.error.URLError, RuntimeError, KeyError, ValueError) as e:
        return f"commit lookup failed ({e})"


def models_dev_evidence(net: Net, f: Finding, today: str, override: str | None) -> str:
    if override:
        sha, _, when = override.partition("@")
        return f"changed in {commit_link(MODELS_DEV_REPO, sha, when or today)}"
    keys = {v["key"] for v in (f.observed.get("models.dev") or {}).values()} or {f.model}
    try:
        for path in [f"{MODELS_DEV_DIR}/{k}.toml" for k in sorted(keys)] + [MODELS_DEV_DIR]:
            q = urllib.parse.quote(path)
            c = net.api(f"/repos/{MODELS_DEV_REPO}/commits?path={q}&per_page=1")
            if c:
                what = "the model file's latest change" if path.endswith(".toml") else "latest change to the provider"
                return f"{what}: {commit_link(MODELS_DEV_REPO, c[0]['sha'], c[0]['commit']['committer']['date'])}"
        return "no commit found"
    except (urllib.error.URLError, RuntimeError, KeyError, ValueError) as e:
        return f"commit lookup failed ({e})"


def gather_evidence(net: Net, f: Finding, today: str, args) -> None:
    """Where each differing source says it. A source that agrees with the
    curated record is in the table; it is not evidence of a change."""
    for s in f.differing:
        if s == "litellm":
            f.evidence[s] = litellm_evidence(net, f, today, args.litellm_commit)
        elif s == "models.dev":
            f.evidence[s] = models_dev_evidence(net, f, today, args.models_dev_commit)
        elif s == "page":
            f.evidence[s] = f"[{PAGE_URL}]({PAGE_URL})"


# ------------------------------------------------------------------ issues

def render(f: Finding, today: str, first: bool) -> str:
    out = []
    if first:
        out.append(f"<!-- {MARK_KEY}{f.key} -->")
    out.append(f"<!-- {MARK_FP}{f.fingerprint} -->")
    if f.kind == "uncurated":
        out.append(f"**`{f.model}`** is listed by "
                   f"{', '.join(SOURCE_LABEL[s] for s in sorted(f.observed))} and has **no row** in the "
                   "curated price history. Until it has one, every install prices all of its history at "
                   "today's catalog rate.")
    else:
        rec = f.record
        span = (f"from {rec['effectiveFrom']}" + (f" to {rec['effectiveTo']}" if rec.get("effectiveTo") else ", open"))\
            if rec else "none open today"
        out.append(f"**`{f.model}`** ({tier_label(f.tier)}). Curated record: {span}.")
        out.append(f"Differs: {', '.join(SOURCE_LABEL[s] for s in f.differing)}.")
    out.append("")
    tiers = sorted({t for v in f.observed.values() for t in v} | ({f.tier} if f.tier >= 0 else set()))
    for t in tiers:
        rec = f.record if f.kind == "rates" else None
        srcs = [s for s in SOURCES if s in f.observed]
        if f.kind == "uncurated":
            out.append(f"**{tier_label(t).capitalize()}**")
            out.append("")
        head = (["Curated (open)"] if f.kind == "rates" else []) + [SOURCE_LABEL[s] for s in srcs]
        out.append("| per MTok | " + " | ".join(head) + " |")
        out.append("|---|" + "---|" * len(head))
        for fld in FIELDS:
            cur = (rec or {}).get("perMTok", {}).get(fld) if rec else None
            row = [money(cur)] if f.kind == "rates" else []
            for s in srcs:
                v = (f.observed[s].get(t) or {}).get("rates", {}).get(fld)
                cell = money(v)
                if v is not None and cur is not None and not same(v, cur):
                    cell = f"**{cell}**"
                row.append(cell)
            out.append(f"| {FIELD_LABEL[fld]} | " + " | ".join(row) + " |")
        out.append("")
    if f.notes:
        out += [f"- {n}" for n in f.notes] + [""]
    out.append(f"**Evidence** (seen {today}):")
    for s in SOURCES:
        if s in f.evidence:
            keys = sorted({v['key'] for v in f.observed[s].values()})
            k = f" — `{', '.join(keys)}`" if keys and s != "page" else ""
            out.append(f"- {SOURCE_LABEL[s]}{k}: {f.evidence[s]}")
    if first:
        out += ["",
                "**To resolve:** confirm the effective date against the pricing page and the "
                f"[release notes]({RELEASE_NOTES_URL}), add the record to "
                "`research/price-history/build_curated.py`, regenerate `price-history.json`, and close "
                "this issue. To dismiss a known difference, close it as *not planned*: the job does not "
                "raise the same rates again.",
                "",
                "🤖 Opened by the Price watch workflow (#330)"]
    return "\n".join(out)


def parse_markers(text: str) -> tuple[str | None, list[str]]:
    key = re.search(r"<!--\s*" + re.escape(MARK_KEY) + r"(.+?)\s*-->", text or "")
    fps = re.findall(r"<!--\s*" + re.escape(MARK_FP) + r"(\w+)\s*-->", text or "")
    return (key.group(1) if key else None), fps


def load_existing(net: Net, repo: str, path: str | None) -> list[dict]:
    """Issues this job opened: number, state, key, latest fingerprint."""
    if path:
        return json.loads(Path(path).read_text())
    if net.offline:
        return []
    seen, out = set(), []
    for q in (f"labels={urllib.parse.quote(LABEL)}", "creator=" + urllib.parse.quote("github-actions[bot]")):
        for page in range(1, 6):
            batch = net.api(f"/repos/{repo}/issues?state=all&per_page=100&page={page}&{q}")
            for i in batch:
                if "pull_request" in i or i["number"] in seen:
                    continue
                key, fps = parse_markers(i.get("body") or "")
                if not key:
                    continue
                seen.add(i["number"])
                if i.get("comments"):
                    for c in net.api(f"/repos/{repo}/issues/{i['number']}/comments?per_page=100"):
                        fps += parse_markers(c.get("body") or "")[1]
                out.append({"number": i["number"], "state": i["state"], "key": key,
                            "fingerprint": fps[-1] if fps else None})
            if len(batch) < 100:
                break
    return out


def decide(f: Finding, existing: list[dict]) -> tuple[str, int | None]:
    """("open", None) | ("comment", n) | ("skip", n)."""
    same_key = [i for i in existing if i["key"] == f.key]
    for i in same_key:
        if i["state"] == "open":
            return ("skip", i["number"]) if i["fingerprint"] == f.fingerprint else ("comment", i["number"])
    for i in same_key:
        if i["fingerprint"] == f.fingerprint:
            return ("skip", i["number"])  # closed with this exact news: handled or dismissed
    return ("open", None)


# ------------------------------------------------------------------ main

def load_source(net: Net, name: str, path: str | None, url: str, errors: list[str]):
    try:
        if path:
            return Path(path).read_bytes()
        return net.get(url)
    except Exception as e:  # a source being down is a note, not a crash
        errors.append(f"{SOURCE_LABEL[name]}: unavailable ({e})")
        return None


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--curated", default=str(CURATED))
    p.add_argument("--litellm", help="LiteLLM price JSON file instead of the live one")
    p.add_argument("--models-dev", help="models.dev api.json file instead of the live one")
    p.add_argument("--page", help="pricing page Markdown file instead of the live one")
    p.add_argument("--no-page", action="store_true", help="skip the pricing page")
    p.add_argument("--litellm-commit", help="evidence override, SHA[@ISO date]")
    p.add_argument("--models-dev-commit", help="evidence override, SHA[@ISO date]")
    p.add_argument("--existing-issues", help="JSON list of {number,state,key,fingerprint}")
    p.add_argument("--today", default=datetime.now(timezone.utc).date().isoformat())
    p.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "EricAndrechek/Pacer"))
    p.add_argument("--dry-run", action="store_true", help="never write to GitHub")
    p.add_argument("--offline", action="store_true", help="never touch the network")
    args = p.parse_args(argv)

    token = os.environ.get("GITHUB_TOKEN")
    if not args.dry_run and not token:
        print("refusing to write issues without GITHUB_TOKEN (use --dry-run)", file=sys.stderr)
        return 2
    net = Net(args.offline, token)
    curated = json.loads(Path(args.curated).read_text())
    records = curated["records"]

    errors: list[str] = []
    sources: dict[str, Observed] = {}
    skipped_page: list[str] = []
    if (b := load_source(net, "litellm", args.litellm, LITELLM_URL, errors)) is not None:
        sources["litellm"] = parse_litellm(json.loads(b))
    if (b := load_source(net, "models.dev", args.models_dev, MODELS_DEV_URL, errors)) is not None:
        sources["models.dev"] = parse_models_dev(json.loads(b))
    if not args.no_page and (b := load_source(net, "page", args.page, PAGE_MD_URL, errors)) is not None:
        sources["page"], skipped_page = parse_page(b.decode("utf-8", "replace"))
        if not sources["page"]:
            errors.append("Pricing page: fetched, but no model table parsed")
    if not sources:
        print("\n".join(errors) or "no sources", file=sys.stderr)
        return 1

    findings, notes = find(sources, records, args.today)
    existing = load_existing(net, args.repo, args.existing_issues)

    lines = [f"Price watch {args.today}: curated asOf {curated.get('asOf')}, {len(records)} records.",
             "Sources: " + ", ".join(f"{SOURCE_LABEL[s]} {len({m for m, _ in o})} models"
                                     for s, o in sources.items()) + "."]
    lines += [f"Note: {e}" for e in errors + notes]
    if skipped_page:
        lines.append(f"Note: pricing page rows not recognised as a model: {', '.join(skipped_page)}")
    if not findings:
        lines.append("No differences from the curated price history.")

    status = 0
    for f in findings:
        action, number = decide(f, existing)
        lines.append(f"- [{f.kind}] {f.key} ({', '.join(SOURCE_LABEL[s] for s in f.differing)}), "
                     f"fingerprint {f.fingerprint}: "
                     + {"open": "open an issue", "comment": f"comment on #{number}",
                        "skip": f"nothing new for #{number}"}[action])
        if action == "skip":
            continue
        gather_evidence(net, f, args.today, args)
        body = render(f, args.today, first=(action == "open"))
        if args.dry_run:
            lines += ["", f"  would {'open' if action == 'open' else f'comment on #{number}'}: "
                      + (f.title if action == "open" else ""), "",
                      *("    " + ln for ln in body.splitlines()), ""]
            continue
        try:
            if action == "open":
                made = net.send("POST", f"/repos/{args.repo}/issues",
                                {"title": f.title, "body": body, "labels": [LABEL]})
                lines.append(f"  opened #{made.get('number')}")
            else:
                net.send("POST", f"/repos/{args.repo}/issues/{number}/comments", {"body": body})
                lines.append(f"  commented on #{number}")
        except urllib.error.HTTPError as e:
            lines.append(f"  GitHub refused: {e.code} {e.read()[:200]!r}")
            status = 1

    report = "\n".join(lines)
    print(report)
    if (summary := os.environ.get("GITHUB_STEP_SUMMARY")):
        with open(summary, "a") as fh:
            fh.write(report + "\n")
    return status


if __name__ == "__main__":
    sys.exit(main())
