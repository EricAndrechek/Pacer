#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""One-off research script: walk the git history of public model-price catalogs
(LiteLLM, models.dev) and report, per Anthropic Claude model, when it first
appeared and every date its prices changed.

Output is a CANDIDATE for human review against Anthropic's pricing page, not
the curated ledger.

    uv run research/price-history/seed_price_history.py \
        --out research/price-history/candidate-price-history.json \
        --report research/price-history/REPORT.md
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import re
import subprocess
import sys
import threading
import time
import tomllib
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

SINCE = "2025-01-01T00:00:00Z"
CACHE = Path("/tmp/pricing-core/seed-cache")
LITELLM_REPO, LITELLM_PATH = "BerriAI/litellm", "model_prices_and_context_window.json"
MD_REPO, MD_DIR = "sst/models.dev", "providers/anthropic/models"
MAX_WORKERS = 8

STATS = {"network": 0, "cache": 0, "api": 0}
_lock = threading.Lock()
_token: str | None = None


def token() -> str:
    global _token
    if _token is None:
        _token = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=True).stdout.strip()
    return _token


def http(url: str, auth: bool, retries: int = 5) -> bytes:
    headers = {"User-Agent": "pacer-price-history"}
    if auth:
        headers["Authorization"] = f"Bearer {token()}"
        headers["Accept"] = "application/vnd.github+json"
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code in (403, 429) and auth:
                reset = e.headers.get("X-RateLimit-Reset")
                wait = max(5, int(reset) - int(time.time()) + 2) if reset and e.headers.get("X-RateLimit-Remaining") == "0" else 10 * (attempt + 1)
                print(f"  rate limited ({e.code}); sleeping {wait}s", file=sys.stderr)
                time.sleep(min(wait, 900))
            elif e.code >= 500:
                time.sleep(2 * (attempt + 1))
            else:
                raise
        except (urllib.error.URLError, TimeoutError):
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"giving up on {url}")


def api(path: str) -> object:
    with _lock:
        STATS["api"] += 1
    return json.loads(http("https://api.github.com" + path, auth=True))


def raw(repo: str, sha: str, path: str) -> bytes:
    """Raw file at a commit, cached on disk (gzip) keyed by repo+sha+path."""
    f = CACHE / repo.replace("/", "__") / sha / (path.replace("/", "__") + ".gz")
    if f.exists():
        with _lock:
            STATS["cache"] += 1
        return gzip.decompress(f.read_bytes())
    data = http(f"https://raw.githubusercontent.com/{repo}/{sha}/{path}", auth=False)
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_suffix(f".tmp{threading.get_ident()}")
    tmp.write_bytes(gzip.compress(data))
    tmp.replace(f)
    with _lock:
        STATS["network"] += 1
    return data


def cached_api(key: str, path: str) -> object:
    """API response for an immutable object (a commit), cached on disk."""
    f = CACHE / "api" / (hashlib.sha1(key.encode()).hexdigest() + ".json")
    if f.exists():
        return json.loads(f.read_text())
    data = api(path)
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps(data))
    return data


def list_commits(repo: str, path: str) -> list[dict]:
    out, page = [], 1
    while True:
        d = api(f"/repos/{repo}/commits?path={path}&since={SINCE}&per_page=100&page={page}")
        out += [{"sha": c["sha"], "date": c["commit"]["committer"]["date"]} for c in d]
        if len(d) < 100:
            break
        page += 1
    out.reverse()  # oldest first
    return out


def day(iso: str) -> str:
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(timezone.utc).strftime("%Y-%m-%d")


def canon(key: str) -> str:
    k = key.lower()
    if k.startswith("anthropic/"):
        k = k[len("anthropic/"):]
    k = re.sub(r"\[[^\]]*\]$", "", k)
    k = re.sub(r"-v\d+:\d+$", "", k)  # Bedrock-style version suffix on a stray plain key
    k = re.sub(r"-\d{8}$", "", k)
    return k


def m(x: float | int | None) -> float | None:
    return None if x is None else round(x * 1e6, 6)


# ---------------------------------------------------------------- LiteLLM

