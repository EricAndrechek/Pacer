"""Build reports/benchmark.html from reports/data.json (report_data.py): a
benchmark page in the style of a model leaderboard. Every number is an absolute
miss, so 0 is perfect; the layers of the chain are shown in order.

  uv run report_data.py > reports/data.json && uv run report_html.py
"""
from __future__ import annotations

import json

import lab

OUT = lab.HERE / "reports" / "benchmark.html"


def main() -> None:
    d = json.loads((lab.HERE / "reports" / "data.json").read_text())
    OUT.write_text(TEMPLATE.replace("/*DATA*/", json.dumps(d)))
    print(OUT)


TEMPLATE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pacer Forecasting Benchmark</title>
<style>
:root{--page:#f9f9f7;--surface:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;--muted:#898781;--grid:#e1e0d9;--axis:#c3c2b7;
--l1:#2a78d6;--l2:#eb6834;--l3:#6250d6;--ceil:#b3b2aa;--used:#eeede8;
font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;color-scheme:light}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--page:#0d0d0d;--surface:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;
--muted:#898781;--grid:#2c2c2a;--axis:#383835;--l1:#3987e5;--l2:#d95926;--l3:#9085e9;--ceil:#5f5e59;--used:#252523;color-scheme:dark}}
:root[data-theme="dark"]{--page:#0d0d0d;--surface:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--muted:#898781;--grid:#2c2c2a;
--axis:#383835;--l1:#3987e5;--l2:#d95926;--l3:#9085e9;--ceil:#5f5e59;--used:#252523;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:var(--page);color:var(--ink)}
header.top{position:sticky;top:0;z-index:6;background:color-mix(in oklab,var(--page) 90%,transparent);backdrop-filter:blur(8px);
-webkit-backdrop-filter:blur(8px);border-bottom:1px solid var(--grid)}
.top-in{max-width:1120px;margin:0 auto;padding:8px 16px;display:flex;align-items:center;gap:8px 18px;flex-wrap:wrap}
.top-in .brand{font-weight:600;font-size:14px}
nav{display:flex;gap:14px;font-size:13px;flex-wrap:wrap}nav a{color:var(--ink2);text-decoration:none}nav a:hover{color:var(--ink)}
.seg{display:inline-flex;border:1px solid var(--axis);border-radius:999px;padding:2px;margin-left:auto}
.seg button{font:inherit;font-size:13px;border:0;background:transparent;color:var(--ink2);padding:4px 14px;border-radius:999px;cursor:pointer}
.seg button[aria-pressed=true]{background:var(--ink);color:var(--page)}
main{max-width:1120px;margin:0 auto;padding:20px 16px 96px}
h1{font-size:32px;letter-spacing:-.02em;margin:12px 0 4px;line-height:1.15}
h2{font-size:21px;margin:56px 0 4px;letter-spacing:-.01em;scroll-margin-top:64px}
h3{font-size:14px;margin:18px 0 6px}
p{margin:6px 0;max-width:80ch}.lede{color:var(--ink2);font-size:16px}.meta{color:var(--muted);font-size:13px}
.card{background:var(--surface);border:1px solid var(--grid);border-radius:12px;padding:16px 18px;margin:12px 0}
dl.task{display:grid;grid-template-columns:max-content 1fr;gap:8px 20px;margin:0}dl.task dt{color:var(--muted);font-size:13px;padding-top:1px}
dl.task dd{margin:0}
@media(max-width:640px){dl.task{grid-template-columns:1fr;gap:2px}dl.task dt{padding-top:10px}nav{display:none}.zl{display:none}}
.tabs{display:flex;gap:6px;flex-wrap:wrap;margin:10px 0 4px}
.tabs button{font:inherit;font-size:13px;padding:5px 12px;border-radius:999px;border:1px solid var(--axis);background:transparent;color:var(--ink2);cursor:pointer}
.tabs button[aria-pressed=true]{background:var(--ink);color:var(--page);border-color:var(--ink)}
.controls{display:flex;gap:6px 16px;flex-wrap:wrap;align-items:center}
.chip{display:inline-flex;align-items:center;gap:6px;font-size:13px;padding:3px 6px 3px 12px;border-radius:999px;background:var(--used)}
.chip button{border:0;background:transparent;color:var(--ink2);cursor:pointer;font:inherit;font-size:15px;line-height:1;padding:0 4px}
.legend{display:flex;flex-wrap:wrap;gap:4px 16px;font-size:12.5px;color:var(--ink2);margin:8px 0 0}
.legend i{display:inline-block;width:12px;height:10px;border-radius:3px;margin-right:6px;vertical-align:-1px}
.legend .wh{display:inline-block;width:22px;height:10px;margin-right:6px;vertical-align:-1px;position:relative}
.legend .wh:before{content:"";position:absolute;left:0;right:0;top:4px;border-top:1.5px solid var(--ink2)}
.legend .wh:after{content:"";position:absolute;left:0;right:0;top:0;bottom:0;border-left:1.5px solid var(--ink2);border-right:1.5px solid var(--ink2)}

/* Horizontal bar boards: label column, then a track from 0 (perfect). */
.board{--lw:min(40%,360px);--vw:64px;position:relative;display:grid;grid-template-columns:var(--lw) 1fr;column-gap:12px}
@media(max-width:640px){.board{--lw:46%;--vw:52px}}
.gridlayer{position:absolute;top:0;bottom:0;left:calc(var(--lw) + 12px);right:var(--vw);pointer-events:none}
.gridlayer .gl{position:absolute;top:0;bottom:24px;border-left:1px solid var(--grid)}
.gridlayer .gl.zero{border-left:1.5px solid var(--axis)}
.gridlayer .tick{position:absolute;bottom:4px;transform:translateX(-50%);font-size:11px;color:var(--muted);white-space:nowrap;font-variant-numeric:tabular-nums}
.gridlayer .tick.zero{transform:none}
.gridlayer .ref{position:absolute;top:0;bottom:24px;border-left:1.5px dashed var(--ink2);opacity:.45}
.lh{grid-column:1/-1;display:flex;align-items:baseline;gap:4px 10px;flex-wrap:wrap;margin:14px 0 2px;padding:10px 0 2px;
border-top:1px solid var(--grid);background:var(--surface);position:relative}
.board>.lh:nth-child(2){border-top:0;margin-top:0;padding-top:0}
.lh .sw{width:10px;height:10px;border-radius:3px;align-self:center}.lh b{font-size:14px}.lh span{font-size:12.5px;color:var(--ink2)}
.br{grid-column:1/-1;display:grid;grid-template-columns:subgrid;border-radius:6px;cursor:default}
.br:hover{background:color-mix(in oklab,var(--used) 70%,transparent)}
.br-l{padding:4px 0;font-size:13px;line-height:1.3;text-align:right;align-self:center;min-width:0;overflow-wrap:anywhere}
.br-l .sub{display:block;color:var(--muted);font-size:11px}
.br-t{position:relative;height:24px;margin-right:var(--vw);align-self:center}
.br-b{position:absolute;left:0;top:5px;bottom:5px;border-radius:0 4px 4px 0;min-width:2px}
.br-w{position:absolute;top:11px;height:0;border-top:1.5px solid var(--ink2);opacity:.75}
.br-w:before,.br-w:after{content:"";position:absolute;top:-5px;height:9px;border-left:1.5px solid var(--ink2)}
.br-w:before{left:0}.br-w:after{right:0}
.br-v{position:absolute;top:3px;right:calc(-1 * var(--vw));width:calc(var(--vw) - 6px);text-align:right;font-size:12.5px;font-variant-numeric:tabular-nums;color:var(--ink);white-space:nowrap}
.f1{background:var(--l1)}.f2{background:var(--l2)}.f3{background:var(--l3)}.fc{background:var(--ceil)}
.hatch{background:repeating-linear-gradient(135deg,var(--l2) 0 3px,color-mix(in oklab,var(--l2) 28%,var(--surface)) 3px 6.5px)}
.tag{display:inline-block;font-size:9.5px;line-height:1;padding:3px 6px;border-radius:999px;border:1px solid var(--axis);color:var(--ink2);
margin-left:6px;vertical-align:1px;text-transform:uppercase;letter-spacing:.05em;white-space:nowrap}
.strip{position:relative;height:34px;margin-right:var(--vw);align-self:center}
.strip .dot{position:absolute;width:9px;height:9px;margin:-4.5px 0 0 -4.5px;border-radius:50%;border:1.5px solid var(--surface);opacity:.75}
.strip .dot.best{width:14px;height:14px;margin:-7px 0 0 -7px;opacity:1;border-width:2px}

/* The chain */
.chain{display:grid;grid-template-columns:.95fr 18px 1.15fr 18px 1.15fr 18px 1.05fr 18px .95fr;align-items:start}
.col h4{font-size:11.5px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:0 0 8px;font-weight:600}
.arrow{align-self:center;text-align:center;color:var(--muted);font-size:17px}
.node{background:var(--surface);border:1px solid var(--grid);border-top:3px solid var(--c,var(--axis));border-radius:10px;padding:9px 11px;margin-bottom:9px}
.node[data-node]{cursor:pointer}.node[data-node]:hover{border-color:var(--axis);border-top-color:var(--c)}
.node[data-l="1"]{--c:var(--l1)}.node[data-l="2"]{--c:var(--l2)}.node[data-l="3"]{--c:var(--l3)}.node[data-l="ceiling"]{--c:var(--ceil)}
.node .t{font-weight:600;font-size:13px;line-height:1.3}.node .n{font-size:11.5px;color:var(--muted)}
.node .d{font-size:11.5px;color:var(--ink2);margin:3px 0 6px;line-height:1.35}
.node .best{display:flex;align-items:center;gap:8px;font-size:12px;font-variant-numeric:tabular-nums}
.mini{height:7px;background:var(--used);border-radius:4px;position:relative;flex:1}
.mini i{position:absolute;left:0;top:0;bottom:0;border-radius:4px;background:var(--c)}
.node .bl{font-size:11px;color:var(--muted);margin-top:3px;line-height:1.3}
.node.live{box-shadow:0 0 0 2px color-mix(in oklab,var(--c) 40%,transparent)}
.node.dim{opacity:.62}
@media(max-width:900px){.chain{grid-template-columns:1fr}.arrow{padding:2px 0 8px}.arrow span{display:inline-block;transform:rotate(90deg)}}

/* Tables */
.tablewrap{overflow:auto;max-height:680px;border-radius:10px}
table{border-collapse:collapse;width:100%;font-size:13px;font-variant-numeric:tabular-nums}
th,td{padding:6px 8px;border-bottom:1px solid var(--grid);text-align:left;vertical-align:top}
th{color:var(--muted);font-weight:500;white-space:nowrap;position:sticky;top:0;background:var(--surface);z-index:1}
th[data-k]{cursor:pointer}th[data-k]:hover{color:var(--ink)}
td.n,th.n{text-align:right}td .sub{display:block;color:var(--muted);font-size:11px}
td.best{font-weight:700}
input[type=search]{font:inherit;font-size:13px;padding:5px 10px;border:1px solid var(--axis);border-radius:8px;background:var(--surface);color:var(--ink);width:min(300px,100%)}
ul{padding-left:20px;margin:6px 0}li{margin:4px 0;max-width:80ch}code{font-size:12.5px;overflow-wrap:anywhere}
svg{display:block;width:100%;height:auto;overflow:visible}
#tip{position:fixed;z-index:20;pointer-events:none;background:var(--ink);color:var(--page);font-size:12px;padding:8px 10px;border-radius:8px;
max-width:360px;display:none;line-height:1.4;box-shadow:0 4px 18px rgba(0,0,0,.18)}
#tip table{font-size:12px;margin-top:4px;width:auto}#tip td{padding:1px 10px 1px 0;border:0;color:var(--page)}
</style></head><body>
<header class="top"><div class="top-in"><span class="brand">Pacer forecasting benchmark</span>
<nav><a href="#steps">Summary</a><a href="#leaderboard">Leaderboard</a><a href="#chain">The chain</a><a href="#example">A real window</a>
<a href="#fit">Learning</a><a href="#all">Every candidate</a></nav>
<div class="seg" id="wseg" role="group" aria-label="Window"><button data-w="five_hour">5-hour</button><button data-w="seven_day">7-day</button></div>
</div></header>
<main>
<h1>Forecasting where the usage meter lands</h1>
<p class="lede">Every forecaster, combiner and picker from the overnight lab, scored on the same windows of your real history. Every score is how far the forecast landed from the real final reading, so <b>0 is perfect</b> and lower is better.</p>

