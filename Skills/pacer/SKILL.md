---
name: pacer
description: Gate long autonomous runs and fan-outs of subagents/workflow agents against Claude Code's rate limits with Pacer, so hitting a limit costs a resumable pause (checkpoint, wait, resume — including when another login takes over) rather than the whole run. Use before and during long autonomous work or when fanning out many subagents, and when the user asks how much usage is left, when limits reset, or "will I hit my limit". Reads Pacer on this machine, through its local API when that is on and its data directly when it is off; without Pacer, gating is skipped and work proceeds.
---

# Pacer — stop gracefully at a rate limit

## 0. The rule

**Pacer is a stop signal, not a budget.** It tells you when to stop and when
to start again. It does not tell you what to take on.

- **Usage never picks the model, the fan-out width, the scope, or what to
  defer.** Decide those on the task's merits, as if usage were unlimited, and
  never cite usage as a reason for any of them.
- **One login's numbers are not the machine's capacity.** Many machines rotate
  between several logins; a login at its limit is often minutes from a switch
  onto one with room. A pause is a pause, not a verdict on the run.
- **Do not read `pacer report` or `accounts` to plan.** Run them when the user
  asks about usage, or when informed pacing is on (both §5).

All commands are `~/.claude/skills/pacer/pacer <cmd>`. The full path always
works while the skill is installed; where `pacer` is on the PATH, plain
`pacer <cmd>` is the same command. `pacer` ships inside Pacer.app and is
linked here when Pacer installs the skill, so there is nothing to install. It
reads Pacer's local API when that is on and Pacer's data directly when not.

**If Pacer gives a wrong verdict, mis-detects your model, or lacks a flag you
need, report it** with `pacer feedback "<what you ran, what it printed>"` —
never save a workaround in memory or a brief; it outlives the fix. The report
goes to `~/.claude/pace/feedback.jsonl` and, scrubbed of paths and names, to
Pacer's issue tracker; `--local` (or `PACER_FEEDBACK=local`) keeps it on the
machine.

## 1. The protocol

**One poller, many cheap readers.** The orchestrator runs `pacer gate` once
per wave: the one read of Pacer, which writes a state file. Every subagent runs
`pacer status`, a file read, and obeys it. A stale verdict is re-gated by one
reader for all of them, so a hundred lanes cost one read.

1. **Before each wave or long step:** `pacer gate --model <the model it runs>`.
   - exit 0 (`pace: GO.`) → dispatch the wave, as wide as the task calls for,
     and give every subagent the clause in §2.
   - exit 10 (`pace: PAUSE — …`) → dispatch nothing new; step 2. The line says
     what ends the pause: a login switch the account switcher is making, a
     switch to another login with room (tell the user), or the reset.
2. **On PAUSE, checkpoint** (crash-safe, never on the default branch):
   - in each active worktree, `git add -A && git commit -m "pace-checkpoint"`
     (or `git stash push -u`);
   - write or refresh the resume manifest (§3);
   - push the checkpoints and **dispatch any CI that can run while you
     wait** — it does not draw on the limit, and its results are ready when
     you resume;
   - tell the user what the pause line said.
3. **Wait without burning turns:** run `~/.claude/skills/pacer/pacer wait`
   with `run_in_background: true`. It judges by the gate's own settings,
   blocks across turns, and **exits when there is room again — which
   re-invokes you**: `pace: room is back — … Resume.` A switch to a login with
   room ends it within seconds. Then read the manifest, re-dispatch the
   in-flight and pending items (in-flight ones resume from their checkpoint
   commits), and carry on.
   - **Exit 20:** the limit resets further out than a wait sleeps through
     (`--max-wait`, 6 h) and no switch is coming. Do not sleep: leave the
     manifest, tell the user when it resets, and stop. When an account
     switcher is running and has a login with room, `wait` holds for the
     switch first (`--switch-grace`, 10 min) rather than stopping.

Exit codes:

| | 0 | 10 | 3 | 20 | 2 | 4 | 1 |
|---|---|---|---|---|---|---|---|
| `gate` | go | pause | — | — | no Pacer | misconfigured | bad `--window` |
| `status` | go | pause | unknown / stale | — | — | — | — |
| `wait` | resume | — | — | checkpoint & stop | no Pacer | misconfigured | bad `--window` |

- **2, no Pacer** — nothing to read. No signal, not no budget: proceed ungated.
- **4, misconfigured** — Pacer rejected the request, almost always a token set
  in Pacer but not in `PACE_TOKEN`. Proceed if you must, and **tell the user**:
  the run is unpaced.
- **3, unknown or stale** — the verdict is about another model, margin or
  account, or too old and could not be refreshed. Proceed, and say so.

