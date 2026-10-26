"""Markdown report (`arena report --format md`), `RESULTS.md` style.

`public=True` is relative-only, for the public repo: per target, models by CRPS
skill against the baseline in percent, plus coverage and PIT flatness (both
unitless). No absolute CRPS or absolute error for any target, no raw token or
dollar value anywhere, no agent cost. `render` ends by asserting that on its own
output, so a new field cannot leak by accident.
"""
from __future__ import annotations

import datetime as dt
import re

from report import md as mdmod
from report.data import TARGETS, Report
from report.render import GLOSSARY

TOP_N = 8

TARGET_TITLES = {
    "meter.five_hour": "5-hour limit meter", "meter.seven_day": "7-day limit meter",
    "meter.scoped": "Scoped (per-model) meter", "spend.hourly": "Hourly spend",
    "tokens.hourly": "Hourly tokens", "split.accounts": "Split across accounts",
    "cycle.next_start": "Next cycle start",
}

# What must never appear in public output.
MONEY = re.compile(r"\$\s?\d|\d\s?(?:usd|dollars?)\b|\busd\s?\d", re.I)
TOKENS = re.compile(r"\d[\d,.]*\s?[kKmMbB]?\s*(?:tokens?|toks?)\b", re.I)


def figures(text: str) -> list[str]:
    return [m.group(0) for rx in (MONEY, TOKENS) for m in rx.finditer(text)]


def _clean(text: str, public: bool) -> str:
    """Sentences carrying a dollar or token figure are dropped (public only)."""
    text = (text or "").replace("|", "/").replace("\n", " ").strip()
    if not public or not figures(text):
        return text
    parts = re.split(r"(?<=[.!?])\s+", text)
    return " ".join(p for p in parts if not figures(p))


def _pct(v, signed=True) -> str:
    return "-" if v is None else (f"{v * 100:+.1f}%" if signed else f"{v * 100:.1f}%")


def _num(v, d=3) -> str:
    return "-" if v is None else f"{v:.{d}f}"


