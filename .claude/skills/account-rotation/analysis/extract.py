#!/usr/bin/env python3
"""Session-wakes extractor: Claude Code transcripts -> Parquet + wakes.duckdb.

READ-ONLY on transcripts. Run:
  uv run --no-project --with duckdb --with pyarrow python3 -I extract.py [--full] [--workers N] [--quiet]

Layout (~/.cache/session-wakes/):
  raw/<table>/bNN.parquet   per-bucket raw rows (bucket = crc32(realpath) % 64)
  state/bNN.json            per-file manifest: size, mtime, inode, parsed offset, resume point
  <table>.parquet           final tables (global dedup + aggregates), rebuilt every run
  wakes.duckdb              views over the final parquet + macros + user-owned `cutovers`

Incremental: a file whose size/mtime are unchanged is skipped. An appended file is re-parsed
from the START of its last (possibly still open) turn, and that file's rows from that turn on
are replaced, so a turn or a streamed message that straddles two runs is never split or
duplicated. A file that shrank or changed inode is re-parsed whole. Rows of transcripts that
have since been deleted (Claude Code's cleanup) are kept.
"""
import glob
import json
import os
import re
import sys
import time
import zlib
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime

HOME = os.path.expanduser('~')
OUT = os.path.join(HOME, '.cache', 'session-wakes')
RAW = os.path.join(OUT, 'raw')
STATE = os.path.join(OUT, 'state')
NB = 64
SCHEMA_VERSION = 6  # bump when raw row shape / parse rules change -> forces a full re-parse
DB_VERSION = 4      # bump when views/macros change -> wakes.duckdb views recreated
ROOTS = [os.path.join(HOME, '.claude', 'projects'), os.path.join(HOME, '.config', 'claude', 'projects')] + \
    sorted(glob.glob(os.path.join(HOME, '.claude-swap-backup', 'sessions', '*', 'projects')))
# Inputs that exist only for one team's tooling are optional env vars with no default. Unset (or a
# missing file) leaves the matching table empty.
#   WAKES_CI_WAIT_POLLS  JSONL of CI-wait poll requests {ts, pid, url, code, remaining, resource}
#   WAKES_ROLLOUT_LOG    JSONL of watcher-engine rollout events {ts, change, version, event, session, ...}
#   WAKES_EXCLUDE        ';'-separated rules marking requests to leave out of totals (flagged, not dropped):
#                          cwd:<SQL LIKE pattern>            every pid traced to a session whose cwd matches
#                          window:<ISO start>/<ISO end>      requests inside the interval
#   WAKES_WATCH_EXTRA    extra regex alternation naming a watcher launch command
#   WAKES_PILOT_RE       regex with ONE group capturing a watcher-engine version in a command
#   WAKES_AWS_MARK       substring marking an AWS-support event line
POLLS_LOG = os.environ.get('WAKES_CI_WAIT_POLLS', '')
ROLLOUT_LOG = os.environ.get('WAKES_ROLLOUT_LOG', '')
EXCLUDE = os.environ.get('WAKES_EXCLUDE', '')
WATCH_EXTRA = os.environ.get('WAKES_WATCH_EXTRA', '')
PILOT_PAT = os.environ.get('WAKES_PILOT_RE', '') or r'(?!)()'
AWS_MARK = os.environ.get('WAKES_AWS_MARK', '')

# --------------------------------------------------------------------------- classification
# Ported from an earlier wake-cost research script (classify_notif / event_cat / is_relaunch).

def classify_notif(t):
    m = re.search(r'<summary>(.*?)</summary>', t, re.S)
    s = (m.group(1) if m else t[:80])
    if s.startswith('Background command'): return 'bg-task(idle-watch exit)', s
    if s.startswith('Monitor event'): return 'monitor-event', s
    if s.startswith('Agent ') or 'subagent' in s.lower(): return 'subagent-done', s
    if 'wakeup' in s.lower() or 'schedule' in s.lower() or 'cron' in s.lower(): return 'scheduled', s
    return 'other-notification', s


def event_cat(t):
    m = re.search(r'<event>(.*?)</event>', t, re.S)
    if not m: return None
    e = m.group(1).strip(); fl = e.split('\n')[0]
    if 'Monitor expired' in fl: return 'monitor-expired(no events)' if 'no events' in fl else 'monitor-expired(had events)'
    if 'resumed from state' in fl or 'armed' in fl and 'watch' in fl: return 'watcher-startup/armed'
    if 'comment by' in fl: return 'repos:comment'
    if re.search(r'new (PR|ISSUE)', fl): return 'repos:new-pr/issue'
    if 'OnCall alerts' in fl or 'oncall' in fl.lower(): return 'oncall'
    if 'NOW FIRING' in fl or 'RESOLVED' in fl or 'alert-watch' in fl: return 'alerts'
    if 'AWS support' in fl or (AWS_MARK and AWS_MARK in fl): return 'aws-support'
    if 'loop' in fl.lower(): return 'whc-loops'
    return 'other:' + re.sub(r'[0-9a-f]{8,}|\d+', 'N', fl)[:30]


NOTIF_MAP = {'bg-task(idle-watch exit)': 'bg-task', 'monitor-event': 'monitor-event',
             'subagent-done': 'subagent-done', 'scheduled': 'scheduled', 'other-notification': 'other'}

WAKESPY_WATCH_RE = re.compile(r'idle-watch|-watch\.sh|watcher')
# spec list, plus a wrapper script's idle.sh and any engine path named in WAKES_WATCH_EXTRA (item C)
WATCH_RE = re.compile(r'idle-watch|repo-watch|watch-repos|watch\.sh|tail\s+-F|/idle\.sh\b' + ('|' + WATCH_EXTRA if WATCH_EXTRA else ''))
SCRIPT_RE = re.compile(r'((?:~|\$HOME|\$\{HOME\}|/|\.{1,2}/)?[\w.~${}/-]*?([\w.-]*(?:watch|idle)[\w.-]*\.sh))')
PILOT_RE = re.compile(PILOT_PAT)
MARKER_RE = re.compile(r'--marker[\s=]+[\'"]?(agent:[\w.-]+)')
AGENT_MARK_RE = re.compile(r'<!--\s*(agent:[\w.-]+)')
# a wake's "first tool result reading the bg output": the task's own .output file, or a watcher's
# last-output copy (a wrapper may read /var/tmp/idle-watch-last.<name> after relaunching)
OUTREAD_RE = re.compile(r'idle-watch-last|watch-last|/tasks/[\w-]+\.output')

GH_SUBS = 'api|pr|run|issue|search|repo|release|workflow|auth|label|status|cache|secret|variable|gist|browse|project|ruleset|attestation|extension|alias|config|org|codespace'
GH_RE = re.compile(r'(?:^|(?<=[\s;&|(`\'"$]))(?:[\w.~$/-]*/)?gh\s+(' + GH_SUBS + r')\b([^\n;&|]*)', re.M)
LOOP_RE = re.compile(r'(?:^|[\s;&|(])(?:while|until|for)\s')
SLEEP_RE = re.compile(r'\bsleep\s+[\d$]')
WATCHUTIL_RE = re.compile(r'(?:^|[\s;&|(])watch\s+-n')
BODY_RE = re.compile(r'''(--body|--title|-m|--message|--notes|-b|-t|--subject|--body-file)(\s+|=)("(?:[^"\\]|\\.)*"|'[^']*')''')
HEREDOC_RE = re.compile(r'<<-?\s*([\'"]?)(\w+)\1')
# a gh named inside a grep/pgrep/pkill pattern is a search, not an invocation
PATTERN_ARG_RE = re.compile(r'''\b(p?grep|pkill|rg|ugrep|egrep|fgrep)\b((?:\s+-[-\w=]+)*)\s+("(?:[^"\\]|\\.)*"|'[^']*')''')
GH_WRITE_VERBS = {
    'pr': {'create', 'merge', 'comment', 'edit', 'review', 'ready', 'close', 'reopen', 'update-branch', 'lock'},
    'issue': {'create', 'comment', 'edit', 'close', 'reopen', 'delete', 'transfer', 'lock', 'pin', 'develop'},
    'run': {'rerun', 'cancel', 'delete'}, 'workflow': {'run', 'enable', 'disable'},
    'release': {'create', 'edit', 'delete', 'upload'}, 'label': {'create', 'edit', 'delete', 'clone'},
    'repo': {'create', 'edit', 'delete', 'fork', 'rename', 'archive', 'sync'},
    'secret': {'set', 'delete'}, 'variable': {'set', 'delete'}, 'cache': {'delete'},
}
GH_OUTBOUND_RE = re.compile(r'(?:^|(?<=[\s;&|(`$/]))gh\s+(?:issue|pr)\s+(?:comment|create|edit|review|merge)\b')
SLACK_RE = re.compile(r'\bslack\b[^\n|;&]*\bsend\b|chat\.postMessage')
GIT_WRITE_RE = re.compile(r'\bgit\s+(?:-C\s+\S+\s+)?(?:commit|push|merge|rebase|cherry-pick|tag|reset|revert|am|apply|stash|checkout|switch|restore|worktree\s+(?:add|remove)|branch\s+-[dDmM])\b')
FS_WRITE_RE = re.compile(r'\bsed\s+-i|\bperl\s+-\w*i|\btee\s|\bmv\s|\bcp\s|\brm\s|\bmkdir\s|\btouch\s|\bchmod\s|\bln\s+-|\binstall\s+-|\bpatch\s|\bwt\s+(?:merge|remove|switch)\b|\bterraform\s+apply|\bkubectl\s+(?:apply|delete|patch|edit|scale|rollout|annotate|label)\b|\bhelm\s+(?:install|upgrade|uninstall)\b|\bchezmoi\s+(?:apply|re-add|add)\b|\bmake\s+install\b')
REDIR_NULL_RE = re.compile(r'\d*>>?\s*/dev/null|\d*>&\d|&>\s*/dev/null')
REDIR_RE = re.compile(r'(?<![<>=-])>>?\s*[^\s|&;>()]')