BASE_MAP = {
    "input_cost_per_token": "input",
    "output_cost_per_token": "output",
    "cache_creation_input_token_cost": "cacheWrite5m",
    "cache_creation_input_token_cost_above_1hr": "cacheWrite1h",
    "cache_read_input_token_cost": "cacheRead",
}
TIER_RE = re.compile(r"^(.*)_above_(100|200)k_tokens$")


def ll_extract(blob: bytes) -> dict[str, dict[str, dict]]:
    """canonical id -> {litellm key -> raw price vector}, first-party keys only."""
    data = json.loads(blob)
    out: dict[str, dict[str, dict]] = {}
    for key, v in data.items():
        if not isinstance(v, dict) or not (key.startswith("claude-") or key.startswith("anthropic/claude-")):
            continue
        vec = {}
        for f, val in v.items():
            if f in BASE_MAP or TIER_RE.match(f) or f == "provider_specific_entry":
                vec[f] = val
        out.setdefault(canon(key), {})[key] = vec
    return out


def ll_regional(blob: bytes) -> dict[str, float]:
    """canonical id -> Bedrock `us.` input price / first-party input price."""
    data = json.loads(blob)
    first = {}
    for key, v in data.items():
        if isinstance(v, dict) and (key.startswith("claude-") or key.startswith("anthropic/claude-")) and v.get("input_cost_per_token"):
            first.setdefault(canon(key), v["input_cost_per_token"])
    ratios = {}
    for key, v in data.items():
        if not isinstance(v, dict):
            continue
        tail = key.rsplit("/", 1)[-1].lower()
        if not tail.startswith("us.anthropic.claude-"):
            continue
        cid = re.sub(r"-v\d+:\d+$", "", tail[len("us.anthropic."):])
        cid = canon(cid)
        p = v.get("input_cost_per_token")
        if p and cid in first:
            ratios.setdefault(cid, round(p / first[cid], 4))
    return ratios


def primary_key(cid: str, keys: list[str]) -> str:
    for pref in (cid, "anthropic/" + cid):
        if pref in keys:
            return pref
    plain = sorted(k for k in keys if not k.startswith("anthropic/"))
    return (plain or sorted(keys))[0]


def ll_period_body(vec: dict) -> dict:
    per, tiers = {}, {"above200k": None, "above100k": None}
    for f, val in vec.items():
        if f in BASE_MAP:
            per[BASE_MAP[f]] = m(val)
        elif (mt := TIER_RE.match(f)):
            base, thr = mt.groups()
            t = tiers.setdefault(f"above{thr}k", None) or {}
            t[BASE_MAP.get(base, base)] = m(val)
            tiers[f"above{thr}k"] = t
    mult = vec.get("provider_specific_entry") or None
    return {"perMTok": per, "tiers": tiers, "multipliers": mult}


