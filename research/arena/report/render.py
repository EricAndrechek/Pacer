"""The HTML: inline CSS, no scripts, no external requests. Bar charts are CSS
grids (not scaled SVG) so their text stays readable at phone width."""
from __future__ import annotations

import datetime as dt
import html
import json
from pathlib import Path

from report import md
from report.data import LIVE, SKILL_FLOOR, TARGETS, Board, Report

E = html.escape

CSS = """
:root{color-scheme:light;--bg:#f9f9f7;--surface:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;--muted:#6f6d67;
--grid:#e1e0d9;--axis:#c3c2b7;--series:#2a78d6;--ref:#a9a79f;--good:#006300;--bad:#b02a2a;--warn:#8a5a00;
--ring:rgba(11,11,11,.10);--wash:rgba(42,120,214,.09)}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){color-scheme:dark;--bg:#0d0d0d;--surface:#1a1a19;
--ink:#f0efec;--ink2:#c3c2b7;--muted:#a09e96;--grid:#2c2c2a;--axis:#383835;--series:#3987e5;--ref:#6b6962;
--good:#0ca30c;--bad:#e66767;--warn:#e0a020;--ring:rgba(255,255,255,.10);--wash:rgba(57,135,229,.14)}}
:root[data-theme="dark"]{color-scheme:dark;--bg:#0d0d0d;--surface:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--muted:#a09e96;
--grid:#2c2c2a;--axis:#383835;--series:#3987e5;--ref:#6b6962;--good:#0ca30c;--bad:#e66767;--warn:#e0a020;
--ring:rgba(255,255,255,.10);--wash:rgba(57,135,229,.14)}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:980px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:1.7rem;line-height:1.2;margin:0 0 4px}
h2{font-size:1.3rem;margin:44px 0 8px;padding-top:12px;border-top:1px solid var(--grid)}
h3{font-size:1.05rem;margin:28px 0 4px}
h4{font-size:.95rem;margin:16px 0 4px}
p{margin:.5em 0}
code{font:.88em ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--wash);padding:1px 4px;border-radius:3px;overflow-wrap:anywhere}
.sub,.note{color:var(--ink2);font-size:.9rem}
.lead{font-size:1.02rem}
.card{background:var(--surface);border:1px solid var(--ring);border-radius:8px;padding:12px 14px;margin:10px 0}
.placeholder{border-style:dashed;color:var(--ink2)}
.runs{display:grid;gap:4px;margin:10px 0;font-size:.88rem;color:var(--ink2)}
.chart{margin:10px 0;background:var(--surface);border:1px solid var(--ring);border-radius:8px;padding:10px 12px}
.chart .ttl{font-size:.85rem;color:var(--ink2);margin-bottom:6px}
.bar{display:grid;grid-template-columns:minmax(120px,210px) 1fr 4.2rem;align-items:center;gap:8px;min-height:26px}
.bar .nm{font-size:.84rem;overflow-wrap:anywhere;line-height:1.2}
.bar .tr{position:relative;height:18px}
.bar .tr:before{content:"";position:absolute;left:var(--z);top:-3px;bottom:-3px;width:1px;background:var(--axis)}
.bar .fill{position:absolute;top:2px;height:14px;background:var(--series);border-radius:0 4px 4px 0}
.bar .fill.neg{border-radius:4px 0 0 4px}
.bar.ref .fill{background:var(--ref)}
.bar .v{font-size:.84rem;font-variant-numeric:tabular-nums;text-align:right}
.bar.ref .nm:after{content:" (reference)";color:var(--muted)}
.bar.base .nm:after{content:" (baseline)";color:var(--muted)}
.axis{display:grid;grid-template-columns:minmax(120px,210px) 1fr 4.2rem;gap:8px;font-size:.75rem;color:var(--muted)}
.axis .scale{display:flex;justify-content:space-between}
.tbox{overflow-x:auto;border:1px solid var(--ring);border-radius:8px;background:var(--surface);margin:10px 0;max-width:100%}
table{border-collapse:collapse;width:100%;font-size:.82rem}
th,td{padding:5px 9px;text-align:right;border-bottom:1px solid var(--grid);white-space:nowrap;font-variant-numeric:tabular-nums}
th:first-child,td:first-child,th.l,td.l{text-align:left}
th{font-weight:600;color:var(--ink2);background:var(--surface);position:sticky;top:0}
td.wrap{white-space:normal;min-width:200px;text-align:left}td.wide{min-width:380px}
tr:last-child td{border-bottom:0}
tr.hl td{background:var(--wash)}
.tag{display:inline-block;font-size:.72rem;border:1px solid var(--axis);border-radius:10px;padding:0 7px;color:var(--ink2)}
.tie{color:var(--good);font-weight:600}
.ok{color:var(--good)}.bad{color:var(--bad)}.warn{color:var(--warn)}
dl.gloss dt{font-weight:600;margin-top:10px}dl.gloss dd{margin:2px 0 0;color:var(--ink2)}
@media (max-width:560px){
 .bar,.axis{grid-template-columns:1fr 3.6rem;gap:2px 8px}
 .bar .nm{grid-column:1/3}.bar .tr{grid-column:1}
 .axis>:first-child{display:none}
 .bar{padding:3px 0 5px}
 h1{font-size:1.4rem}
}
"""