READ_ONLY_TOOLS = {'Read', 'Grep', 'Glob', 'LS', 'WebFetch', 'WebSearch', 'ToolSearch', 'TaskOutput', 'TaskList',
                   'TaskGet', 'ListAgents', 'BashOutput', 'ListMcpResourcesTool', 'ReadMcpResourceTool', 'LSP'}
WRITE_TOOLS = {'Edit', 'Write', 'NotebookEdit', 'MultiEdit'}
OUTBOUND_TOOLS = {'SendMessage', 'PushNotification', 'SubagentHandback'}
MCP_OUT_RE = re.compile(r'slack_send|send_message|add_issue_comment|create_issue|create_pull_request|merge_pull_request|add_comment|reply_to|issue_write|pull_request_review_write|update_pull_request|update_issue')
MCP_WRITE_RE = re.compile(r'create|update|delete|add_|send|merge|push|write|mutate|install|post|apply|schedule')


def strip_bodies(cmd):
    """Drop heredoc bodies and quoted --body/-m/--title args so a gh call quoted inside a commit
    message or a comment body is not counted as an invocation."""
    if '<<' in cmd:
        out = []; i = 0
        while True:
            m = HEREDOC_RE.search(cmd, i)
            if not m: out.append(cmd[i:]); break
            nl = cmd.find('\n', m.end())
            if nl < 0: out.append(cmd[i:]); break
            end = re.compile(r'^\s*' + re.escape(m.group(2)) + r'\s*$', re.M).search(cmd, nl + 1)
            out.append(cmd[i:nl + 1])
            if not end: break
            i = end.end()
        cmd = ''.join(out)
    cmd = PATTERN_ARG_RE.sub(lambda m: m.group(1) + m.group(2) + ' ""', cmd)
    return BODY_RE.sub(lambda m: m.group(1) + m.group(2) + '""', cmd)


def norm_endpoint(rest):
    for tok in rest.split():
        x = tok.strip('"\'')
        if x.startswith('-'): continue
        if '/' in x or x in ('graphql', 'rate_limit', 'user', 'notifications'):
            p = re.sub(r'\?.*', '', x.lstrip('/'))
            p = re.sub(r'^repos/[^/]+/[^/]+', 'repos/R', p)
            p = re.sub(r'\b[0-9a-f]{40}\b', 'SHA', p)
            p = re.sub(r'\d+', 'N', p)
            return p[:80]
    return '?'


def parse_gh(cmd):
    """-> (list of gh invocation dicts, cmd_has_loop_sleep)."""
    if 'gh ' not in cmd: return [], False
    c = strip_bodies(cmd.replace('\\\n', ' '))
    loop = bool((LOOP_RE.search(c) and SLEEP_RE.search(c)) or WATCHUTIL_RE.search(c))
    out = []
    for m in GH_RE.finditer(c):
        sub, rest = m.group(1), m.group(2)
        toks = rest.split()
        if sub == 'api':
            ep = norm_endpoint(rest)
            mm = re.search(r'(?:-X|--method)[\s=]+([A-Za-z]+)', rest)
            if mm: meth = mm.group(1).upper()
            elif re.search(r'(?:^|\s)(?:-f|-F|--field|--raw-field|--input)\b', rest): meth = 'POST'
            else: meth = 'GET'
            if ep == 'graphql':
                is_write = 'mutation' in c
                meth = 'POST'
            else:
                is_write = meth in ('POST', 'PUT', 'PATCH', 'DELETE')
            verb = ''
        else:
            verb = next((x for x in toks if not x.startswith('-') and re.match(r'^[a-z][a-z-]*$', x)), '')
            ep = None; meth = None
            is_write = verb in GH_WRITE_VERBS.get(sub, ())
        watch = (sub == 'run' and verb == 'watch') or (sub == 'pr' and verb == 'checks' and '--watch' in rest) or \
                (sub == 'run' and verb == 'view' and '--watch' in rest)
        poll = loop and ((sub == 'run' and verb in ('list', 'view')) or (sub == 'pr' and verb == 'checks'))
        out.append(dict(sub=sub, verb=verb, endpoint=ep, method=meth, is_write=is_write, watch_mode=watch,
                        poll_loop=poll, invocation=('gh ' + sub + rest)[:300]))
    return out, loop


def classify_tool(name, inp, bg):
    """-> category: watcher_launch | outbound | write | read_only | other."""
    if name == 'Monitor': return 'watcher_launch'
    if name in ('Bash', 'PowerShell'):
        cmd = inp.get('command') or ''
        if bg and WATCH_RE.search(cmd): return 'watcher_launch'
        if GH_OUTBOUND_RE.search(strip_bodies(cmd)) or SLACK_RE.search(cmd): return 'outbound'
        c2 = REDIR_NULL_RE.sub(' ', strip_bodies(cmd))
        if GIT_WRITE_RE.search(c2) or FS_WRITE_RE.search(c2) or REDIR_RE.search(c2): return 'write'
        return 'read_only'
    if name in WRITE_TOOLS: return 'write'
    if name in OUTBOUND_TOOLS: return 'outbound'
    if name in READ_ONLY_TOOLS: return 'read_only'
    if name.startswith('mcp__'):
        op = name.rsplit('__', 1)[-1]
        if MCP_OUT_RE.search(op): return 'outbound'
        if MCP_WRITE_RE.search(op): return 'write'
        return 'read_only'
    return 'other'


def text_of(c):
    if isinstance(c, str): return c
    if isinstance(c, list):
        return ' '.join(x.get('text', '') for x in c if isinstance(x, dict) and x.get('type') == 'text')
    return ''


def tool_result_only(c):
    return isinstance(c, list) and c and all(isinstance(x, dict) and x.get('type') == 'tool_result' for x in c)


def result_text(block):
    c = block.get('content')
    if isinstance(c, str): return c
    if isinstance(c, list):
        return '\n'.join(x.get('text', '') for x in c if isinstance(x, dict) and x.get('type') == 'text')
    return ''


def parse_ts(s):
    try:
        return int(datetime.fromisoformat(s).timestamp() * 1_000_000)
    except Exception:
        return None


def ws(s, n):
    return re.sub(r'\s+', ' ', s or '').strip()[:n]


def classify_start(d, c, is_sub):
    """Is this user record a turn START? -> None (continues the current turn / skipped) or
    dict(trigger, raw, detail, text, ...). `raw` is the exact wakes.py label for cross-checks."""
    o = d.get('origin') or {}
    k = o.get('kind')
    txt = text_of(c)
    sched = bool(d.get('scheduledTaskId')) or d.get('turnOrigin') == 'scheduled'
    r = dict(trigger=None, raw=None, detail=None, text=None, peer_name=None, task_id=None,
             tool_use_id=None, output_file=None, notif_summary=None, event_cat=None, sched_id=d.get('scheduledTaskId'))

    def notif(r, raw_override=None):
        raw, summ = classify_notif(txt)
        r['raw'] = raw_override or raw
        r['trigger'] = 'scheduled' if sched or txt.lstrip().startswith('<scheduled-task') else NOTIF_MAP[raw]
        r['notif_summary'] = ws(summ, 200)
        ev = event_cat(txt) if raw == 'monitor-event' or '<event>' in txt else None
        r['event_cat'] = ev
        m = re.search(r'<event>(.*?)</event>', txt, re.S)
        r['detail'] = ws(summ + ((' | ' + m.group(1).strip().split('\n')[0]) if m else ''), 200)
        m = re.search(r'<task-id>(.*?)</task-id>', txt); r['task_id'] = m.group(1) if m else None
        m = re.search(r'<tool-use-id>(.*?)</tool-use-id>', txt); r['tool_use_id'] = m.group(1) if m else None
        m = re.search(r'<output-file>(.*?)</output-file>', txt); r['output_file'] = m.group(1) if m else None
        r['text'] = txt[:4000]
        return r

    if k == 'task-notification':
        return notif(r)
    if k == 'peer':
        body = str(o.get('body', ''))
        if body[:20].startswith('[Subagent hand'):
            r.update(trigger='subagent-handback', raw='subagent-handback(peer)')
        else:
            r.update(trigger='peer-sendmessage', raw='peer-sendmessage')
        r['peer_name'] = o.get('name') or '?'
        r['detail'] = ws(f"{r['peer_name']}: {body}", 200)
        r['text'] = (body or txt)[:4000]
        return r
    if k == 'human':
        r.update(trigger='human', raw='human', detail=ws(txt, 120), text=txt[:300])
        return r
    if k:
        trig = {'auto-continuation': 'auto-continuation', 'coordinator': 'coordinator'}.get(k, 'other')
        r.update(trigger=trig, raw='other-origin:' + k, detail=ws(f'{k}: {txt}', 200), text=txt[:4000])
        return r
    # no origin (older Claude Code builds, scheduled prompts, meta records)
    if txt.startswith('This session is being continued'):  # also when the compacted turn was a scheduled one
        r.update(trigger='compact-resume', raw='compact-resume', detail='compact-resume', text=txt[:300]); return r
    if sched:  # wakes.py skips these (isMeta) and folds their activity into the previous turn
        r.update(trigger='scheduled', raw='(skipped:isMeta-scheduled)', detail=ws(f"{d.get('scheduledTaskId') or 'scheduled'}: {txt}", 200),
                 text=txt[:1000])
        return r
    if d.get('isMeta'): return None
    if txt.startswith('This session is being continued'):
        r.update(trigger='compact-resume', raw='compact-resume', detail='compact-resume', text=txt[:300]); return r
    if re.match(r'\s*<(local-command|command-name|bash-|command-message)', txt): return None
    if txt.startswith('[Request interrupted'):
        r.update(trigger='other', raw='other', detail='interrupt', text=txt[:200]); return r
    head = txt.lstrip()[:300]
    if head.startswith('<task-notification>'):
        return notif(r, raw_override='human')  # pre-origin format; wakes.py would call it human
    if '<cross-session-message' in head:
        m = re.search(r'from-name="([^"]*)"', head)
        r.update(trigger='peer-sendmessage', raw='human', peer_name=m.group(1) if m else '?',
                 detail=ws(txt, 200), text=txt[:4000]); return r
    r.update(trigger='human', raw='human', detail=ws(txt, 120), text=txt[:300])
    return r