class LiteLLM:
    def __init__(self):
        self.commits = list_commits(LITELLM_REPO, LITELLM_PATH)
        self.states: dict[int, dict] = {}
        self.regional: dict[str, float] = {}

    def state(self, i: int) -> dict:
        return self.states[i]

    def fetch(self, idxs):
        todo = [i for i in sorted(set(idxs)) if i not in self.states]

        def work(i):
            blob = raw(LITELLM_REPO, self.commits[i]["sha"], LITELLM_PATH)
            return i, ll_extract(blob), (ll_regional(blob) if i == len(self.commits) - 1 else None)

        with ThreadPoolExecutor(MAX_WORKERS) as ex:
            for i, st, reg in ex.map(work, todo):
                self.states[i] = st
                if reg is not None:
                    self.regional = reg

    def run(self):
        n = len(self.commits)
        print(f"litellm: {n} commits since {SINCE[:10]}", file=sys.stderr)
        weeks = {}
        for i, c in enumerate(self.commits):
            d = datetime.fromisoformat(c["date"].replace("Z", "+00:00")).isocalendar()
            weeks[(d.year, d.week)] = i
        samples = sorted(set(weeks.values()) | {0, n - 1})
        print(f"litellm: sampling {len(samples)} versions", file=sys.stderr)
        self.fetch(samples)
        segs = [(a, b) for a, b in zip(samples, samples[1:]) if self.states[a] != self.states[b]]
        rnd = 0
        while segs:
            rnd += 1
            mids = {(a + b) // 2 for a, b in segs if b - a > 1}
            self.fetch(mids)
            nxt = []
            for a, b in segs:
                if b - a <= 1:
                    continue
                mid = (a + b) // 2
                for lo, hi in ((a, mid), (mid, b)):
                    if self.states[lo] != self.states[hi]:
                        nxt.append((lo, hi))
            print(f"litellm: bisect round {rnd}: {len(nxt)} open segments", file=sys.stderr)
            segs = nxt
        return self.timeline()

    def timeline(self) -> dict:
        nodes = sorted(self.states)
        first_node = nodes[0]
        models: dict[str, dict] = {}
        for i in nodes:
            st = self.states[i]
            for cid, keyvecs in st.items():
                pk = primary_key(cid, list(keyvecs))
                vec = keyvecs[pk]
                e = models.setdefault(cid, {"keys": set(), "periods": [], "dis": {}, "prev": None,
                                            "firstCommit": i, "preexisting": i == first_node})
                e["keys"].update(keyvecs)
                if vec != e["prev"]:
                    c = self.commits[i]
                    body = ll_period_body(vec)
                    e["periods"].append({"from": day(c["date"]), "commit": c["sha"], **body})
                    e["prev"] = vec
                for k, kv in keyvecs.items():
                    if k == pk or kv == vec:
                        continue
                    diff = {f: [vec.get(f), kv.get(f)] for f in sorted(set(vec) | set(kv)) if vec.get(f) != kv.get(f)}
                    sig = json.dumps([k, diff], sort_keys=True)
                    e["dis"].setdefault(sig, {"key": k, "primary": pk, "from": day(self.commits[i]["date"]),
                                              "commit": self.commits[i]["sha"], "differs": diff})
        out = {}
        for cid, e in models.items():
            c = self.commits[e["firstCommit"]]
            out[cid] = {"firstSeen": day(c["date"]), "firstSeenCommit": c["sha"],
                        "preexistingAtRangeStart": e["preexisting"],
                        "keys": sorted(e["keys"]), "periods": e["periods"],
                        "keyDisagreements": list(e["dis"].values())}
        return out


# -------------------------------------------------------------- models.dev

def _gt_name(n: int) -> str:
    return f"above{n // 1000}k"


def _when_name(when: dict) -> str:
    parts = []
    for k, v in when.items():
        parts.append(str(v.get("equals", json.dumps(v))) if isinstance(v, dict) else str(v))
    return "+".join(parts) if parts else "all"


def _rates(price, cache) -> dict:
    r = {}
    if price is not None:
        r["input"] = price
    if isinstance(cache, dict):
        if "read" in cache:
            r["cacheRead"] = cache["read"]
        w = cache.get("write")
        if isinstance(w, dict):
            if "5m" in w:
                r["cacheWrite5m"] = w["5m"]
            if "1h" in w:
                r["cacheWrite1h"] = w["1h"]
        elif w is not None:
            r["cacheWrite5m"] = w
    return r


def _lenient_cost(text: str) -> dict | None:
    """Some historical files are not valid TOML as a whole; parse only the [cost] tables."""
    lines, keep, on = text.splitlines(), [], False
    for ln in lines:
        if ln.startswith("["):
            on = ln.strip("[] ").split(".")[0] == "cost"
        if on:
            keep.append(ln)
    try:
        return tomllib.loads("\n".join(keep)).get("cost")
    except tomllib.TOMLDecodeError:
        return None


def md_parse(blob: bytes) -> dict | None:
    """Return {perMTok, tiers, multipliers} (USD / MTok) or None if no cost table.

    Handles schema 1 ([cost] input/output/cache_read/cache_write, optionally
    [cost.context_over_200k]; the earliest files used inputCached/outputCached)
    and schema 2 ([cost.text.input] price + cache + overrides + multipliers).
    """
    try:
        d = tomllib.loads(blob.decode())
    except tomllib.TOMLDecodeError:
        d = {"cost": _lenient_cost(blob.decode())}
    cost = d.get("cost")
    if not isinstance(cost, dict):
        return None
    tiers: dict[str, dict | None] = {"above200k": None, "above100k": None}
    mult = None
    if "text" in cost:  # schema 2
        t = cost["text"]
        inp, out = t.get("input", {}), t.get("output", {})
        per = _rates(inp.get("price"), inp.get("cache"))
        if out.get("price") is not None:
            per["output"] = out["price"]
        for ov in inp.get("overrides", []):
            gt = ov.get("when", {}).get("context", {}).get("gt")
            if gt:
                tiers.setdefault(_gt_name(gt), None)
                tiers[_gt_name(gt)] = {**(tiers[_gt_name(gt)] or {}), **_rates(ov.get("price"), ov.get("cache"))}
        for ov in out.get("overrides", []):
            gt = ov.get("when", {}).get("context", {}).get("gt")
            if gt and ov.get("price") is not None:
                tiers.setdefault(_gt_name(gt), None)
                tiers[_gt_name(gt)] = {**(tiers[_gt_name(gt)] or {}), "output": ov["price"]}
        for mu in cost.get("multipliers", []):
            mult = mult or {}
            mult[_when_name(mu.get("when", {}))] = mu.get("factor")
    else:  # schema 1
        per = {}
        for src, dst in (("input", "input"), ("output", "output"), ("cache_read", "cacheRead"),
                         ("cache_write", "cacheWrite5m"), ("inputCached", "cacheWrite5m"), ("outputCached", "cacheRead")):
            if src in cost:
                per[dst] = cost[src]
        o = cost.get("context_over_200k")
        if isinstance(o, dict):
            tiers["above200k"] = {dst: o[src] for src, dst in (("input", "input"), ("output", "output"),
                                  ("cache_read", "cacheRead"), ("cache_write", "cacheWrite5m")) if src in o}
    rnd = lambda x: None if x is None else round(float(x), 6)
    per = {k: rnd(v) for k, v in per.items()}
    tiers = {k: ({a: rnd(b) for a, b in v.items()} if v else None) for k, v in tiers.items()}
    return {"perMTok": per, "tiers": tiers, "multipliers": mult}


class ModelsDev:
    def __init__(self):
        self.commits = list_commits(MD_REPO, MD_DIR)

    def run(self) -> tuple[dict, str]:
        print(f"models.dev: {len(self.commits)} commits touching {MD_DIR}", file=sys.stderr)

        def detail(c):
            d = cached_api("commit:" + c["sha"], f"/repos/{MD_REPO}/commits/{c['sha']}")
            files = [(f["filename"], f["status"]) for f in d.get("files", [])
                     if f["filename"].startswith(MD_DIR + "/") and f["filename"].endswith(".toml")]
            return c, files

        with ThreadPoolExecutor(MAX_WORKERS) as ex:
            details = list(ex.map(detail, self.commits))
        fetches = [(c["sha"], fn) for c, files in details for fn, st in files if st != "removed"]

        def get(a):
            sha, fn = a
            return a, md_parse(raw(MD_REPO, sha, fn))

        with ThreadPoolExecutor(MAX_WORKERS) as ex:
            parsed = dict(ex.map(get, fetches))

        stems: dict[str, dict] = {}  # file stem -> current parsed vec
        models: dict[str, dict] = {}
        for c, files in details:
            touched = set()
            for fn, st in files:
                stem = Path(fn).stem.lower()
                if st == "removed":
                    stems.pop(stem, None)
                else:
                    stems[stem] = parsed[(c["sha"], fn)]
                touched.add(canon(stem))
            for cid in touched:
                keys = [s for s in stems if canon(s) == cid]
                if not keys:
                    continue
                pk = cid if cid in keys else sorted(keys)[0]
                vec = stems[pk]
                e = models.setdefault(cid, {"firstSeen": day(c["date"]), "firstSeenCommit": c["sha"],
                                            "periods": [], "prev": "unset"})
                if vec is None or vec == e["prev"]:
                    continue
                e["prev"] = vec
                e["periods"].append({"from": day(c["date"]), "commit": c["sha"], **vec})
        newest = self.commits[-1]["sha"]
        for e in models.values():
            e.pop("prev")
        return models, newest


# ------------------------------------------------------------------ output

PRICE_FIELDS = ("input", "output", "cacheWrite5m", "cacheWrite1h", "cacheRead")


def at(periods: list[dict], date: str) -> dict | None:
    cur = None
    for p in periods:
        if p["from"] <= date:
            cur = p
    return cur


def fmt(per: dict | None) -> str:
    if not per:
        return "(none)"
    return ", ".join(f"{k} {per[k]:g}" for k in PRICE_FIELDS if k in per)


def tiers_str(t: dict | None) -> str:
    bits = [f"{k}: {fmt(v)}" for k, v in (t or {}).items() if v]
    return "; ".join(bits)


def diff_periods(a: dict, b: dict) -> str:
    out = []
    for k in PRICE_FIELDS:
        x, y = a["perMTok"].get(k), b["perMTok"].get(k)
        if x != y:
            out.append(f"{k} {x if x is not None else '-'} -> {y if y is not None else '-'}")
    if a.get("tiers") != b.get("tiers"):
        out.append(f"tiers [{tiers_str(a.get('tiers')) or 'none'}] -> [{tiers_str(b.get('tiers')) or 'none'}]")
    if a.get("multipliers") != b.get("multipliers"):
        out.append(f"multipliers {a.get('multipliers')} -> {b.get('multipliers')}")
    return "; ".join(out)


def catalog_disagreements(ll: dict | None, md: dict | None) -> list[str]:
    if not ll or not md:
        return []
    dates = sorted({p["from"] for p in ll["periods"]} | {p["from"] for p in md["periods"]})
    out, last = [], None
    for dt in dates:
        a, b = at(ll["periods"], dt), at(md["periods"], dt)
        if not a or not b:
            continue
        diffs = [f"{k}: litellm {a['perMTok'].get(k)} vs models.dev {b['perMTok'].get(k)}"
                 for k in ("input", "output", "cacheWrite5m", "cacheRead") if a["perMTok"].get(k) != b["perMTok"].get(k)]
        sig = tuple(diffs)
        if sig != last:
            if diffs:
                out.append(f"{dt}: " + "; ".join(diffs))
            elif last:
                out.append(f"{dt}: agree again")
            last = sig
    return out


def build(ll: LiteLLM, ll_models: dict, md_models: dict, md_newest: str) -> dict:
    ids = sorted(set(ll_models) | set(md_models))
    models = []
    for cid in ids:
        entry = {"model": cid}
        l = ll_models.get(cid)
        if l:
            entry["litellm"] = l
        if cid in md_models:
            entry["modelsDev"] = md_models[cid]
        entry["bedrockUsRatio"] = ll.regional.get(cid)
        models.append(entry)
    return {"schema": 1, "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "sources": {"litellm": ll.commits[-1]["sha"], "modelsDev": md_newest}, "models": models}


def report(doc: dict, stats: dict) -> str:
    L = ["# Anthropic price history (candidate)", "",
         "Generated by `seed_price_history.py` from the git history of two public catalogs. "
         "Rates are USD per million tokens, dates are UTC. This is a CANDIDATE for human review against "
         "Anthropic's pricing page, not the curated ledger.", "",
         f"Sources: LiteLLM `{doc['sources']['litellm'][:10]}`, models.dev `{doc['sources']['modelsDev'][:10]}`. "
         f"Generated {doc['generatedAt']}.", "",
         "Models marked *(range start)* were already present in the oldest commit examined "
         "(2025-01-01 for LiteLLM; the first commit touching the models.dev directory), so their true first-seen date is earlier or unknown.", ""]
    changed = []
    for e in doc["models"]:
        cid = e["model"]
        l, md = e.get("litellm"), e.get("modelsDev")
        L += [f"## {cid}", ""]
        L.append(f"- LiteLLM first seen: {l['firstSeen']}{' *(range start)*' if l['preexistingAtRangeStart'] else ''} "
                 f"(keys: {', '.join(l['keys'])})" if l else "- LiteLLM: not present")
        L.append(f"- models.dev first seen: {md['firstSeen']}" if md else "- models.dev: not present")
        if e.get("bedrockUsRatio") is not None:
            L.append(f"- Bedrock `us.` input price ratio vs first-party: {e['bedrockUsRatio']}")
        for name, src in (("LiteLLM", l), ("models.dev", md)):
            if not src:
                continue
            ps = src["periods"]
            L.append(f"- {name} periods:")
            for i, p in enumerate(ps):
                extra = []
                ts = tiers_str(p.get("tiers"))
                if ts:
                    extra.append(f"tiers: {ts}")
                if p.get("multipliers"):
                    extra.append(f"multipliers: {p['multipliers']}")
                head = f"  - {p['from']} (`{p['commit'][:8]}`): {fmt(p['perMTok'])}" + ("; " + "; ".join(extra) if extra else "")
                L.append(head)
                if i:
                    L.append(f"    - change: {diff_periods(ps[i-1], p)}")
                    changed.append((cid, name, p["from"], p["commit"][:8], diff_periods(ps[i-1], p)))
        if l and l["keyDisagreements"]:
            L.append("- LiteLLM keys disagreeing within this model:")
            for d in l["keyDisagreements"]:
                L.append(f"  - from {d['from']}: `{d['key']}` vs `{d['primary']}`: {d['differs']}")
        dis = catalog_disagreements(l, md)
        if dis:
            L.append("- Catalog disagreements (LiteLLM vs models.dev, at each change date):")
            L += [f"  - {x}" for x in dis]
        L.append("")
    L += ["## All price changes after first appearance", ""]
    L += [f"- {c} / {n} / {d} (`{sha}`): {s}" for c, n, d, sha, s in sorted(changed, key=lambda x: (x[2], x[0]))] or ["- none"]
    L += ["", "## How to rerun", "",
          "```sh", "uv run research/price-history/seed_price_history.py \\",
          "  --out research/price-history/candidate-price-history.json \\",
          "  --report research/price-history/REPORT.md", "```", "",
          "Needs the `gh` CLI logged in (`gh auth token` is read at runtime, never stored). "
          "Downloads are cached under `/tmp/pricing-core/seed-cache/` keyed by repo, commit and path, so reruns only hit the network for new commits.", "",
          "## Method", "",
          f"- **LiteLLM** (`{LITELLM_REPO}`, `{LITELLM_PATH}`): list every commit touching the file since {SINCE[:10]}, "
          "sample the last commit of each ISO week plus the oldest and newest commits, then for each pair of consecutive samples "
          "whose Anthropic first-party state differs, bisect the commits between them (downloading only midpoints) until each change "
          "is pinned to a single commit. A change that is reverted entirely within one sampling gap (A to B to A) would be missed.",
          "- Keys considered: plain `claude-*` and `anthropic/claude-*`. Fields: input, output, cache write (5m and 1h), cache read, "
          "every `*_above_100k_tokens` / `*_above_200k_tokens` field, and `provider_specific_entry` (multipliers).",
          "- Canonical id: lowercase, strip leading `anthropic/`, strip a trailing `[...]`, strip a trailing `-YYYYMMDD`. "
          "Keys sharing a canonical id are grouped; the undated key is primary and others that differ are listed as disagreements.",
          "- Bedrock: `us.anthropic.<model>-vN:0` keys in the newest sample give a regional input-price ratio; not bisected.",
          f"- **models.dev** (`{MD_REPO}`, `{MD_DIR}/*.toml`): every commit touching that directory since {SINCE[:10]}; "
          "the changed files at each commit are parsed with `tomllib`. Schema 1 files use `[cost]` "
          "(`input`, `output`, `cache_read`, `cache_write`, optional `[cost.context_over_200k]`; the very oldest files used "
          "`inputCached`/`outputCached`, mapped here to cache write/read), schema 2 files use `[cost.text.input]` with `price`, "
          "`cache`, context `overrides` and `[[cost.multipliers]]`. Price files live in `providers/anthropic/models/`; "
          "`models/anthropic/` holds only model metadata.",
          "- Period: begins whenever any of per-MTok rates, tiers or multipliers changes. Dates are the committer date of the commit that introduced the vector. "
          "Absent rates are omitted rather than written as 0.", "",
          "## Run stats", "",
          f"- {stats['network']} files downloaded, {stats['cache']} served from cache, {stats['api']} GitHub API calls, wall time {stats['wall']:.0f}s."]
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--report", required=True)
    a = ap.parse_args()
    t0 = time.time()
    CACHE.mkdir(parents=True, exist_ok=True)
    ll = LiteLLM()
    ll_models = ll.run()
    md_models, md_newest = ModelsDev().run()
    doc = build(ll, ll_models, md_models, md_newest)
    Path(a.out).write_text(json.dumps(doc, indent=2) + "\n")
    stats = {**STATS, "wall": time.time() - t0}
    Path(a.report).write_text(report(doc, stats))
    print(f"done: {len(doc['models'])} models; {STATS}; {stats['wall']:.0f}s", file=sys.stderr)


if __name__ == "__main__":
    main()