def num(v, nd=3) -> str:
    if v is None:
        return "-"
    a = abs(v)
    if a >= 1000:
        return f"{v:,.0f}"
    if a >= 100:
        return f"{v:.0f}"
    return f"{v:.{nd}g}" if a >= 0.001 or a == 0 else f"{v:.1e}"


def sk(v) -> str:
    return "-" if v is None else f"{v:+.3f}"


def table(head: list[str], rows: list[list[str]], *, left=(0,), hl=None, wrap=(), wide=()) -> str:
    th = "".join(f'<th class="{"l" if i in left else ""}">{E(h)}</th>' for i, h in enumerate(head))
    body = []
    for ri, r in enumerate(rows):
        cls = ' class="hl"' if hl and ri in hl else ""
        tds = "".join(f'<td class="{"l" if i in left else ""}{" wrap" if i in wrap else ""}{" wide" if i in wide else ""}">{c}</td>'
                      for i, c in enumerate(r))
        body.append(f"<tr{cls}>{tds}</tr>")
    return f'<div class="tbox"><table><thead><tr>{th}</tr></thead><tbody>{"".join(body)}</tbody></table></div>'


def hbars(items: list[dict], *, title: str, unit: str = "skill") -> str:
    """items: name, value, ref (bool), base (bool). Sorted by the caller."""
    if not items:
        return ""
    vals = [i["value"] for i in items]
    lo = max(min(0.0, min(vals)), SKILL_FLOOR)
    hi = max(0.0, max(vals))
    span = (hi - lo) or 1.0
    z = (0 - lo) / span * 100
    rows = []
    for i in items:
        v = i["value"]
        clipped = v < lo
        vv = max(v, lo)
        if vv >= 0:
            style = f"left:{z:.2f}%;width:{vv / span * 100:.2f}%"
            cls = "fill"
        else:
            style = f"left:{(vv - lo) / span * 100:.2f}%;width:{-vv / span * 100:.2f}%"
            cls = "fill neg"
        extra = (" ref" if i.get("ref") else "") + (" base" if i.get("base") else "")
        label = f"{v:+.3f}" + (" ◂" if clipped else "")
        rows.append(f'<div class="bar{extra}"><div class="nm">{E(i["name"])}</div>'
                    f'<div class="tr" style="--z:{z:.2f}%"><div class="{cls}" style="{style}"></div></div>'
                    f'<div class="v">{label}</div></div>')
    axis = (f'<div class="axis"><div></div><div class="scale"><span>{lo:+.2f}</span><span>0</span>'
            f'<span>{hi:+.2f}</span></div><div></div></div>')
    return f'<div class="chart"><div class="ttl">{E(title)}</div>{"".join(rows)}{axis}</div>'


# ---------------------------------------------------------------- sections


def sec_summary(narr_summary: str | None) -> str:
    if narr_summary and narr_summary.strip():
        return f'<h2 id="summary">Summary</h2><div class="card">{md.render(narr_summary)}</div>'
    return ('<h2 id="summary">Summary</h2><div class="card placeholder"><p>No summary yet. The coordinator '
            'writes this section as plain words and passes it with <code>--narrative FILE.md</code>.</p></div>')


def _run_line(b: Board) -> str:
    return (f"run <code>{E(b.run_id[:8])}</code>, {E(b.tier)} tier, seed {b.seed}, {b.episodes} episodes, "
            f"snapshot <code>{E(b.snapshot)}</code>")


