"""The one-page summary of the lab (reports/benchmark.html): the result, how
it works, one real window, how the approaches compare, what we learned.
Written for anyone; the full results are in benchmark-details.html.

  uv run report_data.py > reports/data.json && uv run report_html.py && uv run report_summary.py
"""
from __future__ import annotations

import json
from datetime import datetime

import numpy as np

import lab

OUT = lab.HERE / "reports" / "benchmark.html"
SIX = {"tokc-decay-30m": "Token spend, fading", "tokc-rate-30m-cal": "Token spend, steady",
       "fm-timestral-5m-6h_3d": "Timestral 5M", "fm-timestral-28m-6h_3d": "Timestral 28M",
       "fm-timestral-123m-6h_3d": "Timestral 123M", "fm-timestral-209m-1d_1w": "Timestral 209M"}


def example() -> dict:
    """A recent 5-hour window where the six disagree and their middle answer
    lands close: what the method is for, not its single best day."""
    c = lab.cases()
    g = c[c["window"] == "five_hour"].copy()
    for n in list(SIX) + ["l3-median6-5h", "rule-current"]:
        g = g.merge(lab.read_preds(n)[["case_id", "pred"]].rename(columns={"pred": n}), on="case_id", how="left")
        g[n] = lab.shown(g[n].to_numpy(), g["used_now"].to_numpy())
    g = g.dropna(subset=list(SIX) + ["l3-median6-5h", "rule-current"])
    P = g[list(SIX)].to_numpy()
    spread = P.max(axis=1) - P.min(axis=1)
    med_err = np.abs(g["l3-median6-5h"] - g["truth"])
    rule_err = np.abs(g["rule-current"] - g["truth"])
    pick = g[(spread >= np.quantile(spread, 0.7)) & (med_err <= 1.5) & rule_err.between(4, 10)
             & g["cut"].between(0.3, 0.6) & g["truth"].between(40, 90)].sort_values("t_cut")
    r = pick.iloc[-1]
    return {"start": datetime.fromtimestamp(r["cycle_start"]).strftime("%A %-d %B, %-I:%M %p"),
            "hours": float(r["t_cut"] - r["cycle_start"]) / 3600, "used": float(r["used_now"]),
            "truth": float(r["truth"]), "now": float(r["l3-median6-5h"]), "before": float(r["rule-current"]),
            "guesses": [{"label": label, "value": float(r[n])} for n, label in SIX.items()]}


def main() -> None:
    d = json.loads((lab.HERE / "reports" / "data.json").read_text())
    by = {e["name"]: e for e in d["candidates"]}
    c = lab.cases()

    def t(name, w="five_hour"):
        return by[name]["m"][w]["typical"]

    def best(pred, w="five_hour"):
        xs = [e for e in d["candidates"] if w in e["m"] and e["m"][w]["share"] >= 0.9 and pred(e)]
        return min(e["m"][w]["typical"] for e in xs)

    five = c[c["window"] == "five_hour"]
    week = c[c["window"] == "seven_day"]
    facts = {
        "windows": int(five.groupby(["account", "resets_at"]).ngroups),
        "weeks": int(week.groupby(["account", "resets_at"]).ngroups),
        "since": datetime.fromtimestamp(c["cycle_start"].min()).strftime("%B"),
        "candidates": len([e for e in d["candidates"] if e["layer"] != "ceiling"]),
        "now5": t("l3-median6-5h"), "before5": t("rule-current"),
        "now7": t("l3-median12-7d", "seven_day"), "before7": t("rule-current", "seven_day"),
        "early": by["l3-median6-5h"]["m"]["five_hour"]["early"], "late": by["l3-median6-5h"]["m"]["five_hour"]["late"],
        "ts5": t("fm-timestral-5m-6h_3d"), "ts209": t("fm-timestral-209m-1d_1w"),
        "learned": best(lambda e: e["tier"] == 3), "apple": t("afm-forecast", "seven_day"),
    }
    facts["bars"] = [
        {"name": "The middle answer of six forecasters", "note": "What your test build of Pacer uses now",
         "v": facts["now5"], "kind": "win"},
        {"name": "Smart pickers", "note": "Learn from your history which forecasters to trust. Tied, never better",
         "v": best(lambda e: e["node"] in ("weighted", "online", "p3online", "p3record")), "kind": ""},
        {"name": "Token-spend forecaster", "note": "Your last 30 minutes of tokens, priced like the API",
         "v": t("tokc-decay-30m"), "kind": ""},
        {"name": "Mistral's Timestral", "note": "A pretrained AI forecaster, never trained on your data",
         "v": t("fm-timestral-28m-6h_3d"), "kind": ""},
        {"name": "Other AI forecasters", "note": "Chronos, TimesFM, Toto, TiRex and Moirai",
         "v": best(lambda e: e["node"] == "fm"), "kind": ""},
        {"name": "Machine learning on your history", "note": "Models trained on your past windows",
         "v": best(lambda e: e["name"].startswith("ml-")), "kind": ""},
        {"name": "Pacer today", "note": "Fits a curve to this window's readings",
         "v": facts["before5"], "kind": "today"},
    ]
    facts["example"] = example()
    OUT.write_text(TEMPLATE.replace("/*DATA*/", json.dumps(facts)))
    print(OUT)