def _table(head: list[str], rows: list[list[str]]) -> str:
    out = ["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def _skill_of(rep: Report, name: str) -> float | None:
    vals = [v for t in TARGETS for v in [next((c["skills"].get(t) for c in rep.models if c["name"] == name), None)]
            if v is not None]
    return max(vals) if vals else None


def sec_target(rep: Report, t: str, public: bool) -> str:
    b = rep.boards[t]
    title = TARGET_TITLES.get(t, t)
    out = [f"### {title} (`{t}`)", ""]
    kinds = {c["name"]: c["kind"] for c in rep.models}
    rows = b.rows
    if b.has_skill:
        base = [r for r in rows if r["model"] == b.baseline]
        ranked = sorted((r for r in rows if r["skill"] is not None and r["model"] != b.baseline),
                        key=lambda r: -r["skill"])[:TOP_N]
        shown = ranked + base
        out.append(f"{b.episodes} episodes, {b.tier} tier. Skill is the CRPS reduction against `{b.baseline}` "
                   f"(positive is better). Top {len(ranked)} shown.")
        head = ["#", "model", "kind", "skill vs baseline", "cover80", "PIT flatness", "tied for best"]
        body = [[i + 1 if r["model"] != b.baseline else "ref", f"`{r['model']}`", kinds.get(r["model"], "-"),
                 _pct(r["skill"]) if r["model"] != b.baseline else "0.0%", _num(r.get("cover80"), 2),
                 _num(r.get("pit_tv")), "yes" if r.get("tied_best") else ""] for i, r in enumerate(shown)]
        if not public:
            head.insert(4, "CRPS")
            for r, row in zip(shown, body):
                row.insert(4, _num(r.get("crps"), 4))
        out += ["", _table(head, body)]
    else:
        out.append(f"{b.episodes} episodes, {b.tier} tier. No baseline scored this target, so there is no skill "
                   "to rank by; models are listed in score order.")
        head = ["#", "model", "kind", "cover80", "PIT flatness"]
        body = [[i + 1, f"`{r['model']}`", kinds.get(r["model"], "-"), _num(r.get("cover80"), 2),
                 _num(r.get("pit_tv"))] for i, r in enumerate(rows[:TOP_N])]
        out += ["", _table(head, body)]
    return "\n".join(out) + "\n"


def sec_catalogue(rep: Report) -> str:
    rows = []
    for c in sorted(rep.models, key=lambda c: (c["kind"], c["generation"] or 0, c["name"])):
        best = "-" if c["best_target"] is None else f"{_pct(c['best_skill'])} on `{c['best_target']}`"
        rows.append([f"`{c['name']}`", c["kind"], "-" if c["generation"] is None else c["generation"],
                     c["agent"] or "-", (c["claude_model"] or "-").replace("claude-", ""), c["effort"] or "-",
                     c["niche"] or "-", f"`{c['copied_from']}`" if c.get("copied_from") else "-", best])
    return "\n".join(["## Model catalogue", "",
                      "Where each model came from: the family it belongs to, the generation and the agent that wrote "
                      "it, which Claude model and effort that agent ran at, the niche it was given, and the model it "
                      "was copied from.", "",
                      _table(["model", "kind", "gen", "agent", "claude model", "effort", "niche", "copied from",
                              "best skill"], rows)]) + "\n"


def sec_agents(rep: Report, public: bool) -> str:
    out = ["## Agents per generation", ""]
    if not rep.agents:
        return "\n".join(out + ["No agent generations found.\n"])
    for gen in sorted({a["generation"] for a in rep.agents}):
        ags = [a for a in rep.agents if a["generation"] == gen]
        out += [f"### Generation {gen}", ""]
        # Best skill on the two main meters only: the per-model cap can be
        # degenerate (a flat forecast wins when the cap barely moves), and a
        # max over every target would make that look like a model's strength.
        head = ["agent", "claude model", "effort", "niche", "exit", "turns", "eval calls",
                "models (scored)", "best 5-hour", "best weekly", "summary"]
        if not public:
            head.insert(6, "cost")
        rows = []
        for a in ags:
            row = [f"`{a['name']}`", (a["model"] or "-").replace("claude-", ""), a["effort"] or "-",
                   a["niche"] or "-", a["status"] or "-", "-" if a["turns"] is None else a["turns"],
                   "-" if a["evals_used"] is None else a["evals_used"],
                   f"{len(a.get('produced') or a['models'])} ({len(a['models'])})",
                   _pct(a["best"].get("meter.five_hour")) if a["best"].get("meter.five_hour") is not None else "-",
                   _pct(a["best"].get("meter.seven_day")) if a["best"].get("meter.seven_day") is not None else "-",
                   _clean(a["summary"], public) or "-"]
            if not public:
                row.insert(6, "-" if a["cost"] is None else f"${a['cost']:.2f}")
            rows.append(row)
        out += [_table(head, rows), ""]
    return "\n".join(out)


def sec_checks(rep: Report, selftest, public: bool) -> str:
    out = ["## Harness checks", ""]
    if selftest:
        sym = {"pass": "pass", "fail": "FAIL", "skip": "skip"}
        rows = [[_clean(str(c.get("name", "")), public), sym.get(str(c.get("status", "")).lower(), "?"),
                 _clean(str(c.get("detail", "")), public)] for c in selftest]
        bad = sum(1 for c in selftest if str(c.get("status", "")).lower() == "fail")
        out += [f"{len(selftest)} checks, {bad} failing.", "", _table(["check", "status", "detail"], rows), ""]
    else:
        out += ["No self-test results were supplied.", ""]
    if rep.parity:
        out += ["### Engine port parity", "",
                "The shipped Swift engine's output against the harness port, row by row.", ""]
        rows = []
        for p in rep.parity:
            for era, e in p.get("eras", {}).items():
                rows.append([era, f"{e['rows']:,}", f"{e['within_tol'] * 100:.2f}%",
                             f"{e['method_agree'] * 100:.1f}%", f"{e['reading_agree'] * 100:.1f}%"])
        out += [_table(["era", "rows", "within tolerance", "method agrees", "reading agrees"], rows), ""]
    return "\n".join(out)


def sec_caveats(caveats: str | None, public: bool) -> str:
    out = ["## Caveats and method", ""]
    if caveats and caveats.strip():
        out += [caveats.strip(), ""]
    if public:
        out += ["This report is relative-only: scores are shown as skill against a baseline, and as unitless "
                "calibration measures (coverage, PIT flatness). Absolute errors, token counts and dollar amounts "
                "are left out on purpose.", ""]
    out += ["### Glossary", ""] + [f"- **{k}**: {v}" for k, v in GLOSSARY] + [""]
    return "\n".join(out)


def render(rep: Report, *, narrative: str | None, selftest: list[dict] | None, public: bool = True) -> str:
    summary, caveats = mdmod.split_caveats(narrative) if narrative else (None, None)
    if public:
        bad = [(i + 1, f) for i, ln in enumerate((narrative or "").splitlines()) for f in figures(ln)]
        if bad:
            raise SystemExit("arena report --public: the narrative contains dollar or token figures "
                             f"(line {bad[0][0]}); rewrite them as percentages")
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    out = ["# Forecast arena results", "",
           f"Generated {stamp}. Baseline: `{rep.baseline or 'none'}`. "
           + ("Relative-only: skill in percent against the baseline." if public else ""), ""]
    if not public:
        out += [f"- run `{r['run_id'][:8]}` ({r['kind']}, {r['tier']} tier, seed {r['seed']}, "
                f"snapshot `{r['snapshot_id']}`)" for r in rep.runs] + [""]
    out += ["## Summary", "", (summary or "No summary yet.").strip(), "", "## Results by target", ""]
    if not rep.boards:
        out.append("No scores in the selected runs.\n")
    for t in TARGETS:
        if t in rep.boards:
            out.append(sec_target(rep, t, public))
    out += [sec_catalogue(rep), sec_agents(rep, public), sec_checks(rep, selftest, public),
            sec_caveats(caveats, public)]
    text = "\n".join(out).rstrip() + "\n"
    if public:
        left = figures(text)
        if left:
            raise SystemExit(f"arena report --public: output carries figures it must not ({left[:3]})")
    return text