# --------------------------------------------------------------------------- per-file parser

COLS = {
    'api_calls': ['file', 'session_id', 'agent_id', 'is_subagent', 'turn_seq', 'pos', 'ts', 'msg_key', 'model',
                  'input', 'output', 'cache_read', 'cache_write_5m', 'cache_write_1h', 'stop_reason', 'error', 'n_copies'],
    'tool_calls': ['file', 'session_id', 'agent_id', 'is_subagent', 'turn_seq', 'pos', 'ts', 'msg_key', 'tool_use_id',
                   'tool', 'category', 'command', 'description', 'run_in_background', 'to', 'agent_model',
                   'subagent_type', 'effort', 'file_path', 'message', 'wakespy_relaunch', 'script_path',
                   'script_name', 'pilot_version', 'watch_marker', 'script_args', 'n_gh', 'cmd_poll_loop',
                   'result_head'],
    'gh_calls': ['file', 'session_id', 'agent_id', 'is_subagent', 'turn_seq', 'ts', 'tool_use_id', 'idx', 'tool',
                 'sub', 'verb', 'endpoint', 'method', 'is_write', 'watch_mode', 'poll_loop', 'in_loop_cmd',
                 'run_in_background', 'invocation'],
    'turns_base': ['file', 'session_id', 'agent_id', 'is_subagent', 'project', 'turn_seq', 'start_pos', 'start_ts',
                   'end_ts', 'cwd', 'trigger', 'trigger_raw', 'trigger_detail', 'trigger_text', 'notif_summary',
                   'event_cat', 'peer_name', 'task_id', 'trigger_tool_use_id', 'output_file', 'sched_id',
                   'wake_output', 'wake_output_tool', 'n_injected', 'n_compact', 'n_synthetic', 'n_rate_limit',
                   'busy_start', 'markers'],
    'api_errors': ['file', 'session_id', 'agent_id', 'turn_seq', 'ts', 'error', 'text'],
}


class Turn:
    __slots__ = ('seq', 'start_pos', 'start_ts', 'end_ts', 'cwd', 'r', 'calls', 'tool_ids', 'tools', 'n_injected',
                 'n_compact', 'n_synthetic', 'n_rate_limit', 'busy_start', 'want_out', 'readers', 'wake_output',
                 'wake_output_tool', 'markers', 'pending_results')

    def __init__(self, seq, pos, ts, cwd, r, busy):
        self.seq = seq; self.start_pos = pos; self.start_ts = ts; self.end_ts = ts; self.cwd = cwd; self.r = r
        self.calls = {}; self.tool_ids = {}; self.tools = []; self.n_injected = 0; self.n_compact = 0
        self.n_synthetic = 0; self.n_rate_limit = 0; self.busy_start = busy
        of = r.get('output_file')
        self.want_out = os.path.basename(of) if of else None
        self.readers = {}; self.wake_output = None; self.wake_output_tool = None; self.markers = set()
        self.pending_results = {}


def parse_file(rp, meta, start, seq0, ctx, out, end=None):
    """Parse rp from byte `start`. ctx = parser state at that point. Appends rows into `out`.
    Returns new manifest fields."""
    is_sub = meta['is_subagent']
    sid, aid, proj = meta['session_id'], meta['agent_id'], meta['project']
    base = (rp, sid, aid, is_sub)
    st_state = ctx.get('state', 'idle')
    lane_started = ctx.get('lane_started', False)
    cwd = ctx.get('cwd')
    seq = seq0
    cur = None
    resume_off, resume_seq, resume_ctx = start, seq0, dict(ctx)
    bad = 0
    A, T, G, TB, E = out['api_calls'], out['tool_calls'], out['gh_calls'], out['turns_base'], out['api_errors']

    def close(t):
        if t is None: return
        for key, c in t.calls.items():
            A.append(base + (t.seq, c[0], c[1], key, c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10]))
        for row in t.tools:
            T.append(row)
        r = t.r
        TB.append(base + (proj, t.seq, t.start_pos, t.start_ts, t.end_ts, t.cwd, r['trigger'], r['raw'], r['detail'],
                          r['text'], r['notif_summary'], r['event_cat'], r['peer_name'], r['task_id'], r['tool_use_id'],
                          r['output_file'], r['sched_id'], t.wake_output, t.wake_output_tool, t.n_injected, t.n_compact,
                          t.n_synthetic, t.n_rate_limit, t.busy_start, ','.join(sorted(t.markers)) or None))

    with open(rp, 'rb') as f:
        f.seek(start)
        pos = start
        for raw in f:
            if not raw.endswith(b'\n'):
                break  # partial last line of a live session: leave it for the next run
            if end is not None and pos >= end:
                break  # verify.py: stop where a stored manifest stopped
            lpos = pos
            pos += len(raw)
            if raw.startswith(b'{"type":"') and not raw.startswith((b'{"type":"user"', b'{"type":"assistant"', b'{"type":"system"')):
                continue
            if b'"type":"user"' not in raw and b'"type":"assistant"' not in raw and b'"type":"system"' not in raw:
                continue
            try:
                d = json.loads(raw)
            except Exception:
                bad += 1
                continue
            if not isinstance(d, dict): continue
            ty = d.get('type')
            if ty not in ('user', 'assistant', 'system'): continue
            ts_s = d.get('timestamp')
            if not ts_s: continue
            t = parse_ts(ts_s)
            if t is None: continue
            if d.get('cwd'): cwd = d['cwd']
            if ty == 'system':
                if cur is not None and (d.get('subtype') == 'compact_boundary' or d.get('compactMetadata')):
                    cur.n_compact += 1
                continue
            msg = d.get('message') or {}
            if not isinstance(msg, dict): continue
            c = msg.get('content')
            if ty == 'user':
                if not is_sub and d.get('isSidechain'): continue
                if tool_result_only(c):
                    st_state = 'busy'
                    if cur is not None:
                        cur.end_ts = max(cur.end_ts, t)
                        for b in c:
                            tid = b.get('tool_use_id')
                            ti = cur.pending_results.pop(tid, None)
                            if ti is not None:
                                txt = result_text(b)
                                T_row = cur.tools[ti]
                                cur.tools[ti] = T_row[:-1] + (ws(txt, 300),)
                                if cur.want_out and cur.wake_output is None and tid in cur.readers:
                                    cur.wake_output = txt[:6000]; cur.wake_output_tool = cur.readers[tid]
                    continue
                r = classify_start(d, c, is_sub)
                if r is None: continue
                if is_sub:
                    if not lane_started:
                        r['raw'] = 'lane-start'; r['trigger'] = 'lane-start'
                        r['detail'] = ws(meta.get('desc') or r.get('detail') or '', 200)
                        r['text'] = (text_of(c) or '')[:1000]
                        lane_started_now = True
                    elif st_state != 'idle':
                        if cur is not None: cur.n_injected += 1
                        continue  # delivered mid-turn: the lane was working, this does not wake it
                    else:
                        lane_started_now = True
                else:
                    lane_started_now = False
                # start a new turn
                close(cur)
                resume_off, resume_seq = lpos, seq
                resume_ctx = dict(state=st_state, lane_started=lane_started, cwd=cwd)
                cur = Turn(seq, lpos, t, d.get('cwd') or cwd, r, st_state != 'idle')
                seq += 1
                if lane_started_now: lane_started = True
                st_state = 'busy'
                continue
            # assistant
            if cur is None:
                r = dict(trigger='lane-start' if is_sub and not lane_started else 'other',
                         raw='pre/other', detail='pre', text=None, peer_name=None, task_id=None, tool_use_id=None,
                         output_file=None, notif_summary=None, event_cat=None, sched_id=None)
                resume_off, resume_seq = lpos, seq
                resume_ctx = dict(state=st_state, lane_started=lane_started, cwd=cwd)
                cur = Turn(seq, lpos, t, cwd, r, False)
                seq += 1
                lane_started = True
            cur.end_ts = max(cur.end_ts, t)
            model = msg.get('model') or ''
            sr = msg.get('stop_reason')
            if model == '<synthetic>':
                cur.n_synthetic += 1
                err = d.get('error')
                if err:
                    E.append((rp, sid, aid, cur.seq, t, str(err), ws(text_of(c), 200)))
                    if err == 'rate_limit': cur.n_rate_limit += 1
                st_state = 'idle'
                continue
            mid = msg.get('id') or d.get('uuid') or ''
            key = f"{mid}:{d.get('requestId') or ''}"
            u = msg.get('usage') or {}
            cc = u.get('cache_creation') or {}
            if isinstance(cc, dict) and ('ephemeral_5m_input_tokens' in cc or 'ephemeral_1h_input_tokens' in cc):
                c5, c1 = cc.get('ephemeral_5m_input_tokens') or 0, cc.get('ephemeral_1h_input_tokens') or 0
            else:
                c5, c1 = u.get('cache_creation_input_tokens') or 0, 0
            outp = u.get('output_tokens') or 0
            prev = cur.calls.get(key)
            if prev is None:
                cur.calls[key] = [lpos, t, model, u.get('input_tokens') or 0, outp, u.get('cache_read_input_tokens') or 0,
                                  c5, c1, sr, d.get('error'), 1]
            else:
                prev[10] += 1
                better = (sr is not None and prev[8] is None) or ((sr is None) == (prev[8] is None) and outp > prev[4])
                if better:
                    prev[2:10] = [model, u.get('input_tokens') or 0, outp, u.get('cache_read_input_tokens') or 0, c5, c1,
                                  sr, d.get('error') or prev[9]]
            if isinstance(c, list):
                for b in c:
                    if not isinstance(b, dict) or b.get('type') != 'tool_use': continue
                    tid = b.get('id') or ''
                    if tid in cur.tool_ids: continue
                    name = b.get('name') or '?'
                    inp = b.get('input') if isinstance(b.get('input'), dict) else {}
                    bg = bool(inp.get('run_in_background'))
                    cmd = inp.get('command') if isinstance(inp.get('command'), str) else None
                    cat = classify_tool(name, inp, bg)
                    spath = sname = pver = marker = sargs = None
                    ngh = 0; loop = False
                    if cmd is not None:
                        if cat == 'watcher_launch':
                            m = SCRIPT_RE.search(cmd)
                            if m:
                                spath = m.group(1).replace('${HOME}', '~').replace('$HOME', '~').replace(HOME, '~')
                                sname = m.group(2)
                                sargs = ws(cmd[m.end():], 300)
                            elif 'tail' in cmd:
                                sname = 'tail -F'
                            mm = PILOT_RE.search(cmd); pver = mm.group(1) if mm else None
                        mm = MARKER_RE.search(cmd); marker = mm.group(1) if mm else None
                        for mk in AGENT_MARK_RE.findall(cmd): cur.markers.add(mk)
                        if marker: cur.markers.add(marker)
                        ghs, loop = parse_gh(cmd)
                        ngh = len(ghs)
                        for i, g in enumerate(ghs):
                            G.append(base + (cur.seq, t, tid, i, name, g['sub'], g['verb'], g['endpoint'], g['method'],
                                             g['is_write'], g['watch_mode'], g['poll_loop'], loop, bg, g['invocation']))
                    fp = inp.get('file_path') or inp.get('notebook_path')
                    fp = fp if isinstance(fp, str) else None
                    message = inp.get('message') if name == 'SendMessage' else (inp.get('prompt') if name in ('Agent', 'Task') else None)
                    if message is not None and not isinstance(message, str): message = json.dumps(message)[:300]
                    if isinstance(message, str):
                        for mk in AGENT_MARK_RE.findall(message): cur.markers.add(mk)
                    wsr = name == 'Monitor' or (name == 'Bash' and (bg or bool(WAKESPY_WATCH_RE.search(cmd or ''))))
                    row = base + (cur.seq, lpos, t, key, tid, name, cat, (cmd or '')[:2000] if cmd is not None else None,
                                  ws(inp.get('description') if isinstance(inp.get('description'), str) else '', 200) or None,
                                  bg, str(inp.get('to')) if inp.get('to') is not None else None,
                                  str(inp.get('model')) if inp.get('model') is not None else None,
                                  str(inp.get('subagent_type')) if inp.get('subagent_type') is not None else None,
                                  str(inp.get('effort')) if inp.get('effort') is not None else None,
                                  fp, ws(message, 300) if isinstance(message, str) else None, wsr, spath, sname, pver,
                                  marker, sargs, ngh, loop, None)
                    cur.tool_ids[tid] = True
                    cur.pending_results[tid] = len(cur.tools)
                    cur.tools.append(row)
                    if cur.want_out and cur.wake_output is None:
                        hay = (fp or '') + ' ' + (cmd or '')
                        if cur.want_out in hay or OUTREAD_RE.search(hay):
                            cur.readers[tid] = name
            if sr is None or sr == 'tool_use':
                st_state = 'busy'
            else:
                st_state = 'idle'
    close(cur)
    return dict(offset=pos, resume_offset=resume_off, resume_seq=resume_seq, resume_ctx=resume_ctx, bad_lines=bad)