TEMPLATE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Closer Usage Forecasts</title>
<style>
:root{--page:#fcfcfb;--card:#f4f3ef;--ink:#0b0b0b;--ink2:#52514e;--muted:#898781;--line:#e1e0d9;
--accent:#2a78d6;--accent-soft:#d7e6f8;--grey:#c3c2b7;--dark:#6b6a65;
font:17px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;color-scheme:light}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--page:#0d0d0d;--card:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;
--muted:#898781;--line:#2c2c2a;--accent:#3987e5;--accent-soft:#1b3350;--grey:#4a4945;--dark:#9a9992;color-scheme:dark}}
:root[data-theme="dark"]{--page:#0d0d0d;--card:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--muted:#898781;--line:#2c2c2a;
--accent:#3987e5;--accent-soft:#1b3350;--grey:#4a4945;--dark:#9a9992;color-scheme:dark}
*{box-sizing:border-box}body{margin:0;background:var(--page);color:var(--ink)}
main{max-width:920px;margin:0 auto;padding:64px 20px 96px}
.eyebrow{font-size:13px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--accent)}
h1{font-size:clamp(34px,6vw,56px);line-height:1.06;letter-spacing:-.025em;margin:12px 0 16px}
h2{font-size:clamp(24px,3.6vw,32px);letter-spacing:-.02em;line-height:1.15;margin:96px 0 12px}
.lede{font-size:clamp(18px,2.2vw,21px);color:var(--ink2);max-width:40em;margin:0}
p{max-width:40em}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px;margin:40px 0 12px}
.stat{background:var(--card);border-radius:20px;padding:24px 26px}
.stat .k{font-size:14px;color:var(--ink2);font-weight:600}
.stat .v{font-size:56px;font-weight:700;letter-spacing:-.03em;line-height:1.1;margin:6px 0 2px;font-variant-numeric:tabular-nums}
.stat .v small{font-size:20px;font-weight:600;letter-spacing:0;color:var(--ink2);margin-left:6px}
.stat .was{font-size:15px;color:var(--ink2)}.stat .was b{color:var(--accent)}
.foot{font-size:14px;color:var(--muted)}
.steps{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin-top:28px}
@media(max-width:760px){.steps{grid-template-columns:1fr}}
.step{background:var(--card);border-radius:20px;padding:22px 24px}
.step .n{font-size:13px;font-weight:700;color:var(--accent)}
.step h3{font-size:19px;margin:6px 0 6px;letter-spacing:-.01em}.step p{font-size:15px;color:var(--ink2);margin:0}
.step svg{display:block;width:100%;height:64px;margin:4px 0 14px}
.meter{background:var(--card);border-radius:20px;padding:24px 26px;margin-top:24px}
.meter svg{display:block;width:100%;height:auto;overflow:visible}
.bars{margin-top:28px;display:grid;gap:18px}
.bar .top{display:flex;justify-content:space-between;align-items:baseline;gap:16px}
.bar .name{font-weight:650;font-size:17px}.bar .note{font-size:14px;color:var(--muted);margin-top:1px}
.bar .val{font-size:22px;font-weight:700;font-variant-numeric:tabular-nums;white-space:nowrap}
.bar .track{height:14px;border-radius:7px;background:var(--card);margin-top:8px;overflow:hidden}
.bar .fill{height:100%;border-radius:7px;background:var(--grey)}
.bar.win .fill{background:var(--accent)}.bar.win .val{color:var(--accent)}
.bar.today .fill{background:var(--dark)}
.badge{display:inline-block;font-size:11px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:var(--accent);
background:var(--accent-soft);border-radius:999px;padding:3px 9px;margin-left:8px;vertical-align:2px}
.scale{display:flex;justify-content:space-between;font-size:13px;color:var(--muted);margin-top:10px}
.cards{display:grid;grid-template-columns:repeat(2,1fr);gap:16px;margin-top:28px}
@media(max-width:640px){.cards{grid-template-columns:1fr}}
.cardx{background:var(--card);border-radius:20px;padding:24px 26px}
.cardx .big{font-size:40px;font-weight:700;letter-spacing:-.03em;line-height:1.1;color:var(--accent)}
.cardx h3{font-size:18px;margin:10px 0 6px}.cardx p{font-size:15px;color:var(--ink2);margin:0}
.weekly{display:flex;gap:20px;align-items:center;flex-wrap:wrap;background:var(--card);border-radius:20px;padding:22px 26px;margin-top:24px}
.weekly .v{font-size:34px;font-weight:700;letter-spacing:-.02em;font-variant-numeric:tabular-nums}
.weekly p{margin:0;color:var(--ink2);font-size:15px;flex:1;min-width:220px}
.fine{margin-top:96px;padding-top:24px;border-top:1px solid var(--line);font-size:14px;color:var(--muted)}
.fine p{max-width:none;margin:6px 0}.fine a{color:var(--accent)}
</style></head><body><main>
<div class="eyebrow">Pacer · forecasting lab</div>
<h1 id="h1"></h1>
<p class="lede" id="lede"></p>
<div class="stats" id="stats"></div>
<p class="foot">“Points off” is how far the forecast landed from where your usage meter really ended, in a typical window.</p>