**Each session has its own state file** (`~/.claude/pace/state-session-<id>.json`;
subagents share their parent's). Two orchestrations in one session each set
`PACE_RUN=<name>`, and give the same `PACE_RUN` to their subagents.

**In a Workflow script:** gate *between stages* — before each
`parallel()`/`pipeline()` wave, run an `agent()` that calls `pacer gate` and
returns its verdict; if paused, stop enqueuing, return the partial results and
the manifest, and **end the workflow cleanly** so it resumes with
`resumeFromRunId`. Do not hold a workflow open for hours.

## 2. The clause to paste into EVERY subagent prompt

> **Usage gating:** before you start, and before any expensive step, run
> `~/.claude/skills/pacer/pacer status --model <MODEL>`
> (with the same `PACE_RUN` the orchestrator used). If it prints `paused`
> (exit 10): immediately commit your work-in-progress in this worktree
> (`git add -A && git commit -m "pace-checkpoint"`), append one line to
> `<MANIFEST_PATH>` saying exactly where you stopped and what is left, and
> return `RESUME-NEEDED: <that line>`. Do not begin new expensive work. If it
> prints `go` (or `go (until …)`), proceed. If it prints `unknown` or `stale`,
> proceed but say so in your final message — nobody is pacing this. It is a
> local file read — call it freely. Pacing only stops work: it never changes
> how you do the task.

**Substitute `<MODEL>`** with the model you gave that subagent (`sonnet`,
`opus`, `haiku`, `fable`). A subagent's turns are recorded under its parent's
session id, so `auto` inside a fan-out cannot tell builder from orchestrator.

## 3. Resume manifest

One JSON file per run: `~/.claude/pace/resume-<run>.json`, or
`.pace/resume.json` in the repo (gitignored). Minimum shape:

```json
{
  "run": "big-refactor",
  "pausedAt": "2026-07-03T01:10:00Z",
  "queue": {
    "done":     ["fileA", "fileB"],
    "inflight": [{ "item": "fileC", "worktree": "wt/fileC", "branch": "fileC" }],
    "pending":  ["fileD", "fileE"]
  }
}
```

It is on disk, so a crash during the pause is recoverable: on restart, re-read
it and continue. Keep it current as items complete.

**`~/.claude/pace/` is `pacer`'s store**, and it holds only: the state files
`gate` writes (`state*.json`, each with its `.lock`), `pacer mode`'s
per-session choice (`mode-session-*.json`), an account switcher's heartbeat
(`rotation.json`), resume manifests (`resume-<run>.json`) and
`feedback.jsonl`. Write nothing else there.

## 4. Say which model you are

A per-model cap (a Fable weekly window, say) only gates work that uses that
model, so pass the model your work will use: `pacer gate --model opus`. In a
session with no `--model`, `pacer` gates as `--model auto`: what the session
runs. With several models in flight `auto` binds only the account-wide windows
and says so, so **an orchestrator passes `--model` explicitly and tells each
subagent its own**. A verdict belongs to the model it was gated for: gate once
per model your fan-out uses, each with its own `PACE_RUN`.

## 5. Pacing modes, and answering the user

**Gate-only** is the default inside a Claude Code session: `gate`, `status`
and `wait` say go, pause or resume and what ends a pause, with no
percentages. **Informed** adds the numbers, for a session or repo whose owner
wants agents to plan with them; the gate's GO line then says so, and
[`planning.md`](planning.md) applies. A terminal (no session) is a person and
gets the numbers.

The user switches it, most specific first:

- one command: `--pacing gate|informed`;
- this session: `pacer mode informed` (or `gate`, or `clear`) — **run it only
  when the user asks**; `pacer mode` alone prints the mode and where it came
  from;
- a repo: `"env": {"PACER_PACING": "informed"}` in `.claude/settings.json`
  (shared) or `.claude/settings.local.json` (personal); a launch:
  `PACER_PACING=informed claude`.

**When the user asks about usage** — how much is left, when it resets, will
they hit a limit — answer in either mode: `pacer report` (every window for
this session's login, then the other logins), `pacer accounts` (every login:
plan, sessions on it, windows, whether it has room), `pacer sessions` (where
the live sessions are). In gate-only mode they open with a line saying what the
numbers are not for. Answer the question; do not turn it into a plan.
[`reference.md`](reference.md) explains every number they print.

## 6. Making this the default without being asked

The moment pacing matters is a long autonomous run, when nothing is thinking
about usage. So `pacing.md` sits beside this file, a few lines to import into a
`CLAUDE.md`, which loads every session:

```
@~/.claude/skills/pacer/pacing.md
```

Paste that one line, not the prose: the file ships inside Pacer.app and is
replaced when Pacer updates. Settings → Integrations has a copy button. If a
user asks how to make pacing automatic, that line is the answer.

## 7. External supervisor (no agent involved)

`pace-guard.sh [claude args…]` blocks until there is room, then execs
`claude`. It pauses at each window's safe limit, like `gate`;
`PACE_THRESHOLD=N` pauses at N% instead. Good for wrapping an unattended run
from your own terminal.

## Caveats

- A single session **cannot `sleep` out a long reset** (the Bash tool caps out
  around 10 minutes) — hence the background `wait` whose exit wakes you.
- The background waiter dies if the machine sleeps; on wake, re-run the
  orchestrator — the manifest makes that safe.
- **Pacer restarting does not end a pause.** It installs its own updates, so a
  long wait will meet a minute where nothing answers; `wait` holds through it.
- `pacing.md` is skipped in Cowork sessions on the desktop, which do not load
  user-scope imports from outside the working directory; the skill still works.