# --------------------------------------------------------------------------- buckets / storage


def schemas():
    import pyarrow as pa
    S, I, B, TS = pa.string(), pa.int64(), pa.bool_(), pa.int64()
    types = {
        'file': S, 'session_id': S, 'agent_id': S, 'is_subagent': B, 'turn_seq': I, 'pos': I, 'ts': TS, 'msg_key': S,
        'model': S, 'input': I, 'output': I, 'cache_read': I, 'cache_write_5m': I, 'cache_write_1h': I,
        'stop_reason': S, 'error': S, 'n_copies': I, 'tool_use_id': S, 'tool': S, 'category': S, 'command': S,
        'description': S, 'run_in_background': B, 'to': S, 'agent_model': S, 'subagent_type': S, 'effort': S,
        'file_path': S, 'message': S, 'wakespy_relaunch': B, 'script_path': S, 'script_name': S, 'pilot_version': S,
        'watch_marker': S, 'script_args': S, 'n_gh': I, 'cmd_poll_loop': B, 'result_head': S, 'idx': I, 'sub': S,
        'verb': S, 'endpoint': S, 'method': S, 'is_write': B, 'watch_mode': B, 'poll_loop': B, 'in_loop_cmd': B,
        'invocation': S, 'project': S, 'start_pos': I, 'start_ts': TS, 'end_ts': TS, 'cwd': S, 'trigger': S,
        'trigger_raw': S, 'trigger_detail': S, 'trigger_text': S, 'notif_summary': S, 'event_cat': S,
        'peer_name': S, 'task_id': S, 'trigger_tool_use_id': S, 'output_file': S, 'sched_id': S,
        'wake_output': S, 'wake_output_tool': S, 'n_injected': I, 'n_compact': I, 'n_synthetic': I,
        'n_rate_limit': I, 'busy_start': B, 'markers': S, 'text': S,
    }
    return {t: pa.schema([(c, types[c]) for c in cols]) for t, cols in COLS.items()}


def bucket_of(rp):
    return zlib.crc32(rp.encode()) % NB


def load_state(b):
    p = os.path.join(STATE, f'b{b:02d}.json')
    try:
        with open(p) as f:
            s = json.load(f)
        if s.get('_v') != SCHEMA_VERSION: return {}
        return s.get('files', {})
    except Exception:
        return {}


def process_bucket(b, tasks):
    """tasks: list of (rp, meta, mode, start, seq0, ctx, fstat). mode: 'full' | 'append'."""
    import pyarrow as pa
    import pyarrow.compute as pc
    import pyarrow.parquet as pq
    t0 = time.time()
    SC = schemas()
    out = {t: [] for t in COLS}
    st = load_state(b)
    nbytes = 0
    for rp, meta, mode, start, seq0, ctx, fstat in tasks:
        try:
            res = parse_file(rp, meta, start, seq0, ctx, out)
        except Exception as e:  # defensive: one unreadable file must not kill the run
            print(f'  ! {rp}: {e!r}', file=sys.stderr)
            continue
        nbytes += res['offset'] - start
        st[rp] = dict(size=fstat[0], mtime=fstat[1], ino=fstat[2], **res, meta=meta)
    drops = {}  # rp -> min turn_seq to drop (0 = all)
    for rp, meta, mode, start, seq0, ctx, fstat in tasks:
        drops[rp] = 0 if mode == 'full' else seq0
    for tname, rows in out.items():
        d = os.path.join(RAW, tname); os.makedirs(d, exist_ok=True)
        p = os.path.join(d, f'b{b:02d}.parquet')
        cols = COLS[tname]
        if rows:
            colv = list(zip(*rows))
            new = pa.Table.from_arrays([pa.array(colv[i], type=SC[tname].field(i).type) for i in range(len(cols))],
                                       schema=SC[tname])
        else:
            new = SC[tname].empty_table()
        parts = []
        if os.path.exists(p):
            old = pq.read_table(p)
            if old.schema.names == SC[tname].names:
                mask = None
                for rp, s0 in drops.items():
                    m = pc.equal(old['file'], rp)
                    if s0 > 0: m = pc.and_(m, pc.greater_equal(old['turn_seq'], s0))
                    mask = m if mask is None else pc.or_(mask, m)
                if mask is not None:
                    old = old.filter(pc.invert(pc.fill_null(mask, False)))
                parts.append(old.cast(SC[tname]))
        parts.append(new)
        tbl = pa.concat_tables(parts)
        tmp = p + '.tmp'
        pq.write_table(tbl, tmp, compression='zstd')
        os.replace(tmp, p)
    os.makedirs(STATE, exist_ok=True)
    tmp = os.path.join(STATE, f'b{b:02d}.json.tmp')
    with open(tmp, 'w') as f:
        json.dump({'_v': SCHEMA_VERSION, 'files': st}, f)
    os.replace(tmp, os.path.join(STATE, f'b{b:02d}.json'))
    return b, len(tasks), nbytes, {t: len(r) for t, r in out.items()}, time.time() - t0