<h2>How it works</h2>
<p class="lede">Ask several forecasters, then go with the middle answer.</p>
<div class="steps" id="steps"></div>

<h2>One real window</h2>
<p class="lede" id="exlede"></p>
<div class="meter" id="meter"></div>

<h2>Everything we tried</h2>
<p class="lede" id="trylede"></p>
<div class="bars" id="bars"></div>
<div class="scale"><span>0 = a perfect forecast</span><span>points off in a typical 5-hour window</span></div>
<div class="weekly" id="weekly"></div>

<h2>What we learned</h2>
<div class="cards" id="cards"></div>

<div class="fine" id="fine"></div>
</main>
<script>
const F=/*DATA*/;
const $=s=>document.querySelector(s);
const one=v=>v.toFixed(1);
const pct=(a,b)=>Math.round((1-a/b)*100);
$("#h1").textContent=`Pacer's usage forecasts are now ${pct(F.now5,F.before5)}% closer.`;
$("#lede").textContent=`Tested on every 5-hour window and every week of your Claude usage since ${F.since}: ${F.windows} windows and ${F.weeks} weeks.`;
$("#stats").innerHTML=[["5-hour limit",F.now5,F.before5],["Weekly limit",F.now7,F.before7]].map(([k,n,b])=>
 `<div class="stat"><div class="k">${k}</div><div class="v">${one(n)}<small>points off</small></div><div class="was">was ${one(b)} · <b>${pct(n,b)}% closer</b></div></div>`).join("");

// How it works: three small drawings.
const dots=(hl)=>{const xs=[18,34,47,55,66,84];return xs.map((x,i)=>`<circle cx="${x}%" cy="32" r="${hl&&i===2||hl&&i===3?0:7}" style="fill:${hl?"var(--grey)":"var(--accent)"}"/>`).join("")+
 (hl?`<circle cx="51%" cy="32" r="11" style="fill:var(--accent)"/>`:"")};