<div class="card"><dl class="task">
<dt>Task</dt><dd>At a checkpoint inside a usage window, predict the meter's reading when the window resets.</dd>
<dt>Cases</dt><dd id="tcases"></dd>
<dt>Score</dt><dd>The miss: |forecast − final reading| in points of the meter. Over and under count the same. <span id="tscore"></span></dd>
<dt>Rules</dt><dd>Walk-forward: each forecast uses only data that existed at that moment, and everything that learns trains only on windows that had already ended. Nothing sees the answer.</dd>
<dt>Error bars</dt><dd>Your history split into four consecutive quarters; the whisker spans a model's best to worst quarter. A short whisker means it held up in every stretch of time.</dd>
</dl></div>

<h2 id="steps">From forecasters to the final answer</h2>
<p>The best entry at each layer of the chain, and how far a perfect picker could go. <span id="stepsnote"></span></p>
<div class="card"><div class="board" id="stepsboard"></div>
<div class="legend"><span><i class="f1"></i>Layer 1 · forecasters</span><span><i class="f2"></i>Layer 2 · combiners</span><span><i class="f3"></i>Layer 3 · pickers of pickers</span>
<span><i class="fc"></i>Hindsight ceiling</span><span><i class="hatch"></i>Pacer's shipping rule</span><span><span class="wh"></span>best to worst quarter</span></div></div>