def discover():
    files = {}
    seen_dirs = set()
    for root in ROOTS:
        if not os.path.isdir(root): continue
        for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
            rd = os.path.realpath(dirpath)
            if rd in seen_dirs:
                dirnames[:] = []
                continue
            seen_dirs.add(rd)
            for fn in filenames:
                if not fn.endswith('.jsonl'): continue
                rp = os.path.realpath(os.path.join(dirpath, fn))
                if rp in files: continue
                parts = rp.split('/')
                if 'subagents' in parts and fn.startswith('agent-'):
                    i = parts.index('subagents')
                    meta = dict(is_subagent=True, session_id=parts[i - 1], agent_id=fn[6:-6], project=parts[i - 2])
                else:
                    meta = dict(is_subagent=False, session_id=fn[:-6], agent_id=None, project=parts[-2])
                if meta['is_subagent']:
                    mp = rp[:-6] + '.meta.json'
                    try:
                        with open(mp) as f:
                            mj = json.load(f)
                        meta['desc'] = ws(f"{mj.get('agentType') or ''}: {mj.get('description') or ''}", 200)
                    except Exception:
                        meta['desc'] = None
                files[rp] = meta
    return files

# --------------------------------------------------------------------------- build (DuckDB)

# Item D. A watcher wake is `digest` when every item line it carried is one of the kinds the tier
# engine moves out of wakes: [other]-tagged items, "all emitting loops are registered again",
# "Terminated: 15" (someone's `pkill sleep`), a watcher source exiting. Boilerplate (headers, the
# "[exited with code N]" trailer, timestamps) is ignored. Peer messages and hand-backs are never classified.
DIGEST_RES = [
    re.compile(r'\[other\]', re.I),
    re.compile(r'all emitting loops are registered again', re.I),
    re.compile(r'Terminated:\s*15\b', re.I),
    re.compile(r'REAPPEARED \(not new\)|\bREAPPEARED\b', re.I),     # alert-watch self-check (tier engine: digest)
    re.compile(r'\b(source|watcher|feed|poller|stream|tail)\b.{0,80}\b(exited|exiting|died|stopped|ended|gone)\b|'
               r'\b(exited|died)\b.{0,40}\b(rc|code|status|signal)\b\s*=?\s*-?\d', re.I),
]
BOILER_RE = re.compile(
    r'^(idle-watch:\s*\d+\s+actionable line\(s\):?|\[exited with code -?\d+\]|written=\S+(\s+lines=\d+)?|'
    r'[-=#*_.~ ]+|\d{4}-\d\d-\d\d[T ][\d:.]+Z?|\d\d:\d\d(:\d\d)?Z?|exit(ed)?[= ]\d+|lines=\d+|'
    r'\(no output\)|<system-reminder>.*|</?details>|<summary>.*)$', re.I)
RESOLVED_RE = re.compile(r'✅\s*RESOLVED\b')  # alert transitions: the tier engine BATCHES these (own sub-flag)
HEARTBEAT_RE = re.compile(r'heartbeat|no actionable events|still idle|nothing new|idle for \d', re.I)
STARTUP_RE = re.compile(r'resumed from state|\barmed\b|baseline (taken|set|of)|starting|started watching|watching \d+ repo', re.I)


def digest_lines(trigger, text, out):
    """Item lines a wake carried: the notification's <event> (monitor) or the watcher output it read."""
    src = []
    if trigger == 'monitor-event' and text:
        m = re.search(r'<event>(.*?)</event>', text, re.S)
        if m: src.append(m.group(1))
    if out:
        src.append(out)
    lines = []
    for s in src:
        for ln in s.split('\n'):
            ln = re.sub(r'^\s*\d+(\t|→)', '', ln)  # Read tool's line-number prefix
            ln = ln.strip()
            ln = re.sub(r'^\[\d\d:\d\d(:\d\d)?Z?\]\s*', '', ln)
            if not ln or BOILER_RE.match(ln): continue
            lines.append(ln)
    return lines


def digest_class(trigger, text, out, from_watcher):
    """-> digest | resolved | heartbeat | startup | items | empty | unread | command-output | None (not a watcher wake).
    resolved = only RESOLVED transitions (optionally with digest lines): digest_able, batched rather than digested."""
    if trigger not in ('bg-task', 'monitor-event'): return None
    if trigger == 'bg-task' and not from_watcher and not (out and 'idle-watch' in out):
        return 'command-output'
    if trigger == 'bg-task' and out is None: return 'unread'
    lines = digest_lines(trigger, text, out)
    if not lines: return 'empty'
    kinds = set()
    for ln in lines:
        if RESOLVED_RE.search(ln): kinds.add('resolved')
        elif any(p.search(ln) for p in DIGEST_RES): kinds.add('digest')
        elif HEARTBEAT_RE.search(ln): kinds.add('heartbeat')
        elif STARTUP_RE.search(ln): kinds.add('startup')
        else: return 'items'
    if 'resolved' in kinds: return 'resolved'
    if 'digest' in kinds: return 'digest'
    return 'heartbeat' if 'heartbeat' in kinds else 'startup'