def board_items(b: Board, n_top=12) -> list[dict]:
    rows = [r for r in b.rows if r["skill"] is not None]
    rows.sort(key=lambda r: -r["skill"])
    keep = {r["model"] for r in rows[:n_top]}
    for extra in (b.baseline, LIVE, "naive-flat"):
        if extra:
            keep.add(extra)
    refs = {b.baseline, LIVE, "naive-flat"}
    return [{"name": r["model"], "value": r["skill"], "ref": r["model"] in refs and r["model"] != b.baseline,
             "base": r["model"] == b.baseline} for r in rows if r["model"] in keep]


def sec_boards(rep: Report) -> str:
    out = ['<h2 id="winners">What won, per target</h2>',
           '<p class="note">CRPS skill is 1 minus the model\'s CRPS over the baseline\'s on the same cells: '
           'positive beats the baseline, 0 ties it. Grey bars are reference rows.</p>']
    for t in TARGETS:
        b = rep.boards.get(t)
        out.append(f'<h3 id="t-{E(t)}">{E(t)}</h3>')
        if not b or not b.rows:
            out.append('<p class="note">Not scored in the chosen runs.</p>')
            continue
        tied = [r["model"] for r in b.rows if r["tied_best"]]
        lead = b.rows[0]
        if len(b.rows) == 1:
            sent = f"Only <strong>{E(lead['model'])}</strong> scored this target (CRPS {num(lead['crps'])})."
        else:
            s = (f" (skill {sk(lead['skill'])} vs {E(b.baseline)})" if lead["skill"] is not None and b.baseline else "")
            tie = f"; {len(tied)} models are statistically tied for best" if len(tied) > 1 else ""
            sent = f"<strong>{E(lead['model'])}</strong> has the lowest CRPS on {E(t)}{s}{tie}."
            if b.baseline and b.baseline != b.baseline_requested:
                sent += (f" <span class='note'>{E(b.baseline_requested or 'no baseline')} did not score this target, "
                         f"so skill is against {E(b.baseline)}.</span>")
        out.append(f'<p class="lead">{sent}</p><p class="note">{_run_line(b)}</p>')
        if b.has_skill:
            out.append(hbars(board_items(b), title=f"CRPS skill vs {b.baseline}, top 12 plus references"))
            shown = {i["name"] for i in board_items(b)}
        else:
            shown = {r["model"] for r in b.rows[:12]}
        rows = [r for r in b.rows if r["model"] in shown] or b.rows[:12]
        if b.has_skill:
            order = {i["name"]: k for k, i in enumerate(board_items(b))}
            rows = sorted(rows, key=lambda r: order.get(r["model"], 99))
        head = ["model", "crps", "skill", "ae_point", "ae_reset", "next_reading_ae", "brier_hit", "cover80",
                "pit_tv", "n", "MCS"]
        trs = [[E(r["model"]), num(r["crps"]), sk(r["skill"]), num(r["ae_point"]), num(r["ae_reset"]),
                num(r["next_reading_ae"]), num(r["brier_hit"]), num(r["cover80"]), num(r["pit_tv"]),
                str(r["n"] or 0), '<span class="tie">tied for best</span>' if r["tied_best"] else ""]
               for r in rows]
        out.append(table(head, trs))
        if len(b.rows) > len(rows):
            out.append(f'<p class="note">{len(b.rows) - len(rows)} more models scored this target; '
                       f'they are in the catalogue below.</p>')
    return "".join(out)


def sec_catalogue(rep: Report) -> str:
    rows, order = [], {"agent": 0}
    for m in sorted(rep.models, key=lambda m: (order.get(m["kind"], 1), m["kind"], m["name"])):
        auth = "-"
        if m["kind"] == "agent":
            auth = E(" · ".join(str(x) for x in (m["agent"], m["claude_model"], m["effort"]) if x) or "agent")
        elif m["claude_model"]:
            auth = E(f"{m['claude_model']} · {m['effort'] or ''}")
        best = (f"{E(m['best_target'])} {sk(m['best_skill'])}" if m["best_target"] else "-")
        rows.append([E(m["name"]), f'<span class="tag">{E(m["kind"])}</span>',
                     E(", ".join(m["children"])) or "-", "-" if m["generation"] is None else str(m["generation"]),
                     auth, best])
    body = (table(["model", "kind", "children", "gen", "author", "best target (skill)"], rows,
                  left=(0, 1, 2, 4, 5), wrap=(2,)) if rows else '<p class="note">No models scored.</p>')
    return (f'<h2 id="catalogue">Model catalogue</h2><p class="note">Every model scored in the chosen runs: '
            f'{len(rep.models)}. "Best target" is the target where its CRPS skill is highest, counted only on '
            f'targets with a baseline and at least three models.</p>{body}')