<h2 id="leaderboard">Leaderboard</h2>
<p>Grouped by layer and sorted best first. The faint dashed line is Pacer's shipping rule; <span class="tag">live</span> marks lab models running in your Pacer now, <span class="tag">built in</span> Pacer's own models. Click a box in <a href="#chain">the chain</a> to see every member of that group.</p>
<div class="controls"><div class="tabs" id="mtabs"></div><div class="tabs" id="modetabs"></div><span id="nodechip"></span></div>
<p class="meta" id="mdesc"></p>
<div class="card"><div class="board" id="board"></div>
<div class="legend"><span><i class="f1"></i>Layer 1</span><span><i class="f2"></i>Layer 2</span><span><i class="f3"></i>Layer 3</span><span><i class="fc"></i>Hindsight</span>
<span><i class="hatch"></i>Shipping rule</span><span id="whlegend"><span class="wh"></span>best to worst quarter</span></div>
<p class="meta" id="sampled"></p></div>

<h2 id="chain">The chain, layer by layer</h2>
<p>Layer-1 forecasters each make their own prediction. Layer-2 combiners take all of those answers and produce one. Layer-3 pickers choose which combiner to trust. Each box shows how many variants were tried and the best one's typical miss, on the same scale. Boxes with a ring are part of what runs in your Pacer now.</p>
<div class="card"><div class="chain" id="chainview"></div></div>
<p id="livepath"></p>

<h2 id="example">One real window, through every layer</h2>
<p>Each dot is one answer for the same moment, on the same 0–100% meter scale. The vertical line is where the meter really ended. Lines show what feeds what: every forecaster into the median, and every combiner into the picker of pickers.</p>
<div class="tabs" id="extabs"></div>
<div class="card"><div id="exchart"></div><p id="excaption" style="margin-top:10px"></p></div>

<h2 id="fit">Does learning more from your history help?</h2>
<p>Every candidate as a dot, grouped by how much it learns from your past windows. Hover a dot for its details. The best of each group is the large dot.</p>
<div class="card"><div class="board" id="tierboard"></div>
<div class="legend"><span><i class="f1"></i>Layer 1</span><span><i class="f2"></i>Layer 2</span><span><i class="f3"></i>Layer 3</span></div></div>
<p id="tiernote"></p>

<h2 id="curves">Do they improve as history builds up?</h2>
<p>Typical miss on 5-hour windows, by how many of the account's own windows had already ended (the record a learner could use). <span id="curvenote"></span></p>
<div class="card"><div id="curvechart"></div><div class="legend" id="curvelegend"></div></div>

<h2 id="timestral">Timestral: size barely matters, context does</h2>
<p>Mistral's zero-shot forecaster at every size, by how much recent history it reads. Typical miss; the best of each window in bold.</p>
<div class="card tablewrap" id="tstable"></div>

<h2 id="tokens">What moves the meter</h2>
<div class="card"><ul>
<li><b>Token spend explains the meter almost completely:</b> hour by hour, out of sample, R² ≈ 0.96 on the 5-hour meter and 0.97 on the weekly one.</li>
<li><b>Price works as well as tokens:</b> API-equivalent cost with one factor per account fits the 5-hour meter as well as 25 separate token weights (busiest account: R² 0.964 vs 0.863). On the weekly meter, tokens (0.973) and cost with per-model factors (0.958) beat plain cost (0.892).</li>
<li><b>Per model:</b> Fable 5.1 moves the weekly meter about 2.5× more per dollar than average, consistent with its own weekly cap. Model and period are confounded: each model was used in different weeks.</li>
<li><b>The exchange rate drifts:</b> meter points per API dollar ranged 0.11–0.25 week to week, about ±30%. That is why the cost models recalibrate daily.</li>
<li><b>No off-peak discount found:</b> on the busiest account, 9 PM–3 AM moved the meter 20–30% <i>more</i> per dollar, and hour-of-day factors did not hold up out of sample.</li>
</ul><h3>5-hour meter points per API-equivalent dollar, by week (busiest account)</h3><div id="ppd"></div></div>

<h2 id="live">What runs in your Pacer now</h2>
<div class="card"><ul>
<li><b>5-hour:</b> the built-in curve fits, plus Cost burn fading, Cost burn held, Timestral 5M / 28M / 123M / 209M and their median, all served by the lab helper. Pacer's own selector picks between them by record; on your main account it picks the median.</li>
<li><b>7-day:</b> the built-ins plus Cost burn over the last day and a median of twelve. The built-in models still win the weekly pick.</li>
<li>After a reboot, restart the helper in the lab worktree with <code>LAB_HELPER_PYTHON=research/lab/foundation/.venv/bin/python make lab-helper</code>. Without it, Pacer falls back to its built-in models.</li>
</ul></div>

<h2 id="caveats">Caveats</h2>
<div class="card"><ul>
<li>The activity prior (your usual usage by hour) is built from the whole store, so "Your daily rhythm" and the ML features saw a little of the future. That mildly flatters them.</li>
<li>Weekly results rest on 276 checkpoints from about 34 completed weeks. Treat any single weekly winner as provisional, and look at its whisker.</li>
<li>With about 650 candidates, the best of any group is optimistically picked. A short whisker matters more than a small gap.</li>
<li>Early in a window every method misses far more than late in it (on 5-hour windows, about 7 points before halfway against under 2 after).</li>
</ul></div>

<h2 id="all">Every candidate</h2>
<div class="controls"><div class="tabs" id="alltabs"></div><input type="search" id="q" placeholder="Filter by name"><span class="meta" id="qn"></span></div>
<div class="card tablewrap"><table id="alltable"><thead></thead><tbody></tbody></table></div>
<p class="meta" id="built"></p>
</main><div id="tip"></div>
<script>
const D=/*DATA*/;
const $=s=>document.querySelector(s);
const store={get(k){try{return localStorage.getItem(k)}catch(e){return null}},set(k,v){try{localStorage.setItem(k,v)}catch(e){}}};
let W=store.get("bench.window")==="seven_day"?"seven_day":"five_hour";
const WN={five_hour:"5-hour",seven_day:"7-day"};
const BY=Object.fromEntries(D.candidates.map(c=>[c.name,c]));
const NODE=Object.fromEntries(D.nodes.map(n=>[n.id,n]));
const LAYERS=[1,2,3,"ceiling"];
const LN={1:"Layer 1 · Forecasters",2:"Layer 2 · Combiners",3:"Layer 3 · Pickers of pickers",ceiling:"Hindsight ceilings"};
const LD={1:"Each predicts the final reading on its own.",2:"Combine the forecasters' answers into one, or choose one of them.",
 3:"Choose which layer-2 combiner to trust.",ceiling:"Not real models: what a perfect picker would score, knowing the answers."};
const LF={1:"f1",2:"f2",3:"f3",ceiling:"fc"};
const LV={1:"var(--l1)",2:"var(--l2)",3:"var(--l3)",ceiling:"var(--ceil)"};
const METRICS=[
 {k:"typical",name:"Typical miss",unit:"pts",desc:w=>w==="five_hour"?"The median miss at reset, in meter points.":"The average miss at reset, in meter points (most weeks end at the cap, so the weekly median is near 0 for everyone)."},
 {k:"big",name:"Big misses",unit:"%",desc:()=>"Share of checkpoints the forecast missed by more than 5 points."},
 {k:"p90",name:"Bad-day miss",unit:"pts",desc:()=>"One checkpoint in ten misses by more than this."},
 {k:"early",name:"Early in the window",unit:"pts",desc:()=>"Typical miss at checkpoints before the halfway point."},
 {k:"late",name:"Late in the window",unit:"pts",desc:()=>"Typical miss at checkpoints after halfway."},
 {k:"worst",name:"Worst quarter",unit:"pts",desc:()=>"Typical miss in the worst of the four quarters of your history."}];