def build(quiet=False):
    import duckdb
    t0 = time.time()
    con = duckdb.connect()
    con.execute("SET TimeZone='UTC'")
    con.execute(f"SET threads={min(os.cpu_count() or 4, 12)}")
    r = lambda t: f"read_parquet('{RAW}/{t}/*.parquet', union_by_name=true)"
    # titles
    titles = []
    for root in ROOTS:
        for p in glob.glob(os.path.join(root, '*', '*', 'custom-title.json')):
            try:
                with open(p) as f:
                    titles.append((p.split('/')[-2], json.load(f).get('customTitle')))
            except Exception:
                pass
    con.execute('CREATE TABLE titles(session_id VARCHAR, title VARCHAR)')
    if titles: con.executemany('INSERT INTO titles VALUES (?, ?)', titles)
    con.execute('CREATE TABLE titles1 AS SELECT session_id, any_value(title) title FROM titles GROUP BY 1')
    ts = lambda c: f"make_timestamp({c})::TIMESTAMPTZ"
    con.execute(f"""
    CREATE TABLE api_calls AS
    SELECT file, session_id, agent_id, is_subagent, turn_seq,
           session_id[1:8] || '/' || coalesce(agent_id, 'main') || '#' || turn_seq AS turn_id,
           pos, {ts('ts')} AS ts, msg_key, model, input, output, cache_read, cache_write_5m, cache_write_1h,
           stop_reason, error, n_copies,
           CAST(CASE WHEN model ILIKE '%fable%' THEN 2.0 WHEN model ILIKE '%sonnet%' THEN 0.6
                WHEN model ILIKE '%haiku%' THEN 0.2 ELSE 1.0 END AS DOUBLE) AS model_scale,
           model_scale * (input + 5.0 * output + 1.25 * cache_write_5m + 2.0 * cache_write_1h + 0.1 * cache_read)::DOUBLE AS weight,
           input + cache_read + cache_write_5m + cache_write_1h AS context_tokens
    FROM {r('api_calls')}
    QUALIFY row_number() OVER (PARTITION BY msg_key ORDER BY (stop_reason IS NOT NULL) DESC, output DESC, file, pos) = 1
    """)
    con.execute(f"""
    CREATE TABLE tool_calls AS
    WITH raw AS (SELECT * FROM {r('tool_calls')}),
         w AS (SELECT msg_key, file FROM api_calls)
    SELECT raw.file, raw.session_id, raw.agent_id, raw.is_subagent, raw.turn_seq,
           raw.session_id[1:8] || '/' || coalesce(raw.agent_id, 'main') || '#' || raw.turn_seq AS turn_id,
           raw.pos, {ts('raw.ts')} AS ts, raw.* EXCLUDE (file, session_id, agent_id, is_subagent, turn_seq, pos, ts)
    FROM raw LEFT JOIN w ON w.msg_key = raw.msg_key
    WHERE w.file IS NULL OR w.file = raw.file
    QUALIFY row_number() OVER (PARTITION BY raw.tool_use_id ORDER BY raw.ts, raw.file) = 1
    """)
    con.execute(f"""
    CREATE TABLE gh_calls AS
    SELECT g.file, g.session_id, g.agent_id, g.is_subagent, coalesce(g.agent_id, 'main') AS lane, g.turn_seq,
           g.session_id[1:8] || '/' || coalesce(g.agent_id, 'main') || '#' || g.turn_seq AS turn_id,
           {ts('g.ts')} AS ts, g.* EXCLUDE (file, session_id, agent_id, is_subagent, turn_seq, ts),
           g.watch_mode OR g.poll_loop AS polling,
           -- what ci-wait v1-v3 should replace: polling -> `ci-wait <ids>`; job logs -> `ci-wait log`;
           -- single run view/list -> `ci-wait status`
           CASE WHEN g.watch_mode OR g.poll_loop THEN 'ci-wait wait'
                WHEN g.sub = 'api' AND (g.endpoint LIKE '%actions/jobs/%/logs%' OR g.endpoint LIKE '%actions/runs/%/jobs%') THEN 'ci-wait log'
                WHEN g.sub = 'run' AND g.verb = 'view' AND regexp_matches(g.invocation, '--log(-failed)?\b') THEN 'ci-wait log'
                WHEN g.sub = 'run' AND g.verb IN ('view', 'list') THEN 'ci-wait status'
                WHEN g.sub = 'pr' AND g.verb = 'checks' THEN 'ci-wait status'
                END AS ci_wait_target
    FROM {r('gh_calls')} g SEMI JOIN tool_calls t ON t.tool_use_id = g.tool_use_id AND t.file = g.file
    """)
    con.execute(f"""CREATE TABLE api_errors AS SELECT file, session_id, agent_id, turn_seq, {ts('ts')} AS ts, error, text
                    FROM {r('api_errors')}""")
    # content class of watcher wakes (item D), in Python: no numpy for a DuckDB UDF under the fixed uv deps
    rows = con.execute(f"""SELECT b.file, b.turn_seq, b.trigger, b.trigger_text, b.wake_output,
                                  coalesce(l.category = 'watcher_launch', false) AS from_watcher
                           FROM {r('turns_base')} b LEFT JOIN tool_calls l ON l.tool_use_id = b.trigger_tool_use_id
                           WHERE b.trigger IN ('bg-task', 'monitor-event')""").fetchall()
    import pyarrow as pa
    cc_tbl = pa.table({'file': pa.array([x[0] for x in rows], pa.string()),
                       'turn_seq': pa.array([x[1] for x in rows], pa.int64()),
                       'content_class': pa.array([digest_class(x[2], x[3], x[4], x[5]) for x in rows], pa.string())})
    con.register('cc_arrow', cc_tbl)  # executemany of ~15k rows costs seconds; an Arrow scan costs nothing
    con.execute('CREATE TABLE content_cls AS SELECT * FROM cc_arrow')
    con.execute(f"""
    CREATE TABLE turns AS
    WITH b AS (SELECT * FROM {r('turns_base')}),
    a AS (SELECT file, turn_seq, count(*) AS n_api_calls, sum(input) AS input, sum(output) AS output, sum(cache_read) AS cache_read,
                 sum(cache_write_5m) AS cache_write_5m, sum(cache_write_1h) AS cache_write_1h, sum(weight) AS weight,
                 arg_min(cache_read, pos) AS first_call_cache_read, arg_min(context_tokens, pos) AS first_call_context,
                 max(context_tokens) AS max_context, bool_or(error = 'rate_limit') AS any_rl,
                 string_agg(DISTINCT model, ',') AS models
          FROM api_calls GROUP BY ALL),
    t AS (SELECT file, turn_seq, count(*) AS n_tool_calls,
                 count(*) FILTER (category = 'watcher_launch') AS n_watcher_launch,
                 count(*) FILTER (category = 'write') AS n_write, count(*) FILTER (category = 'outbound') AS n_outbound,
                 count(*) FILTER (category = 'read_only') AS n_read_only, count(*) FILTER (wakespy_relaunch) AS n_relaunch_wakespy,
                 sum(n_gh) AS n_gh, string_agg(tool, ',' ORDER BY pos) AS tools
          FROM tool_calls GROUP BY ALL),
    g AS (SELECT file, turn_seq, count(*) FILTER (polling) n_gh_polling FROM gh_calls GROUP BY ALL)
    SELECT b.session_id, b.file, b.is_subagent, b.agent_id, coalesce(b.agent_id, 'main') AS lane,
           ti.title, b.project, b.cwd,
           b.session_id[1:8] || '/' || coalesce(b.agent_id, 'main') || '#' || b.turn_seq AS turn_id, b.turn_seq,
           {ts('b.start_ts')} AS start_ts, {ts('b.end_ts')} AS end_ts,
           b.trigger, b.trigger_raw, b.trigger_detail, b.notif_summary, b.event_cat, b.peer_name, b.task_id,
           b.trigger_tool_use_id, b.sched_id,
           coalesce(a.n_api_calls, 0) AS n_api_calls, coalesce(t.n_tool_calls, 0) AS n_tool_calls,
           coalesce(t.n_watcher_launch, 0) AS n_watcher_launch, coalesce(t.n_write, 0) AS n_write,
           coalesce(t.n_outbound, 0) AS n_outbound, coalesce(t.n_read_only, 0) AS n_read_only,
           coalesce(t.n_gh, 0) AS n_gh, coalesce(g.n_gh_polling, 0) AS n_gh_polling,
           coalesce(a.input, 0) AS input, coalesce(a.output, 0) AS output, coalesce(a.cache_read, 0) AS cache_read,
           coalesce(a.cache_write_5m, 0) AS cache_write_5m, coalesce(a.cache_write_1h, 0) AS cache_write_1h,
           coalesce(a.cache_write_5m, 0) + coalesce(a.cache_write_1h, 0) AS cache_write,
           a.first_call_cache_read, a.first_call_context, a.max_context, coalesce(a.weight, 0) AS weight, a.models,
           t.tools, b.n_injected, b.n_compact, b.n_synthetic, b.n_rate_limit, b.busy_start, b.markers,
           b.trigger NOT IN ('human', 'lane-start') AS is_wake,
           NOT b.is_subagent AND b.trigger_raw NOT IN ('human', 'compact-resume', 'other-origin:auto-continuation', 'other')
               AND b.trigger_raw NOT LIKE '(skipped%' AS is_wake_wakespy,
           coalesce(a.n_api_calls, 0) + b.n_synthetic > 0 AS has_calls,
           coalesce(t.n_tool_calls, 0) = 0 AS zero_tool,
           coalesce(t.n_tool_calls, 0) <= 3 AS light,
           coalesce(t.n_tool_calls, 0) <= 3 AND coalesce(t.n_watcher_launch, 0) >= 1 AND coalesce(t.n_write, 0) = 0
               AND coalesce(t.n_outbound, 0) = 0 AS relaunch_only,
           coalesce(t.n_tool_calls, 0) <= 3 AND coalesce(t.n_relaunch_wakespy, 0) >= 1 AS relaunch_only_wakespy,
           cc.content_class,
           coalesce(cc.content_class IN ('digest', 'resolved'), false) AS digest_able,
           coalesce(cc.content_class = 'resolved', false) AS digest_resolved,
           b.n_rate_limit > 0 OR coalesce(a.any_rl, false) AS rate_limited,
           b.trigger_text, b.wake_output, b.wake_output_tool, b.output_file
    FROM b LEFT JOIN a USING (file, turn_seq) LEFT JOIN t USING (file, turn_seq) LEFT JOIN g USING (file, turn_seq)
    LEFT JOIN titles1 ti ON ti.session_id = b.session_id
    LEFT JOIN content_cls cc ON cc.file = b.file AND cc.turn_seq = b.turn_seq
    """)
    con.execute("""ALTER TABLE turns ADD COLUMN spurious BOOLEAN""")
    con.execute("""UPDATE turns SET spurious = is_wake AND has_calls
                   AND trigger NOT IN ('peer-sendmessage', 'subagent-handback', 'coordinator')
                   AND (zero_tool OR relaunch_only OR digest_able)""")
    # rollout log (WAKES_ROLLOUT_LOG). A row naming a `session` (e.g. a project name) is resolved to the
    # main session with that title / project suffix whose tool calls are closest to the row's ts.
    if ROLLOUT_LOG and os.path.exists(ROLLOUT_LOG):
        con.execute(f"""CREATE TABLE rollout0 AS SELECT row_number() OVER () AS line, j->>'ts' AS ts_raw,
                        try_cast(j->>'ts' AS TIMESTAMPTZ) AS ts, j->>'change' AS change, j->>'version' AS version,
                        j->>'event' AS event, j->>'session' AS session, j->>'repo_commit' AS repo_commit,
                        j->>'path' AS path, j->>'sessions_call' AS sessions_call, j->>'note' AS note,
                        CAST(j AS VARCHAR) AS raw
                        FROM read_json_objects('{ROLLOUT_LOG}', format='newline_delimited', ignore_errors=true) t(j)""")
    else:
        con.execute("""CREATE TABLE rollout0(line BIGINT, ts_raw VARCHAR, ts TIMESTAMPTZ, change VARCHAR, version VARCHAR,
                       event VARCHAR, session VARCHAR, repo_commit VARCHAR, path VARCHAR, sessions_call VARCHAR,
                       note VARCHAR, raw VARCHAR)""")
    con.execute("""CREATE TABLE rollout AS
        WITH s AS (SELECT DISTINCT session_id, title, project FROM turns WHERE NOT is_subagent),
        cand AS (SELECT r.line, t.session_id, min(abs(epoch(t.ts) - epoch(r.ts))) AS d
                 FROM rollout0 r JOIN s ON s.title = r.session OR s.project LIKE '%-' || r.session
                 JOIN tool_calls t ON t.session_id = s.session_id AND NOT t.is_subagent
                 WHERE r.session IS NOT NULL AND r.ts IS NOT NULL GROUP BY r.line, t.session_id)
        SELECT r0.*, c.session_id FROM rollout0 r0
        LEFT JOIN (SELECT line, arg_min(session_id, d) AS session_id FROM cand GROUP BY line) c USING (line)""")
    con.execute(f"""
    CREATE TABLE watcher_events AS
    SELECT t.session_id, t.file, t.is_subagent, t.agent_id, t.turn_id, t.ts, t.tool, t.tool_use_id, t.run_in_background,
           t.script_path, t.script_name, t.pilot_version, t.watch_marker, t.script_args, t.description, t.command,
           row_number() OVER (PARTITION BY t.session_id, coalesce(t.script_path, t.script_name, t.tool) ORDER BY t.ts) = 1
               AS first_of_path_in_session,
           -- the engine the launch ran: a pilot path in the command, else (a wrapper such as idle.sh)
           -- the latest rollout `cutover` row for this session at or before the launch
           coalesce(t.pilot_version,
                    CASE WHEN t.script_name IN ('idle.sh', 'idle-watch.sh') THEN
                      (SELECT arg_max(r.version, r.ts) FROM rollout r WHERE r.event = 'cutover' AND r.change LIKE 'idle-watch%'
                         AND r.session_id = t.session_id AND r.ts <= t.ts + INTERVAL 5 SECOND) END) AS engine_version,
           (SELECT count(*) FROM turns w WHERE w.trigger_tool_use_id = t.tool_use_id) AS n_wakes_caused
    FROM tool_calls t WHERE t.category = 'watcher_launch'
    """)
    con.execute("""
    CREATE TABLE lanes AS
    WITH c AS (SELECT file, row_number() OVER (PARTITION BY file ORDER BY pos) call_n, turn_seq, context_tokens
               FROM api_calls WHERE is_subagent)
    SELECT t.session_id, t.agent_id, t.file, any_value(t.title) title, min(t.start_ts) AS start_ts, max(t.end_ts) AS end_ts,
           count(*) AS n_turns, sum(t.n_api_calls) AS n_api_calls, sum(t.weight) AS weight,
           arg_min(t.first_call_cache_read, t.turn_seq) AS first_turn_cache_read,
           median(t.first_call_cache_read) AS median_turn_cache_read, max(t.first_call_cache_read) AS max_turn_cache_read,
           max(t.max_context) AS max_context,
           (SELECT min(call_n) FROM c WHERE c.file = t.file AND c.context_tokens >= 200000) call_n_200k,
           (SELECT min(turn_seq) FROM c WHERE c.file = t.file AND c.context_tokens >= 200000) turn_200k,
           (SELECT min(call_n) FROM c WHERE c.file = t.file AND c.context_tokens >= 400000) call_n_400k,
           (SELECT min(turn_seq) FROM c WHERE c.file = t.file AND c.context_tokens >= 400000) turn_400k,
           min(t.turn_seq) FILTER (t.first_call_cache_read >= 200000) AS turn_fc_200k,
           min(t.turn_seq) FILTER (t.first_call_cache_read >= 400000) AS turn_fc_400k,
           count(*) FILTER (t.is_wake) AS n_wakes, string_agg(DISTINCT t.trigger, ',') AS triggers
    FROM turns t WHERE t.is_subagent GROUP BY t.session_id, t.agent_id, t.file
    """)
    # ci-wait polls + rollout (small; full rewrite)
    if POLLS_LOG and os.path.exists(POLLS_LOG):
        con.execute(f"""CREATE TABLE polls_raw AS SELECT * FROM read_json('{POLLS_LOG}', format='newline_delimited',
                        ignore_errors=true, columns={{ts:'DOUBLE', pid:'BIGINT', url:'VARCHAR', code:'INTEGER',
                        remaining:'VARCHAR', resource:'VARCHAR'}})""")
    else:
        con.execute("CREATE TABLE polls_raw(ts DOUBLE, pid BIGINT, url VARCHAR, code INTEGER, remaining VARCHAR, resource VARCHAR)")
    attribute_polls(con)
    con.execute(r"""CREATE TABLE ci_wait_calls AS
        WITH c AS (SELECT session_id, file, agent_id, is_subagent, turn_id, ts, tool_use_id, run_in_background, command,
                          -- an invocation is /ci-wait followed by a subcommand, a run id, a flag or a $var;
                          -- `git add cli/ci-wait`, `py_compile cli/ci-wait` are mentions, not calls
                          list_transform(regexp_extract_all(command, '/ci-wait[ \t]+(status|log|stats|[0-9]|--[a-z-]+|[$"])', 1),
                                         x -> CASE WHEN x IN ('status', 'log', 'stats') THEN x ELSE 'wait' END) AS subs
                   FROM tool_calls WHERE tool IN ('Bash', 'Monitor') AND command LIKE '%/ci-wait%')
        SELECT *, CASE WHEN len(subs) = 0 THEN 'mention' WHEN list_contains(subs, 'wait') THEN 'wait'
                       WHEN list_contains(subs, 'log') THEN 'log' WHEN list_contains(subs, 'status') THEN 'status'
                       ELSE subs[1] END AS subcommand,
               len(list_filter(subs, x -> x = 'wait')) AS n_wait, len(list_filter(subs, x -> x = 'status')) AS n_status,
               len(list_filter(subs, x -> x = 'log')) AS n_log, len(list_filter(subs, x -> x = 'stats')) AS n_stats
        FROM c""")
    # peer_names: the name other sessions see for a session = from-name on a peer wake whose body starts with
    # a SendMessage this session sent within 2 min before it
    con.execute(r"""CREATE TABLE peer_names AS
        WITH s AS (SELECT session_id, ts, left(regexp_replace(message, '\s+', ' ', 'g'), 60) AS m
                   FROM tool_calls WHERE tool = 'SendMessage' AND NOT is_subagent AND length(message) >= 20),
             w AS (SELECT session_id AS receiver, start_ts, peer_name,
                          left(regexp_replace(trigger_text, '\s+', ' ', 'g'), 60) AS m
                   FROM turns WHERE trigger = 'peer-sendmessage' AND peer_name IS NOT NULL)
        SELECT s.session_id, w.peer_name, count(*) AS n_matches, min(w.start_ts) AS first_seen, max(w.start_ts) AS last_seen
        FROM s JOIN w ON w.m = s.m AND w.start_ts BETWEEN s.ts AND s.ts + INTERVAL 2 MINUTE AND w.receiver <> s.session_id
        GROUP BY s.session_id, w.peer_name
        -- a name seen for several senders belongs to the one it was matched for most often
        QUALIFY row_number() OVER (PARTITION BY w.peer_name ORDER BY count(*) DESC) = 1""")
    con.execute("""CREATE TABLE session_markers AS
        SELECT DISTINCT session_id, unnest(string_split(markers, ',')) AS marker FROM turns WHERE markers IS NOT NULL""")
    counts = {}
    for tname in ('api_calls', 'tool_calls', 'gh_calls', 'turns', 'watcher_events', 'lanes', 'api_errors',
                  'ci_wait_polls', 'rollout', 'ci_wait_calls', 'peer_names', 'session_markers'):
        tmp = os.path.join(OUT, f'{tname}.parquet.tmp')
        con.execute(f"COPY {tname} TO '{tmp}' (FORMAT parquet, COMPRESSION zstd)")
        os.replace(tmp, os.path.join(OUT, f'{tname}.parquet'))
        counts[tname] = con.execute(f'SELECT count(*) FROM {tname}').fetchone()[0]
    con.close()
    ensure_db()
    return counts, time.time() - t0