const steps=[["1","Six forecasters guess","Two read your recent token spend. Four are Mistral's Timestral AI, in different sizes.",
  `<line x1="6%" x2="94%" y1="32" y2="32" style="stroke:var(--line);stroke-width:2"/>${dots(false)}`],
 ["2","Pacer takes the middle guess","Guesses that run too high and too low cancel each other out.",
  `<line x1="6%" x2="94%" y1="32" y2="32" style="stroke:var(--line);stroke-width:2"/>${dots(true)}`],
 ["3","That's your forecast","Where your meter will be when the window resets, on the dashboard and in the menu bar.",
  `<rect x="6%" y="22" width="88%" height="20" rx="10" style="fill:var(--line)"/><rect x="6%" y="22" width="40%" height="20" rx="10" style="fill:var(--grey)"/><line x1="64%" x2="64%" y1="12" y2="52" style="stroke:var(--accent);stroke-width:4;stroke-linecap:round"/>`]];
$("#steps").innerHTML=steps.map(([n,h,p,svg])=>`<div class="step"><svg viewBox="0 0 300 64" preserveAspectRatio="none" aria-hidden="true">${svg}</svg><div class="n">Step ${n}</div><h3>${h}</h3><p>${p}</p></div>`).join("");

// One real window: the six guesses above a 0–100% meter, the new and the old
// forecast on their own rows below it, and where it really ended running
// through all three so the gap is the distance to that line.
// Drawn at the box's real width, so the text stays full size on a phone.
function drawMeter(){const e=F.example,box=$("#meter"),W=Math.max(300,Math.min(900,box.clientWidth-52)),narrow=W<560,
 L=narrow?62:96,R=narrow?8:16,x=v=>L+(W-L-R)*v/100,gy=72,ty=116,th=26,ny=196,by=246,r=narrow?5.5:7;
 $("#exlede").textContent=`${e.start}, ${e.hours.toFixed(1)} hours into a 5-hour window. The meter read ${Math.round(e.used)}%. Where would it end?`;
 let s=`<svg viewBox="0 0 ${W} 300" style="width:${W}px;max-width:100%" role="img" aria-label="Six guesses, the new and old forecasts, and where the meter really ended">`;
 const row=(y,t,c)=>`<text x="0" y="${y+5}" style="fill:${c};font-size:15px;font-weight:600">${t}</text>`;
 s+=row(gy,"Guesses","var(--ink2)")+row(ty+th/2,"Meter","var(--ink2)")+row(ny,"New","var(--accent)")+row(by,"Before","var(--ink2)");
 s+=`<rect x="${x(0)}" y="${ty}" width="${x(100)-x(0)}" height="${th}" rx="${th/2}" style="fill:var(--line)"/>`;
 s+=`<rect x="${x(0)}" y="${ty}" width="${Math.max(th,x(e.used)-x(0))}" height="${th}" rx="${th/2}" style="fill:var(--grey)"/>`;
 if(x(e.used)-x(0)>84)s+=`<text x="${x(e.used)-10}" y="${ty+th/2+5}" text-anchor="end" style="fill:var(--ink);font-size:13px">used ${Math.round(e.used)}%</text>`;
 s+=`<text x="${x(0)}" y="${ty+th+20}" style="fill:var(--muted);font-size:13px">0%</text><text x="${x(100)}" y="${ty+th+20}" text-anchor="end" style="fill:var(--muted);font-size:13px">100%</text>`;
 s+=`<line x1="${x(e.truth)}" x2="${x(e.truth)}" y1="30" y2="${by+18}" style="stroke:var(--ink);stroke-width:2;stroke-dasharray:4 4"/>`;
 s+=`<text x="${Math.min(W-R-70,Math.max(L+70,x(e.truth)))}" y="20" text-anchor="middle" style="fill:var(--ink);font-size:15px;font-weight:700">It ended at ${Math.round(e.truth)}%</text>`;
 const gs=[...e.guesses].sort((a,b)=>a.value-b.value),placed=[];
 gs.forEach(g=>{const step=r*2+1.5;let y=gy;for(const k of[0,-1,1,-2,2,-3,3]){y=gy+k*step;if(!placed.some(p=>Math.abs(p[0]-x(g.value))<step&&p[1]===y))break}
  placed.push([x(g.value),y]);
  s+=`<circle cx="${x(g.value)}" cy="${y}" r="${r}" style="fill:var(--accent);fill-opacity:.4"><title>${g.label}: ${Math.round(g.value)}%</title></circle>`});
 // The value goes on the side away from the truth line, unless that side has no room.
 const mark=(v,y,fill,stroke,txt,chars)=>{const w=chars*8.2+20;let right=x(v)>x(e.truth);
  if(!right&&x(v)-w<L)right=true;if(right&&x(v)+w>W-R)right=false;
  return `<circle cx="${x(v)}" cy="${y}" r="9" style="fill:${fill};stroke:${stroke};stroke-width:3"/>`+
  `<text x="${x(v)+(right?16:-16)}" y="${y+5}" text-anchor="${right?"start":"end"}" style="fill:var(--ink);font-size:15px;paint-order:stroke;stroke:var(--card);stroke-width:6px;stroke-linejoin:round">${txt}</text>`};
 s+=mark(e.now,ny,"var(--accent)","var(--page)",`<tspan style="font-weight:700;fill:var(--accent)">${Math.round(e.now)}%</tspan>, ${one(Math.abs(e.now-e.truth))} off`,12);
 s+=mark(e.before,by,"var(--page)","var(--dark)",`<tspan style="font-weight:700">${Math.round(e.before)}%</tspan>, ${one(Math.abs(e.before-e.truth))} off`,12);
 $("#meter").innerHTML=s+"</svg>"}
