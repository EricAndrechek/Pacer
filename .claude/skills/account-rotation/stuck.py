#!/usr/bin/env python3
"""Sessions stopped by a usage limit and not yet resumed.

  python3 -I stuck.py [HOURS]      (default 12)

Claude Code records the stop as an assistant line with "error":"rate_limit"
and isApiErrorMessage, text "You've hit your session limit · resets …". A
session does not retry on its own after a switch or a reset: it waits for its
next input. So a main transcript whose LAST assistant line is that stop is a
session that will sit idle until someone sends it a message.

Prints one line per stuck session: when it stopped, which limit, title, cwd,
session id. Subagent transcripts are skipped: the parent gets the failure as a
tool result and carries on (or stops itself, which shows up here).
"""
import json, os, sys, time, glob

HOURS = float(sys.argv[1]) if len(sys.argv) > 1 else 12.0
cut = time.time() - HOURS * 3600
home = os.path.expanduser("~")
roots = [f"{home}/.claude/projects", f"{home}/.config/claude/projects"]
roots += glob.glob(f"{home}/.claude-swap-backup/sessions/*/projects")

def tail_lines(path, nbytes=262144):
    with open(path, "rb") as f:
        f.seek(0, 2); size = f.tell()
        f.seek(max(0, size - nbytes))
        data = f.read()
    return data.splitlines()[1:] if size > nbytes else data.splitlines()

seen = set()
for root in roots:
    for p in glob.glob(f"{root}/*/*.jsonl"):
        rp = os.path.realpath(p)
        if rp in seen:
            continue
        seen.add(rp)
        try:
            if os.path.getmtime(rp) < cut:
                continue
            lines = tail_lines(rp)
        except OSError:
            continue
        last = None
        for line in reversed(lines):
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("type") == "assistant" and not r.get("isSidechain"):
                last = r
                break
        if not last or last.get("error") != "rate_limit":
            continue
        c = (last.get("message") or {}).get("content")
        text = c[0].get("text", "") if isinstance(c, list) and c and isinstance(c[0], dict) else str(c)
        title = ""
        tp = rp[:-6] + "/custom-title.json"
        if os.path.exists(tp):
            try:
                title = json.load(open(tp)).get("customTitle", "")
            except Exception:
                pass
        sid = os.path.basename(rp)[:-6]
        print(f'{last.get("timestamp", "?")[:16]}Z  {text[:70]:70}  {title or "-":24} {last.get("cwd", "?").replace(home, "~")}  {sid}')