def attribute_polls(con):
    """Attach each ci-wait pid to the transcript Bash call that started it (shared run id / PR / sha,
    call shortly before the pid's first request), so requests matching WAKES_EXCLUDE can be flagged."""
    con.execute("""CREATE TABLE polls AS SELECT to_timestamp(ts) AS ts, pid, url,
                   regexp_extract(url, 'repos/([^/]+/[^/]+)', 1) AS repo, code, try_cast(remaining AS INTEGER) AS remaining,
                   resource FROM polls_raw""")
    pids = con.execute("""SELECT pid, epoch(min(ts)) AS t0, list(DISTINCT url) AS urls FROM polls GROUP BY pid""").fetchall()
    calls = con.execute("""SELECT t.session_id, t.agent_id, epoch(t.ts), t.command, coalesce(b.cwd, '') AS cwd
                           FROM tool_calls t LEFT JOIN (SELECT DISTINCT file, turn_seq, cwd FROM read_parquet('""" + RAW +
                        """/turns_base/*.parquet')) b ON b.file = t.file AND b.turn_seq = t.turn_seq
                           WHERE t.command LIKE '%/ci-wait%'""").fetchall()
    cinfo = []
    for sid, aid, cts, cmd, cwd in calls:
        ids = set(re.findall(r'\b\d{8,}\b', cmd))
        prs = set(re.findall(r'--pr[\s=]+(\d+)', cmd))
        shas = set(re.findall(r'--sha[\s=]+([0-9a-f]{7,40})', cmd))
        brs = set(re.findall(r'--branch[\s=]+([\w./-]+)', cmd))
        cinfo.append((sid, aid, cts, ids, prs, shas, cwd, brs))
    rows = []
    for pid, t0, urls in pids:
        uids = set(); uprs = set(); ushas = set(); ubr = set()
        for u in urls:
            uids |= set(re.findall(r'/runs/(\d+)', u)) | set(re.findall(r'/jobs/(\d+)', u))
            ubr |= set(re.findall(r'[?&]branch=([^&]+)', u))
            uprs |= set(re.findall(r'/pulls/(\d+)', u))
            ushas |= set(re.findall(r'head_sha=([0-9a-f]{40})', u))
        best = None
        for sid, aid, cts, ids, prs, shas, cwd, brs in cinfo:
            dt = t0 - cts
            if dt < -5 or dt > 4 * 3600: continue
            hit = bool(ids & uids) or any(h.startswith(s) for s in shas for h in ushas) or \
                (bool(prs & uprs) and dt < 300) or (bool(brs & ubr) and dt < 120)
            if hit and (best is None or cts > best[2]):
                best = (sid, aid, cts, cwd)
        if best:
            rows.append((pid, best[0], best[1], best[2], best[3]))
        else:
            rows.append((pid, None, None, None, None))
    # pass 2: a pid sharing a run id / head sha with an attributed pid within 10 min belongs to the same caller
    # (a sha computed at run time, `sha=$(gh run view ...)`, never appears in the command text)
    info = {}
    for pid, t0, urls in pids:
        ids = set()
        for u in urls:
            ids |= set(re.findall(r'/runs/(\d+)', u)) | set(re.findall(r'/jobs/(\d+)', u)) | \
                set(re.findall(r'head_sha=([0-9a-f]{40})', u))
        info[pid] = (t0, ids, {re.sub(r'.*repos/[^/]+/([^/]+).*', r'\1', u) for u in urls})
    rows = [list(x) + ['ids' if x[1] else None] for x in rows]
    for _ in range(3):
        for r_ in rows:
            if r_[1]: continue
            t0, ids, _repos = info[r_[0]]
            for o in rows:
                if o[1] and o[5] in ('ids', 'shared-ids') and abs(info[o[0]][0] - t0) < 600 and ids & info[o[0]][1]:
                    r_[1:6] = [o[1], o[2], o[3], o[4], 'shared-ids']; break
    # pass 3: a repo nobody's command named (a helper script ran ci-wait): the latest session that called
    # ci-wait before the pid started, from a cwd in that repo
    for r_ in rows:
        if r_[1]: continue
        t0, ids, repos = info[r_[0]]
        best = None
        for sid, aid, cts, _i, _p, _s, cwd, _b in cinfo:
            if cts <= t0 + 5 and any(rp and ('/' + rp) in (cwd or '') for rp in repos):
                if best is None or cts > best[2]: best = (sid, aid, cts, cwd)
        if best: r_[1:6] = [best[0], best[1], best[2], best[3], 'repo']
    con.execute('CREATE TABLE pid_attr0(pid BIGINT, session_id VARCHAR, agent_id VARCHAR, call_ts DOUBLE, cwd VARCHAR, attributed_by VARCHAR)')
    if rows: con.executemany('INSERT INTO pid_attr0 VALUES (?, ?, ?, ?, ?, ?)', rows)
    con.execute('CREATE TABLE pid_attr AS SELECT * EXCLUDE (call_ts), to_timestamp(call_ts) AS call_ts FROM pid_attr0')
    cwds, wins = [], []
    for rule in filter(None, (r.strip() for r in EXCLUDE.split(';'))):
        kind, _, val = rule.partition(':')
        if kind == 'cwd':
            cwds.append("a.cwd LIKE '%s'" % val.replace("'", "''"))
        elif kind == 'window':
            lo, _, hi = val.partition('/')
            wins.append("p.ts BETWEEN TIMESTAMPTZ '%s' AND TIMESTAMPTZ '%s'" % (lo.replace("'", ''), hi.replace("'", '')))
    excl_cwd = 'coalesce(%s, false)' % ' OR '.join(cwds) if cwds else 'false'
    excl_win = 'coalesce(%s, false)' % ' OR '.join(wins) if wins else 'false'
    con.execute(f"""CREATE TABLE ci_wait_polls AS
        SELECT p.*, CASE WHEN p.url LIKE '%/actions/jobs/%' THEN 'job-log' ELSE 'poll' END AS kind,
               p.code = 304 AS is_free, a.session_id, a.agent_id, a.call_ts AS started_by_call_ts, a.cwd, a.attributed_by,
               {excl_cwd} AS is_excluded,
               {excl_win} AS in_excluded_window
        FROM polls p LEFT JOIN pid_attr a USING (pid)""")