let metric="typical",mode="featured",nodeFilter=null,exIdx=0,allLayer="all",sortK="typical",sortAsc=true;
const M=(c,k=metric)=>c&&c.m[W]?c.m[W][k]:null;
const full=c=>c&&c.m[W]&&c.m[W].share>=0.9;
const lab=c=>((c.label&&c.label[W])||c.name)+(c.m[W]&&c.m[W].share<0.9?" (sample)":"");
const unitOf=k=>(METRICS.find(m=>m.k===k)||{unit:"pts"}).unit;
const fmt=(v,k="typical")=>v==null?"–":unitOf(k)==="%"?v.toFixed(0)+"%":v.toFixed(2);
const esc=s=>String(s).replace(/[&<>"]/g,ch=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[ch]));
function niceMax(v){if(!(v>0))return 1;const p=Math.pow(10,Math.floor(Math.log10(v)));for(const s of[1,1.5,2,2.5,3,4,5,6,8,10])if(v<=s*p)return s*p;return 10*p}
function stepFor(max){const raw=max/5,p=Math.pow(10,Math.floor(Math.log10(raw)));for(const s of[1,2,2.5,5,10])if(raw<=s*p)return s*p;return 10*p}
function tagsOf(c){const l=c.live&&c.live[W];return l==="lab"?["live"]:l==="built-in"?["built in"]:[]}
function bestOf(list,k="typical"){return list.filter(c=>full(c)&&M(c,k)!=null).sort((a,b)=>M(a,k)-M(b,k))[0]}

// Tooltip: any element with data-c (a candidate) or data-tip (html).
const tip=$("#tip");
function tipFor(c){const m=c.m[W];if(!m)return"";
 return `<b>${esc(lab(c))}</b><br><span style="opacity:.7">${esc(NODE[c.node].title)} · ${LN[c.layer]}</span><table>`+
 METRICS.map(x=>`<tr><td>${x.name}</td><td style="text-align:right">${fmt(m[x.k],x.k)}${x.unit==="%"?"":" pts"}</td></tr>`).join("")+
 (m.folds?`<tr><td>By quarter</td><td style="text-align:right">${m.folds.map(f=>f.toFixed(1)).join(" · ")}</td></tr>`:"")+
 `<tr><td>Checkpoints scored</td><td style="text-align:right">${m.cases.toLocaleString()}${m.share<0.9?" (sample)":""}</td></tr></table><span style="opacity:.55">${esc(c.name)}</span>`}
document.addEventListener("mousemove",e=>{const t=e.target.closest("[data-c],[data-tip]");if(!t){tip.style.display="none";return}
 tip.innerHTML=t.dataset.c?tipFor(BY[t.dataset.c]):t.dataset.tip;tip.style.display="block";
 const r=tip.getBoundingClientRect();let x=e.clientX+14,y=e.clientY+16;
 if(x+r.width>innerWidth-8)x=e.clientX-r.width-14;if(y+r.height>innerHeight-8)y=e.clientY-r.height-12;
 tip.style.left=Math.max(8,x)+"px";tip.style.top=Math.max(8,y)+"px"});
document.addEventListener("scroll",()=>tip.style.display="none",{passive:true});

// A bar board: groups of rows, a track from 0 (perfect), optional whiskers
// (best to worst quarter) and the shipping rule as a faint dashed line.
function board(el,groups,k,{ref=null,whisk=false}={}){
 const vals=groups.flatMap(g=>g.rows.flatMap(r=>[r.v,...(whisk&&r.folds?[Math.max(...r.folds)]:[])])).filter(v=>v!=null).sort((a,b)=>a-b);
 if(!vals.length){el.innerHTML='<p class="meta">Nothing to show for this window.</p>';return}
 const q=vals[Math.min(vals.length-1,Math.floor(vals.length*0.96))];
 const max=niceMax(Math.max(q,ref||0)*1.04),step=stepFor(max),x=v=>Math.max(0,Math.min(100,v/max*100));
 let h='<div class="gridlayer">';
 for(let v=0;v<=max+1e-9;v+=step){const z=v===0;
  h+=`<div class="gl${z?" zero":""}" style="left:${x(v)}%"></div><div class="tick${z?" zero":""}" style="left:${x(v)}%">${z?'0<span class="zl"> = perfect</span>':(+v.toFixed(2))+(unitOf(k)==="%"?"%":"")}</div>`}
 if(ref!=null)h+=`<div class="ref" style="left:${x(ref)}%"></div>`;
 h+="</div>";
 for(const g of groups){
  if(g.title)h+=`<div class="lh">${g.layer!=null?`<i class="sw ${LF[g.layer]}"></i>`:""}<b>${esc(g.title)}</b><span>${esc(g.desc||"")}</span></div>`;
  for(const r of g.rows){const over=r.v!=null&&r.v>max,w=r.v==null?0:x(r.v);
   let wh="";if(whisk&&r.folds){const a=x(Math.min(...r.folds)),b=x(Math.max(...r.folds));wh=`<div class="br-w" style="left:${a}%;width:${Math.max(.5,b-a)}%"></div>`}
   h+=`<div class="br"${r.c?` data-c="${esc(r.c.name)}"`:""}><div class="br-l">${esc(r.label)}${(r.tags||[]).map(t=>`<span class="tag">${t}</span>`).join("")}${r.sub?`<span class="sub">${esc(r.sub)}</span>`:""}</div>`+
    `<div class="br-t"><div class="br-b ${r.hatch?"hatch":r.cls}" style="width:${w}%"></div>${wh}<span class="br-v">${fmt(r.v,k)}${over?" ›":""}</span></div></div>`}}
 h+='<div style="grid-column:1/-1;height:28px"></div>';el.innerHTML=h}

function renderTask(){
 $("#tcases").textContent=`${D.cases.five_hour.toLocaleString()} checkpoints from 5-hour windows and ${D.cases.seven_day} from weekly windows: every completed window in your history, at 20%, 30% … 90% of the way through.`;
 $("#tscore").textContent=W==="five_hour"?"The headline is the typical (median) miss.":"On weekly windows the headline is the average miss, since most weeks end at the cap and the median miss is near 0 for everyone.";
 $("#built").textContent=`Built ${D.built} from the frozen lab snapshot. research/lab/reports/benchmark.html`}

function renderSteps(){
 const L=n=>bestOf(D.candidates.filter(c=>c.layer===n));
 const r=(c,label,cls,hatch)=>c?{c,label,sub:c.layer==="ceiling"?"hindsight, not a real model":lab(c)===label?"":lab(c),v:M(c,"typical"),folds:M(c,"folds"),cls,hatch,tags:tagsOf(c)}:null;
 const b1=L(1),b2=L(2),b3=L(3),rule=BY["rule-current"],ca=BY["p3-hindsight-acct"],cc=BY["p3-hindsight-case"];
 const groups=[{title:"Best at each layer",rows:[r(b1,"Best forecaster","f1"),r(b2,"Best combiner","f2"),r(b3,"Best picker of pickers","f3")].filter(Boolean)},
  {title:"For comparison",rows:[r(rule,"Pacer's shipping rule","f2",true),r(ca,"Perfect strategy per account","fc"),r(cc,"Perfect choice for every window","fc")].filter(Boolean)}];
 board($("#stepsboard"),groups,"typical",{whisk:true});
 const t=c=>M(c,"typical").toFixed(2);
 $("#stepsnote").textContent=W==="five_hour"
  ?`Combining the forecasters takes the typical miss from ${t(b1)} to ${t(b2)}. Picking between combiners adds nothing (${t(b3)}): the best strategy per account, even in hindsight, is the median itself (${t(ca)}). Only knowing every answer in advance would go further (${t(cc)}).`
  :`On weekly windows the best entries by score are ML models with long whiskers: excellent in some quarters, poor in others. The steadiest are the medians. A perfect per-account choice would reach ${t(ca)}; no real picker gets there yet on about 34 weeks of record.`}

function renderBoard(){
 $("#mtabs").innerHTML=METRICS.map(m=>`<button data-k="${m.k}" aria-pressed="${m.k===metric}">${m.name}</button>`).join("");
 $("#modetabs").innerHTML=[["featured","Featured"],["top","Top 20 per layer"]].map(([k,l])=>`<button data-mode="${k}" aria-pressed="${!nodeFilter&&k===mode}">${l}</button>`).join("");
 $("#nodechip").innerHTML=nodeFilter?`<span class="chip">${esc(NODE[nodeFilter].title)}<button aria-label="Clear" id="clearnode">×</button></span>`:"";
 const m=METRICS.find(x=>x.k===metric);$("#mdesc").textContent=m.desc(W);
 $("#whlegend").style.display=metric==="typical"?"":"none";
 const ok=c=>full(c)&&M(c)!=null;let names;
 if(nodeFilter)names=D.candidates.filter(c=>c.node===nodeFilter&&ok(c)).map(c=>c.name);
 else if(mode==="featured")names=D.featured[W].filter(n=>ok(BY[n]));
 else names=LAYERS.flatMap(L=>D.candidates.filter(c=>c.layer===L&&ok(c)).sort((a,b)=>M(a)-M(b)).slice(0,20).map(c=>c.name));
 if(!nodeFilter&&!names.includes("rule-current"))names.push("rule-current");
 const groups=LAYERS.map(L=>({layer:L,title:LN[L],desc:LD[L],rows:names.map(n=>BY[n]).filter(c=>c&&c.layer===L).sort((a,b)=>M(a)-M(b))
  .map(c=>({c,label:lab(c),sub:c.layer==="ceiling"?"":NODE[c.node].title,v:M(c),folds:M(c,"folds"),cls:LF[c.layer],hatch:c.name==="rule-current",tags:tagsOf(c)}))})).filter(g=>g.rows.length);
 board($("#board"),groups,metric,{ref:M(BY["rule-current"]),whisk:metric==="typical"});
 const s=D.candidates.filter(c=>c.m[W]&&c.m[W].share<0.9);
 $("#sampled").textContent=s.length?`Scored on a sample, so left off the board: ${s.map(c=>`${lab(c)} ${fmt(M(c))}`).join(" · ")}. As a router, Apple's model only tied the best forecaster it was choosing between on the same sample.`:""}

function renderChain(){
 const cols=[{h:"Inputs",inputs:[["Usage meter readings","The 5-hour and weekly percentages Pacer polls every few minutes."],["Token spend","From Claude Code's logs, priced at API-equivalent rates."],["Your completed windows","The record that learners train on and pickers judge by."]]},
  {h:"Layer 1 · Forecasters",ids:["fit","tok","timestral","fm","ml","afm-forecast"]},{h:"Layer 2 · Combiners",ids:["median","weighted","choose","online","learned","afm-router"]},
  {h:"Layer 3 · Pickers of pickers",ids:["p3record","p3online"]},{h:"Answer",out:true}];
 const live=new Set(["fit","tok","timestral","median","choose"]);
 const info=id=>{const mem=D.candidates.filter(c=>c.node===id&&c.m[W]);const b=bestOf(mem)||mem[0];return{mem,b,sampled:b&&!full(b)}};
 const all=D.nodes.map(n=>info(n.id)).filter(i=>i.b&&!i.sampled).map(i=>M(i.b,"typical"));const max=niceMax(Math.max(...all)*1.05);
 const card=(n,i)=>{if(!i.b)return"";const v=M(i.b,"typical");
  return `<div class="node${live.has(n.id)?" live":""}${i.sampled?" dim":""}" data-l="${n.layer}"${i.sampled?"":` data-node="${n.id}"`}><div class="t">${esc(n.title)}</div>`+
  `<div class="n">${i.mem.length} ${i.mem.length===1?"variant":"variants"}${live.has(n.id)?' · <span class="tag" style="margin:0">in Pacer</span>':""}</div><div class="d">${esc(n.desc)}</div>`+
  `<div class="best"><div class="mini"><i style="width:${Math.min(100,v/max*100)}%"></i></div><span>${fmt(v)}</span></div><div class="bl">${i.sampled?"sample only: ":"best: "}${esc(lab(i.b))}</div></div>`};
 let h="";cols.forEach((col,ci)=>{
  if(ci)h+='<div class="arrow"><span>→</span></div>';
  h+=`<div class="col"><h4>${col.h}</h4>`;
  if(col.inputs)h+=col.inputs.map(([t,d])=>`<div class="node"><div class="t">${t}</div><div class="d" style="margin-bottom:0">${d}</div></div>`).join("");
  if(col.ids)h+=col.ids.map(id=>card(NODE[id],info(id))).join("");
  if(col.out){h+=`<div class="node live" data-l="2"><div class="t">The forecast Pacer shows</div><div class="d" style="margin-bottom:0">Pacer's own selector picks, for each account and half of the window, whichever model has the best record.</div></div>`+
   `<h4 style="margin-top:14px">Ceilings</h4>`+["ceil-acct","ceil-case"].map(id=>card(NODE[id],info(id))).join("")}
  h+="</div>"});
 const el=$("#chainview");el.innerHTML=h;
 el.querySelectorAll("[data-node]").forEach(n=>n.onclick=()=>{nodeFilter=n.dataset.node;renderBoard();$("#leaderboard").scrollIntoView({behavior:"smooth"})});
 $("#livepath").textContent=W==="five_hour"
  ?"In your Pacer today the chain is: built-in curve fits plus the lab's cost-burn and Timestral forecasters (layer 1), the lab's median of six (layer 2), then Pacer's selector choosing by record between all of them. On your main account it chooses the median."
  :"Weekly, the chain is the same shape: built-ins plus the lab's cost burn and a median of twelve, with Pacer's selector choosing by record. The built-in models currently win that choice."}

function placeRow(vals,x,y0,r){const placed=[];const order=vals.map((v,i)=>[v,i]).sort((a,b)=>a[0]-b[0]);const ys=new Array(vals.length);
 for(const[v,i]of order){const cx=x(v);for(const dy of[0,-1,1,-2,2,-3,3,-4,4]){const cy=y0+dy*(r*2+1);if(placed.every(p=>Math.hypot(p[0]-cx,p[1]-cy)>=r*2+1)){placed.push([cx,cy]);ys[i]=cy;break}}if(ys[i]==null){ys[i]=y0;placed.push([cx,y0])}}
 return ys}
function renderExample(){
 const ex=D.examples[W]||[];if(!ex.length){$("#exchart").innerHTML='<p class="meta">No example for this window.</p>';return}
 exIdx=Math.min(exIdx,ex.length-1);
 $("#extabs").innerHTML=ex.map((e,i)=>`<button data-ex="${i}" aria-pressed="${i===exIdx}">${esc(e.title)}</button>`).join("");
 const e=ex[exIdx],err=v=>Math.abs(v-e.truth);
 const vals=[...e.layer1.map(d=>d.value),...e.layer2.map(d=>d.value),e.layer3.value,e.truth,e.used];
 let lo=Math.max(0,Math.floor((Math.min(...vals)-3)/5)*5),hi=Math.min(100,Math.ceil((Math.max(...vals)+3)/5)*5);if(hi-lo<15){hi=Math.min(100,lo+15);lo=Math.max(0,hi-15)}
 const Wd=1000,L=150,R=24,H=340,x=v=>L+(Wd-L-R)*(v-lo)/(hi-lo),r=6;
 const y1=92,y2=196,y3=272,top=44,bot=300;
 const ys1=placeRow(e.layer1.map(d=>d.value),x,y1,r),ys2=placeRow(e.layer2.map(d=>d.value),x,y2,r);
 const med=e.layer2.findIndex(d=>d.key==="median"),chosen=e.layer2.findIndex(d=>d.label===e.layer3.choice);
 let s=`<svg viewBox="0 0 ${Wd} ${H}" role="img" aria-label="One window through every layer">`;
 s+=`<rect x="${x(lo)}" y="${top}" width="${Math.max(0,x(e.used)-x(lo))}" height="${bot-top}" style="fill:var(--used)"/>`;
 s+=`<text x="${x(lo)+6}" y="${top+16}" style="fill:var(--muted);font-size:12px">already used: ${e.used.toFixed(0)}%</text>`;
 for(let v=lo;v<=hi;v+=5)s+=`<line x1="${x(v)}" x2="${x(v)}" y1="${top}" y2="${bot}" style="stroke:var(--grid)"/><text x="${x(v)}" y="${bot+18}" text-anchor="middle" style="fill:var(--muted);font-size:12px">${v}%</text>`;
 [[y1,"Layer 1","forecasters"],[y2,"Layer 2","combiners"],[y3,"Layer 3","picker of pickers"]].forEach(([y,a,b])=>{s+=`<text x="0" y="${y-2}" style="fill:var(--ink);font-size:13px;font-weight:600">${a}</text><text x="0" y="${y+14}" style="fill:var(--muted);font-size:12px">${b}</text>`});
 e.layer1.forEach((d,i)=>{s+=`<line x1="${x(d.value)}" y1="${ys1[i]}" x2="${x(e.layer2[med].value)}" y2="${ys2[med]}" style="stroke:var(--l1);stroke-opacity:.22"/>`});
 e.layer2.forEach((d,i)=>{s+=`<line x1="${x(d.value)}" y1="${ys2[i]}" x2="${x(e.layer3.value)}" y2="${y3}" style="stroke:var(--l2);stroke-opacity:${i===chosen?.9:.2};stroke-width:${i===chosen?2:1}"/>`});
 s+=`<line x1="${x(e.truth)}" x2="${x(e.truth)}" y1="${top-8}" y2="${bot}" style="stroke:var(--ink);stroke-width:2"/>`;
 s+=`<text x="${x(e.truth)}" y="${top-14}" text-anchor="middle" style="fill:var(--ink);font-size:13px;font-weight:600">final reading ${e.truth.toFixed(0)}%</text>`;
 const tipd=(lbl,v,extra="")=>esc(`<b>${esc(lbl)}</b><br>${v.toFixed(1)}% · off by ${err(v).toFixed(1)} pts${extra}`);
 e.layer1.forEach((d,i)=>{s+=`<circle cx="${x(d.value)}" cy="${ys1[i]}" r="${r}" style="fill:var(--l1);stroke:var(--surface);stroke-width:2" data-tip="${tipd(d.label,d.value,"<br>"+esc(NODE[d.node].title))}"/>`});
 e.layer2.forEach((d,i)=>{const big=i===med||d.key==="rule-current";
  s+=`<circle cx="${x(d.value)}" cy="${ys2[i]}" r="${big?r+2:r}" style="fill:${d.key==="rule-current"?"var(--surface)":"var(--l2)"};stroke:${d.key==="rule-current"?"var(--l2)":"var(--surface)"};stroke-width:${d.key==="rule-current"?2.5:2}" data-tip="${tipd(d.label,d.value)}"/>`});
 const lab2=(i,txt,dy)=>{if(i<0)return"";const d=e.layer2[i];s+=`<text x="${x(d.value)}" y="${ys2[i]+dy}" text-anchor="middle" style="fill:var(--ink2);font-size:11.5px">${txt}</text>`};
 if(med>=0)s+=`<text x="${x(e.layer2[med].value)}" y="${Math.min(...ys2)-14}" text-anchor="middle" style="fill:var(--ink);font-size:12px;font-weight:600">median ${e.layer2[med].value.toFixed(0)}%</text>`;
 lab2(e.layer2.findIndex(d=>d.key==="rule-current"),"shipping rule",24);
 s+=`<circle cx="${x(e.layer3.value)}" cy="${y3}" r="${r+2}" style="fill:var(--l3);stroke:var(--surface);stroke-width:2" data-tip="${tipd(e.layer3.label,e.layer3.value,"<br>chose: "+esc(e.layer3.choice))}"/>`;
 const right=x(e.layer3.value)>Wd*0.62;
 s+=`<text x="${x(e.layer3.value)+(right?-14:14)}" y="${y3+4}" text-anchor="${right?"end":"start"}" style="fill:var(--ink2);font-size:12px">chose “${esc(e.layer3.choice)}”: ${e.layer3.value.toFixed(0)}%</text>`;
 s+="</svg>";$("#exchart").innerHTML=s;
 const l1=[...e.layer1].sort((a,b)=>err(a.value)-err(b.value)),mn=Math.min(...e.layer1.map(d=>d.value)),mx=Math.max(...e.layer1.map(d=>d.value));
 const rule=e.layer2.find(d=>d.key==="rule-current"),m2=e.layer2[med];
 const when=W==="five_hour"?`${e.elapsed_h.toFixed(1)} hours in`:`${(e.elapsed_h/24).toFixed(1)} days in`;
 $("#excaption").innerHTML=`${W==="five_hour"?"A 5-hour window":"A week"} starting ${esc(e.start)}, seen ${Math.round(e.cut*100)}% of the way through (${when}). The meter read <b>${e.used.toFixed(0)}%</b> and ended at <b>${e.truth.toFixed(0)}%</b>. `+
  `The ${e.layer1.length} forecasters said between ${mn.toFixed(0)}% and ${mx.toFixed(0)}%; the closest was ${esc(l1[0].label)}, off by ${err(l1[0].value).toFixed(1)}. `+
  `Their median said ${m2.value.toFixed(0)}% (off by ${err(m2.value).toFixed(1)}). Pacer's shipping rule said ${rule.value.toFixed(0)}% (off by ${err(rule.value).toFixed(1)}). `+
  `The picker of pickers chose “${esc(e.layer3.choice)}”: ${e.layer3.value.toFixed(0)}% (off by ${err(e.layer3.value).toFixed(1)}).`}

function renderTiers(){
 const cs=D.candidates.filter(c=>c.tier!=null&&full(c)&&M(c,"typical")!=null);
 const vals=cs.map(c=>M(c,"typical")).sort((a,b)=>a-b),max=niceMax(vals[Math.floor(vals.length*0.95)]*1.04),step=stepFor(max),x=v=>Math.min(100,v/max*100);
 const hash=s=>[...s].reduce((a,ch)=>(a*31+ch.charCodeAt(0))>>>0,7);
 let h='<div class="gridlayer">';for(let v=0;v<=max+1e-9;v+=step){const z=v===0;h+=`<div class="gl${z?" zero":""}" style="left:${x(v)}%"></div><div class="tick${z?" zero":""}" style="left:${x(v)}%">${z?'0<span class="zl"> = perfect</span>':+v.toFixed(2)}</div>`}
 const ref=M(BY["rule-current"],"typical");h+=`<div class="ref" style="left:${x(ref)}%"></div></div>`;
 D.tiers.forEach((t,i)=>{const mem=cs.filter(c=>c.tier===i),b=bestOf(mem);
  h+=`<div class="br"><div class="br-l">${esc(t)}<span class="sub">${mem.length} candidates${b?` · best: ${esc(lab(b))}, ${fmt(M(b,"typical"))}`:""}</span></div><div class="strip">`;
  mem.forEach(c=>{const v=M(c,"typical");const jy=8+(hash(c.name)%1000)/1000*18;
   h+=`<span class="dot${c===b?" best":""}" data-c="${esc(c.name)}" style="left:${x(v)}%;top:${c===b?17:jy}px;background:${LV[c.layer]}"></span>`});
  h+="</div></div>"});
 h+='<div style="grid-column:1/-1;height:28px"></div>';$("#tierboard").innerHTML=h;
 const bt=D.tiers.map((_,i)=>bestOf(cs.filter(c=>c.tier===i)));
 $("#tiernote").textContent=W==="five_hour"
  ?`The best of all needs no learning at all: the median of the forecasters (${fmt(M(bt[0],"typical"))}). The groups that learn the most from your history spread widest, and their best (${fmt(M(bt[3],"typical"))}) is behind the median: they fit the past closely and carry over less well to the next stretch of time. Anything past the end of the axis sits at its edge.`
  :`On weekly windows the best learned models score well overall (${fmt(M(bt[3],"typical"))}) but swing widely from quarter to quarter (see their whiskers in the leaderboard); with about 34 weeks of history there is little to learn from yet.`}

function renderCurves(){
 const C=D.curves.five_hour,S=[["rule-current","Pacer's shipping rule","var(--ink2)","5 4"],["tokc-decay-30m","Best forecaster (cost burn, fading)","var(--l1)",""],
  ["fm-timestral-28m-6h_3d","Timestral 28M","var(--l1)","2 4"],["p2-median","Median of the forecasters","var(--l2)",""],["l2-route-gbm-all","Learned router","var(--l2)","2 4"],
  ["p3-hedge-pick-e1-pooled","Picker of pickers (Hedge)","var(--l3)",""]].filter(s=>C.series[s[0]]);
 const Wd=1000,L=48,R=200,T=12,B=56,H=340,n=C.buckets.length,xs=i=>L+(Wd-L-R)*i/(n-1);
 const all=S.flatMap(s=>C.series[s[0]]).filter(v=>v!=null),max=niceMax(Math.max(...all)*1.05),step=stepFor(max),y=v=>T+(H-T-B)*(1-v/max);
 let s=`<svg viewBox="0 0 ${Wd} ${H}" role="img" aria-label="Learning curves">`;
 for(let v=0;v<=max+1e-9;v+=step)s+=`<line x1="${L}" x2="${Wd-R}" y1="${y(v)}" y2="${y(v)}" style="stroke:${v===0?"var(--axis)":"var(--grid)"}"/><text x="${L-8}" y="${y(v)+4}" text-anchor="end" style="fill:var(--muted);font-size:12px">${+v.toFixed(1)}</text>`;
 C.buckets.forEach((b,i)=>s+=`<text x="${xs(i)}" y="${H-B+20}" text-anchor="middle" style="fill:var(--ink2);font-size:12px">${b}</text><text x="${xs(i)}" y="${H-B+36}" text-anchor="middle" style="fill:var(--muted);font-size:11px">${C.counts[i]} checkpoints</text>`);
 s+=`<text x="${(L+Wd-R)/2}" y="${H-2}" text-anchor="middle" style="fill:var(--muted);font-size:12px">windows of the account's own record already completed</text>`;
 const ends=[];
 S.forEach(([k,l,c,dash])=>{const v=C.series[k],pts=v.map((y_,i)=>y_==null?null:[xs(i),y(y_)]).filter(Boolean);
  s+=`<polyline points="${pts.map(p=>p.join(",")).join(" ")}" style="fill:none;stroke:${c};stroke-width:2.2;stroke-dasharray:${dash||"none"}"/>`;
  v.forEach((y_,i)=>{if(y_!=null)s+=`<circle cx="${xs(i)}" cy="${y(y_)}" r="4" style="fill:${c};stroke:var(--surface);stroke-width:2" data-tip="${esc(`<b>${esc(l)}</b><br>${y_.toFixed(2)} pts with ${C.buckets[i]} windows of record`)}"/>`});
  const last=pts[pts.length-1];if(last)ends.push([last[1],l,c])});
 ends.sort((a,b)=>a[0]-b[0]);for(let i=1;i<ends.length;i++)if(ends[i][0]-ends[i-1][0]<15)ends[i][0]=ends[i-1][0]+15;
 ends.forEach(([yy,l,c])=>s+=`<text x="${Wd-R+12}" y="${yy+4}" style="fill:var(--ink2);font-size:12px">${esc(l)}</text>`);
 s+="</svg>";$("#curvechart").innerHTML=s;
 $("#curvelegend").innerHTML=S.map(([k,l,c,dash])=>`<span><svg width="24" height="10" style="display:inline-block;width:24px;vertical-align:0;margin-right:6px"><line x1="0" x2="24" y1="5" y2="5" style="stroke:${c};stroke-width:2.2;stroke-dasharray:${dash||"none"}"/></svg>${esc(l)}</span>`).join("");
 $("#curvenote").textContent=(W==="seven_day"?"The weekly version has too few weeks per group to read, so this is the 5-hour one. ":"")+"The learned layers start poor and improve with history; the median needs none, and the picker of pickers ends up matching it. Each group mixes accounts and periods, so the lines rise and fall together: compare the lines with each other, not one group with the next."}

function renderTimestral(){
 const sizes=["5M","28M","123M","209M"],ctxs=["6h_3d","12h_3d","1d_1w","2d_2w","1w_4w"],T=D.timestral.filter(t=>t.window===W);
 const span={"6h":"6 hours","12h":"12 hours","1d":"1 day","2d":"2 days","3d":"3 days","1w":"1 week","2w":"2 weeks","4w":"4 weeks"};
 const rows=ctxs.filter(c=>T.some(t=>t.context===c));const best=Math.min(...T.map(t=>t.typical));
 let h=`<table><thead><tr><th>Context read</th>${sizes.map(s=>`<th class="n">${s}</th>`).join("")}</tr></thead><tbody>`;
 rows.forEach(c=>{const p=c.split("_"),lbl=span[W==="five_hour"?p[0]:p[1]]||c;h+=`<tr><td>${lbl}</td>`+sizes.map(s=>{const t=T.find(t=>t.size===s&&t.context===c);return `<td class="n${t&&t.typical===best?" best":""}">${t?t.typical.toFixed(2):"–"}</td>`}).join("")+"</tr>"});
 h+=`</tbody></table><p class="meta" style="margin:10px 8px 4px">For scale: the best combiner scores ${fmt(M(bestOf(D.candidates.filter(c=>c.layer===2)),"typical"))} and Pacer's shipping rule ${fmt(M(BY["rule-current"],"typical"))} on the same checkpoints.</p>`;
 $("#tstable").innerHTML=h}

function renderPPD(){
 const wk=["May 4","May 11","May 18","May 25","Jun 1","Jun 8","Jun 15","Jun 22","Jun 29","Jul 6","Jul 13","Jul 20","Jul 27","Aug 3","Aug 10","Aug 17","Aug 24","Aug 31","Sep 7","Sep 14","Sep 21","Sep 28","Oct 5","Oct 12","Oct 19"];
 const v=[.184,.180,.202,.230,.186,.212,.193,.227,.253,.192,.145,.165,.182,.122,.113,.137,.123,.170,.153,.161,.201,.155,.170,.186,.167];
 const Wd=1000,L=48,R=16,T=12,B=34,H=230,x=i=>L+(Wd-L-R)*i/(v.length-1),y=a=>T+(H-T-B)*(1-a/.3);
 let s=`<svg viewBox="0 0 ${Wd} ${H}" role="img" aria-label="Meter points per dollar by week">`;
 [0,.1,.2,.3].forEach(a=>s+=`<line x1="${L}" x2="${Wd-R}" y1="${y(a)}" y2="${y(a)}" style="stroke:${a?"var(--grid)":"var(--axis)"}"/><text x="${L-8}" y="${y(a)+4}" text-anchor="end" style="fill:var(--muted);font-size:12px">${a.toFixed(1)}</text>`);
 wk.forEach((w,i)=>{if(i%4===0)s+=`<text x="${x(i)}" y="${H-10}" text-anchor="middle" style="fill:var(--muted);font-size:12px">${w}</text>`});
 s+=`<polyline points="${v.map((a,i)=>x(i)+","+y(a)).join(" ")}" style="fill:none;stroke:var(--l1);stroke-width:2"/>`;
 v.forEach((a,i)=>s+=`<circle cx="${x(i)}" cy="${y(a)}" r="4" style="fill:var(--l1);stroke:var(--surface);stroke-width:2" data-tip="${esc(`Week of ${wk[i]}: ${a.toFixed(3)} points per dollar`)}"/>`);
 $("#ppd").innerHTML=s+"</svg>"}

function renderAll(){
 $("#alltabs").innerHTML=[["all","All"],[1,"Layer 1"],[2,"Layer 2"],[3,"Layer 3"],["ceiling","Hindsight"]].map(([k,l])=>`<button data-al="${k}" aria-pressed="${String(k)===String(allLayer)}">${l}</button>`).join("");
 const cols=[["label","Candidate"],["node","Group"],["typical","Typical miss",1],["big","Big misses",1],["p90","Bad-day",1],["early","Early",1],["late","Late",1],["worst","Worst quarter",1],["cases","Checkpoints",1]];
 const q=$("#q").value.toLowerCase();
 let rows=D.candidates.filter(c=>c.m[W]&&(allLayer==="all"||String(c.layer)===String(allLayer))&&(lab(c)+" "+c.name+" "+NODE[c.node].title).toLowerCase().includes(q));
 const key=c=>sortK==="label"?lab(c):sortK==="node"?NODE[c.node].title:M(c,sortK);
 rows.sort((a,b)=>{const x=key(a),y=key(b);if(x==null)return 1;if(y==null)return -1;return(x<y?-1:x>y?1:0)*(sortAsc?1:-1)});
 const real=D.candidates.filter(c=>c.layer!=="ceiling"&&full(c));const bests={};["typical","big","p90","early","late","worst"].forEach(k=>bests[k]=Math.min(...real.map(c=>M(c,k)).filter(v=>v!=null)));
 $("#alltable thead").innerHTML="<tr>"+cols.map(([k,l,n])=>`<th data-k="${k}" class="${n?"n":""}">${l}${sortK===k?(sortAsc?" ↑":" ↓"):""}</th>`).join("")+"</tr>";
 $("#alltable tbody").innerHTML=rows.map(c=>{const m=c.m[W];return `<tr data-c="${esc(c.name)}"><td>${esc(lab(c))}${tagsOf(c).map(t=>`<span class="tag">${t}</span>`).join("")}${c.name==="rule-current"?'<span class="tag">shipping</span>':""}<span class="sub">${esc(c.name)}${m.share<0.9?" · sample":""}</span></td>`+
  `<td><span style="display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:6px;background:${LV[c.layer]}"></span>${esc(NODE[c.node].title)}</td>`+
  ["typical","big","p90","early","late","worst"].map(k=>`<td class="n${c.layer!=="ceiling"&&full(c)&&m[k]!=null&&Math.abs(m[k]-bests[k])<1e-9?" best":""}">${fmt(m[k],k)}</td>`).join("")+`<td class="n">${m.cases.toLocaleString()}</td></tr>`}).join("");
 $("#qn").textContent=`${rows.length} candidates · best real score in each column in bold`}

function renderAllSections(){
 document.querySelectorAll("#wseg button").forEach(b=>b.setAttribute("aria-pressed",b.dataset.w===W));
 renderTask();renderSteps();renderBoard();renderChain();renderExample();renderTiers();renderCurves();renderTimestral();renderAll()}
document.addEventListener("click",e=>{const t=e.target.closest("button,th[data-k]");if(!t)return;
 if(t.dataset.w){W=t.dataset.w;store.set("bench.window",W);exIdx=0;renderAllSections()}
 else if(t.dataset.k&&t.closest("#mtabs")){metric=t.dataset.k;renderBoard()}
 else if(t.dataset.mode){mode=t.dataset.mode;nodeFilter=null;renderBoard()}
 else if(t.id==="clearnode"){nodeFilter=null;renderBoard()}
 else if(t.dataset.ex!=null){exIdx=+t.dataset.ex;renderExample()}
 else if(t.dataset.al!=null){allLayer=t.dataset.al==="all"||t.dataset.al==="ceiling"?t.dataset.al:+t.dataset.al;renderAll()}
 else if(t.tagName==="TH"){const k=t.dataset.k;sortAsc=sortK===k?!sortAsc:true;sortK=k;renderAll()}});
$("#q").addEventListener("input",renderAll);
renderPPD();renderAllSections();
</script></body></html>
"""

if __name__ == "__main__":
    main()