drawMeter();let rz;addEventListener("resize",()=>{clearTimeout(rz);rz=setTimeout(drawMeter,120)});

// Everything we tried.
const max=Math.max(...F.bars.map(b=>b.v))*1.08;
$("#trylede").textContent=`${F.candidates} approaches, from simple rules to AI forecasters and learned pickers. Shorter is better.`;
$("#bars").innerHTML=F.bars.map(b=>`<div class="bar ${b.kind}"><div class="top"><div><div class="name">${b.name}${b.kind==="win"?'<span class="badge">Best</span>':""}</div><div class="note">${b.note}</div></div><div class="val">${one(b.v)}</div></div>`+
 `<div class="track"><div class="fill" style="width:${b.v/max*100}%"></div></div></div>`).join("");
$("#weekly").innerHTML=`<div class="v">${one(F.before7)} → ${one(F.now7)}</div><p><b>Weekly limits:</b> the same idea, with twelve forecasters, takes the weekly forecast ${pct(F.now7,F.before7)}% closer. Weeks are harder to call: there are only ${F.weeks} of them to learn from so far.</p>`;

$("#cards").innerHTML=[["96%","Token spend is the signal","Your token spend, priced like the API, explains 96% of how your meter moves hour to hour."],
 ["Simple won","Learning more did worse",`The approaches that learned the most from your past did worse on new windows (${one(F.learned)} at best). Taking the middle answer needs no training at all.`],
 ["5M = 209M","Size didn't matter",`Mistral's smallest Timestral did as well as its largest (${one(F.ts5)} and ${one(F.ts209)} points off). Reading the last few hours mattered more than size.`],
 [`${Math.round(F.early)} → ${one(F.late)}`,"The first hours are hardest",`Early in a 5-hour window the forecast is off by about ${Math.round(F.early)} points. After halfway, by ${one(F.late)}.`]]
 .map(([b,h,p])=>`<div class="cardx"><div class="big">${b}</div><h3>${h}</h3><p>${p}</p></div>`).join("");
$("#fine").innerHTML=`<p><b>How we tested.</b> Every window was checked at eight moments, from 20% to 90% of the way through, using only the data that existed at that moment. Anything that learns was trained only on windows that had already ended.</p>`+
 `<p>Running in your test build of Pacer, not in a release yet. Pacer still checks each account's record and uses whichever model has done best; on your main account that is the middle answer. Apple's on-device model was far off as a forecaster (${Math.round(F.apple)} points on weekly windows), so it isn't shown.</p>`+
 `<p><a href="benchmark-details.html">Full results for all ${F.candidates} approaches →</a></p>`;
</script></body></html>
"""

if __name__ == "__main__":
    main()