VIEWS = ['api_calls', 'tool_calls', 'gh_calls', 'turns', 'watcher_events', 'lanes', 'api_errors', 'ci_wait_polls',
         'rollout', 'ci_wait_calls', 'peer_names', 'session_markers']


def ensure_db():
    """(Re)create wakes.duckdb views only when DB_VERSION changes, so a normal run never opens the db
    (a reader holding it open would otherwise block us)."""
    import duckdb
    dbp = os.path.join(OUT, 'wakes.duckdb')
    vfile = os.path.join(OUT, '.db_version')
    try:
        with open(vfile) as f:
            if f.read().strip() == str(DB_VERSION) and os.path.exists(dbp): return
    except Exception:
        pass
    con = duckdb.connect(dbp)
    con.execute("SET TimeZone='UTC'")
    for v in VIEWS:
        con.execute(f"CREATE OR REPLACE VIEW {v} AS SELECT * FROM read_parquet('{OUT}/{v}.parquet')")
    con.execute("""CREATE TABLE IF NOT EXISTS cutovers(session_id VARCHAR, cutover_ts TIMESTAMPTZ, change VARCHAR,
                   source VARCHAR, note VARCHAR)""")
    # cutovers_for(change, pattern): explicit rollout `cutover` rows (session resolved) first; every other
    # session's cutover = its first Bash/Monitor call whose command matches the regex `pattern`, not before the
    # change's first `deployed` rollout row (when there is one).
    con.execute("""
    CREATE OR REPLACE MACRO cutovers_for(change_name, pattern) AS TABLE
    WITH ex AS (SELECT session_id, min(ts) AS cutover_ts, any_value(version) AS version FROM rollout
                WHERE change = change_name AND event = 'cutover' AND session_id IS NOT NULL GROUP BY session_id),
         lo AS (SELECT coalesce(min(ts) FILTER (event = 'deployed'), TIMESTAMPTZ '1970-01-01 00:00:00+00') AS lo,
                       count(*) FILTER (event = 'deployed') > 0 AS has_dep FROM rollout WHERE change = change_name),
         fu AS (SELECT t.session_id, min(t.ts) AS cutover_ts FROM tool_calls t, lo
                WHERE t.tool IN ('Bash', 'Monitor') AND regexp_matches(coalesce(t.command, ''), pattern) AND t.ts >= lo.lo
                GROUP BY t.session_id)
    SELECT session_id, cutover_ts, change_name AS change, 'rollout:cutover' AS source, 'version ' || version AS note FROM ex
    UNION ALL
    SELECT session_id, cutover_ts, change_name AS change,
           CASE WHEN (SELECT has_dep FROM lo) THEN 'rollout:deployed+first-use' ELSE 'marker:first-use' END AS source,
           'pattern ' || pattern AS note
    FROM fu WHERE session_id NOT IN (SELECT session_id FROM ex)
    """)
    # first watcher launch whose script path/command matches a regex (tier-engine cutover, item C)
    con.execute("""
    CREATE OR REPLACE MACRO watcher_cutovers(pattern, change_name) AS TABLE
    SELECT session_id, min(ts) AS cutover_ts, change_name AS change, 'first-watcher-launch' AS source,
           'pattern ' || pattern AS note
    FROM watcher_events WHERE regexp_matches(coalesce(script_path, '') || ' ' || command, pattern)
    GROUP BY session_id
    """)
    con.close()
    with open(vfile, 'w') as f:
        f.write(str(DB_VERSION))

# --------------------------------------------------------------------------- main


def main():
    args = sys.argv[1:]
    full = '--full' in args
    quiet = '--quiet' in args
    workers = int(args[args.index('--workers') + 1]) if '--workers' in args else min(12, os.cpu_count() or 4)
    t0 = time.time()
    os.makedirs(RAW, exist_ok=True); os.makedirs(STATE, exist_ok=True)
    files = discover()
    states = {b: ({} if full else load_state(b)) for b in range(NB)}
    if full:
        for t in COLS:
            for p in glob.glob(os.path.join(RAW, t, '*.parquet')): os.remove(p)
    work = {}
    n_unchanged = 0; n_new = 0; n_app = 0; n_rew = 0
    for rp, meta in files.items():
        try:
            s = os.stat(rp)
        except FileNotFoundError:
            continue
        b = bucket_of(rp)
        old = states[b].get(rp)
        fstat = (s.st_size, s.st_mtime_ns, s.st_ino)
        if old and old.get('size') == s.st_size and old.get('mtime') == s.st_mtime_ns and old.get('ino') == s.st_ino:
            n_unchanged += 1
            continue
        if old and old.get('ino') == s.st_ino and s.st_size >= old.get('offset', 0) and s.st_size >= old.get('size', 0):
            task = (rp, meta, 'append', old['resume_offset'], old['resume_seq'], old.get('resume_ctx') or {}, fstat)
            n_app += 1
        else:
            task = (rp, meta, 'full', 0, 0, {}, fstat)
            if old: n_rew += 1
            else: n_new += 1
        work.setdefault(b, []).append(task)
    t_disc = time.time() - t0
    stats = {t: 0 for t in COLS}; nbytes = 0
    if work:
        order = sorted(work.items(), key=lambda kv: -sum(x[6][0] - x[3] for x in kv[1]))
        if len(order) == 1 or workers == 1:
            results = [process_bucket(b, tasks) for b, tasks in order]
        else:
            with ProcessPoolExecutor(max_workers=workers) as ex:
                futs = [ex.submit(process_bucket, b, tasks) for b, tasks in order]
                results = [f.result() for f in futs]
        for b, n, nb, cnt, dt in results:
            nbytes += nb
            for k, v in cnt.items(): stats[k] += v
    t_parse = time.time() - t0 - t_disc
    counts, t_build = build(quiet)
    print(f"files: {len(files)} total, {n_unchanged} unchanged, {n_new} new, {n_app} appended, {n_rew} rewritten; "
          f"parsed {nbytes / 1e6:.1f} MB")
    print(f"timing: discover {t_disc:.1f}s, parse {t_parse:.1f}s, build {t_build:.1f}s, total {time.time() - t0:.1f}s")
    print('raw rows written this run: ' + ', '.join(f'{k}={v}' for k, v in stats.items()))
    print('final tables: ' + ', '.join(f'{k}={v}' for k, v in counts.items()))


if __name__ == '__main__':
    main()