def _label(a: dict) -> str:
    short = (a["model"] or "?").replace("claude-", "")
    return f"{a['name']} · {short} · {a['effort'] or '?'}"


def sec_agents(rep: Report) -> str:
    out = ['<h2 id="agents">The agents</h2>']
    agent_models = [m for m in rep.models if m["kind"] == "agent"]
    if not rep.agents:
        out.append('<p class="note">No fleet generation found.</p>')
    if not agent_models:
        out.append('<div class="card placeholder"><p>No agent models scored yet.</p></div>')
    cols = ["agent", "Claude model", "effort", "niche", "status", "turns", "cost", "evals", "models",
            "best 5-hour", "best 7-day", "other targets", "review", "report"]
    for gen in sorted({a["generation"] for a in rep.agents}):
        ags = [a for a in rep.agents if a["generation"] == gen]
        rows = []
        for a in ags:
            other = " · ".join(f"{t.split('.')[-1]} {sk(v)}" for t, v in a["best"].items()
                               if v is not None and t not in ("meter.five_hour", "meter.seven_day"))
            ver = a["verdict"]
            vcell = (f'<span class="{ {"pass": "ok", "flag": "warn", "fail": "bad"}[ver]}">{ver}</span>'
                     if ver else "-")
            rows.append([E(a["name"]), E(a["model"] or "-"), E(a["effort"] or "-"), E(a["niche"] or "-"),
                         E(a["status"] or "-"), "-" if a["turns"] is None else str(a["turns"]),
                         "-" if a["cost"] is None else f"${a['cost']:.2f}",
                         "-" if a["evals_used"] is None else f"{a['evals_used']}/{a['evals_budget']}",
                         str(len(a["models"])), sk(a["best"].get("meter.five_hour")),
                         sk(a["best"].get("meter.seven_day")), E(other) or "-", vcell, E(a["summary"]) or "-"])
        out.append(f"<h3>Generation {gen}</h3>")
        out.append(table(cols, rows, left=(0, 1, 2, 3, 4, 11, 12, 13), wrap=(13,), wide=(13,)))
    scored = [a for a in rep.agents if any(v is not None for v in a["best"].values())]
    for t, name in (("meter.five_hour", "5-hour"), ("meter.seven_day", "7-day")):
        items = [{"name": _label(a), "value": a["best"][t]} for a in scored if a["best"].get(t) is not None]
        items.sort(key=lambda i: -i["value"])
        if items:
            b = rep.boards.get(t)
            out.append(hbars(items, title=f"Best {name} CRPS skill by agent (vs {b.baseline if b else 'baseline'})"))
    return "".join(out)


def sec_checks(selftest: list[dict] | None, rep: Report) -> str:
    out = ['<h2 id="checks">Harness checks</h2><h3>Self-test</h3>']
    if selftest:
        icon = {"pass": ("ok", "✓ pass"), "fail": ("bad", "✗ fail"), "skip": ("warn", "– skip")}
        rows = []
        for c in selftest:
            st = str(c.get("status", "")).lower()
            cls, txt = icon.get(st, ("warn", E(st or "?")))
            rows.append([E(str(c.get("name", ""))), f'<span class="{cls}">{txt}</span>', E(str(c.get("detail", "")))])
        n_bad = sum(1 for c in selftest if str(c.get("status", "")).lower() == "fail")
        out.append(f'<p class="note">{len(selftest)} checks, {n_bad} failing.</p>')
        out.append(table(["check", "status", "detail"], rows, left=(0, 1, 2), wrap=(2,)))
    else:
        out.append('<div class="card placeholder"><p>No self-test file given (<code>--selftest FILE.json</code>).</p></div>')
    out.append("<h3>Engine port parity</h3>")
    if not rep.parity:
        out.append('<p class="note">No parity output found under <code>results/parity</code>.</p>')
    for p in rep.parity:
        tol = p.get("tolerance_pp")
        out.append(f'<p class="note">Snapshot <code>{E(p["snapshot"])}</code>: the Swift engine\'s output vs the '
                   f'harness port, per row; "within tol" is the share of rows within {tol} pp.</p>')
        rows = []
        for era, e in p.get("eras", {}).items():
            bw = " · ".join(f"{k} {v * 100:.1f}%" for k, v in e.get("by_window", {}).items())
            rows.append([E(era), f"{e['rows']:,}", f"{e['within_tol'] * 100:.2f}%", num(e["abs_delta_p90"]),
                         num(e["abs_delta_max"]), f"{e['method_agree'] * 100:.1f}%",
                         f"{e['reading_agree'] * 100:.1f}%", E(bw)])
        out.append(table(["era", "rows", "within tol", "|Δ| p90", "|Δ| max", "method agrees", "reading agrees",
                          "within tol by window"], rows, left=(0, 7)))
    return "".join(out)


