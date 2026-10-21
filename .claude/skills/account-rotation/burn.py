#!/usr/bin/env python3
"""Who is spending the 5h window right now.

  uv run --no-project python3 -I burn.py [MINUTES]     (default 60)

Reads the transcripts Claude Code wrote in the last MINUTES (every root Pacer
scans: ~/.claude, ~/.config/claude, cswap session profiles), dedups the way
Pacer does (messageId:requestId, the finished copy wins), and prints one row
per session, heaviest first. "weight" is Opus-relative cost: input 1, output 5,
cache write 1.25 (5m) / 2 (1h), cache read 0.1 — a proxy for what the rate
limit charges, good for ranking, not for absolute %.

Columns that point at waste:
  turns/h   a session waking very often (tight poll loop, Monitor spam)
  ctx       mean context per turn; every turn re-reads it from cache
  rd%       share of weight that is cache READS: high = big context x many turns
  wr%       share that is cache WRITES: high = context churn (compaction,
            cache misses past the 5m TTL, new subagents)
  sub       turns from subagents (subagents/*.jsonl), with their models
"""
import json, os, sys, time, glob
from collections import defaultdict

MIN = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
cut = time.time() - MIN * 60
home = os.path.expanduser("~")
roots = [f"{home}/.claude/projects", f"{home}/.config/claude/projects"]
roots += glob.glob(f"{home}/.claude-swap-backup/sessions/*/projects")

def iso(s):
    from datetime import datetime
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()

best = {}  # dedupKey -> (rank, row)
for root in roots:
    for dp, _, fs in os.walk(root):
        for f in fs:
            if not f.endswith(".jsonl"):
                continue
            p = os.path.join(dp, f)
            try:
                if os.path.getmtime(p) < cut:
                    continue
                fh = open(p, "rb")
            except OSError:
                continue
            sub = "/subagents/" in p
            with fh:
                for line in fh:
                    if b'"usage"' not in line:
                        continue
                    try:
                        r = json.loads(line)
                    except Exception:
                        continue
                    m = r.get("message") or {}
                    u = m.get("usage")
                    if r.get("type") != "assistant" or not u or m.get("model") == "<synthetic>":
                        continue
                    try:
                        t = iso(r["timestamp"])
                    except Exception:
                        continue
                    if t < cut:
                        continue
                    key = f'{m.get("id")}:{r.get("requestId")}'
                    rank = (m.get("stop_reason") is not None, u.get("output_tokens", 0))
                    if key in best and best[key][0] >= rank:
                        continue
                    best[key] = (rank, dict(
                        sid=r.get("sessionId", "?"), cwd=r.get("cwd", "?"), model=m.get("model", "?"),
                        sub=sub, t=t, u=u))

S = defaultdict(lambda: dict(turns=0, sub=0, w=0.0, rd=0.0, wr=0.0, out=0, ctx=0, models=defaultdict(int), cwd="", first=1e18, last=0))
tot = 0.0
for _, row in best.values():
    u = row["u"]
    cc = u.get("cache_creation") or {}
    w5 = cc.get("ephemeral_5m_input_tokens")
    w1 = cc.get("ephemeral_1h_input_tokens")
    cwt = u.get("cache_creation_input_tokens", 0) or 0
    if w5 is None and w1 is None:
        w5, w1 = cwt, 0
    w5 = w5 or 0; w1 = w1 or 0
    inp = u.get("input_tokens", 0) or 0
    out = u.get("output_tokens", 0) or 0
    rd = u.get("cache_read_input_tokens", 0) or 0
    scale = 0.2 if "haiku" in row["model"] else (0.6 if "sonnet" in row["model"] else (2.0 if "fable" in row["model"] else 1.0))
    wr = (w5 * 1.25 + w1 * 2.0) * scale
    rdw = rd * 0.1 * scale
    w = inp * scale + out * 5 * scale + wr + rdw
    s = S[row["sid"]]
    s["turns"] += 1; s["sub"] += row["sub"]; s["w"] += w; s["rd"] += rdw; s["wr"] += wr
    s["out"] += out; s["ctx"] += inp + rd + w5 + w1
    s["models"][row["model"].replace("claude-", "") + ("*" if row["sub"] else "")] += 1
    s["cwd"] = row["cwd"]; s["first"] = min(s["first"], row["t"]); s["last"] = max(s["last"], row["t"])
    tot += w

print(f"last {MIN:.0f} min: {len(best)} turns, {len(S)} sessions, total weight {tot/1e6:.1f}M (Opus-input-token equivalents)")
print(f"{'share':>5} {'weight':>7} {'turns':>5} {'t/h':>5} {'ctx':>6} {'rd%':>4} {'wr%':>4} {'sub':>4}  session   cwd · models (* = subagent)")
for sid, s in sorted(S.items(), key=lambda kv: -kv[1]["w"]):
    if s["w"] < tot * 0.005:
        continue
    span = max(s["last"] - s["first"], 60) / 3600
    cwd = s["cwd"].replace(home, "~")
    models = ", ".join(f"{k} {v}" for k, v in sorted(s["models"].items(), key=lambda kv: -kv[1]))
    print(f"{100*s['w']/tot:4.0f}% {s['w']/1e6:6.1f}M {s['turns']:5d} {s['turns']/span:5.0f} {s['ctx']/s['turns']/1e3:5.0f}k "
          f"{100*s['rd']/s['w']:3.0f}% {100*s['wr']/s['w']:3.0f}% {s['sub']:4d}  {sid[:8]}  {cwd} · {models}")