GLOSSARY = [
    ("CRPS", "Continuous ranked probability score: how far a whole forecast distribution sits from what happened. "
             "Lower is better, and it rewards forecasts that are both sharp and honest about uncertainty."),
    ("Skill", "1 minus (model CRPS over baseline CRPS), computed on the same episode, checkpoint and target cells. "
              "0.20 means 20% lower CRPS than the baseline; negative means worse."),
    ("Coverage (cover80)", "The share of true values that fell inside the model's 80% interval. Honest is 0.80; "
                           "lower means over-confident, higher means too wide."),
    ("PIT / pit_tv", "The probability integral transform places each truth in the model's own forecast distribution. "
                     "A calibrated model fills ten bins evenly; pit_tv is the distance from flat (0 is calibrated)."),
    ("MCS", "Model confidence set (Hansen): the models that cannot be told apart from the best at the 90% level, "
            "by a block bootstrap over episodes. 'Tied for best' means in the set, not that it won."),
    ("ae_point, ae_reset, next_reading_ae, brier_hit", "Absolute error of the point estimate, of the predicted reset "
                                                        "time, and of the next reading, and the Brier score of the "
                                                        "limit-hit call."),
    ("Tiers", "visible: the data agents can see, for development. leaderboard: the held-out weeks that rank models. "
              "lockbox: the final weeks, scored rarely. Scores from different tiers or seeds are never averaged."),
]


def sec_caveats(narr_caveats: str | None) -> str:
    out = ['<h2 id="caveats">Caveats and method</h2>']
    if narr_caveats and narr_caveats.strip():
        out.append(f'<div class="card">{md.render(narr_caveats, base_level=4)}</div>')
    out.append("<h3>Glossary</h3><dl class='gloss'>" +
               "".join(f"<dt>{E(k)}</dt><dd>{E(v)}</dd>" for k, v in GLOSSARY) + "</dl>")
    return "".join(out)


def render(rep: Report, *, narrative: str | None, selftest: list[dict] | None) -> str:
    summary, caveats = md.split_caveats(narrative) if narrative else (None, None)
    run_rows = "".join(
        f'<div>run <code>{E(r["run_id"][:8])}</code> · {E(r["kind"])} · {E(r["tier"])} tier · seed {r["seed"]} · '
        f'snapshot <code>{E(r["snapshot_id"])}</code></div>' for r in rep.runs)
    nav = " · ".join(f'<a href="#{i}">{n}</a>' for i, n in (
        ("summary", "Summary"), ("winners", "Winners"), ("catalogue", "Catalogue"), ("agents", "Agents"),
        ("checks", "Checks"), ("caveats", "Caveats")))
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><title>Forecast arena report</title><style>{CSS}</style></head>
<body><main>
<h1>Forecast arena report</h1>
<p class="sub">Generated {stamp}. Baseline: <code>{E(rep.baseline or 'none')}</code>. {nav}</p>
<div class="runs">{run_rows}</div>
{sec_summary(summary)}
{sec_boards(rep)}
{sec_catalogue(rep)}
{sec_agents(rep)}
{sec_checks(selftest, rep)}
{sec_caveats(caveats)}
</main></body></html>
"""


def load_selftest(path: Path) -> list[dict]:
    d = json.loads(path.read_text())
    if isinstance(d, dict):
        for k in ("checks", "tests", "results"):
            if isinstance(d.get(k), list):
                return d[k]
        return [{"name": k, "status": v if isinstance(v, str) else ("pass" if v else "fail"), "detail": ""}
                for k, v in d.items()]
    return d
