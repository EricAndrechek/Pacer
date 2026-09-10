---
name: pacer
description: Report Claude Code usage from Pacer — every rate-limit window, including per-model caps like Fable and each account on the machine — and pace heavy work against them, so hitting a limit during a long autonomous run or a large fan-out of subagents costs a resumable pause rather than the whole run. Use before and during long autonomous work or when fanning out many subagents/workflow agents, and whenever the user asks how much usage is left, how far through a window they are, when limits reset, or "will I hit my limit". Reads Pacer's local HTTP API on this machine; that API is opt-in and may be off, in which case gating is skipped and work proceeds.
---

# Pacer — pace agents and workflows against Claude's rate limits

Reports how far through **every** rate-limit window you are — the account-wide
5-hour and 7-day blocks *and* any per-model cap the server reports, such as a
Fable weekly window — and gives an orchestrator a **checkpoint → sleep →
resume** protocol so a limit hit during a big parallel run costs a pause, not
the run.

All commands are `~/.claude/skills/pacer/pace.sh <cmd>`.

Needs `curl` and `awk`, both of which macOS already has. There is nothing to
install: this skill ships inside Pacer.app and updates when Pacer does.

## 1. Just report where I'm at

```
$ ~/.claude/skills/pacer/pace.sh report
5h           62% used · resets in 1h 43m  (Thu 2:19 PM)
7d           32% used · resets in 5d 12h  (Wed 12:59 AM)
Fable        47% used · resets in 5d 12h  (Wed 12:59 AM)
```

One row per window Pacer is tracking for the **active login**. `json` gives the
machine form. That is the whole reporting story — percent through each window
and when each resets. **No forecasts.**

Two accounts on the machine? `--account all` shows both, prefixed by account
id; `--account <id>` picks one. Ids come from `pace json` or Pacer's
`/v1/accounts`.

## 2. The gating model (why it scales to hundreds of agents)

Pacer only recomputes every **~5 min**, and you must not have 200 subagents
each curling it. So it is **one poller, many cheap readers**:

- **One poller** — the orchestrator runs `pace.sh gate --cap N` once per
  fan-out *wave*. That is the single HTTP read; it writes a shared **state
  file**.
- **Many cheap readers** — every subagent runs `pace.sh status`, a plain
  **file read** (no HTTP), and obeys it.

Exit codes:

| | 0 | 10 | 3 | 20 | 2 | 4 | 1 |
|---|---|---|---|---|---|---|---|
| `gate` | GO | PAUSE | — | — | API off | misconfigured | bad `--window` |
| `status` | GO | PAUSE | unknown / stale | — | — | — | — |
| `wait` | resume | — | — | far-off reset → checkpoint & stop | API off | misconfigured | bad `--window` |

Three of those are "no signal" rather than "no budget", and they are not the
same as each other:

- **2, API off** — Pacer's server is opt-in and is not running. Proceed
  ungated; this is the ordinary case on a machine without Pacer.
- **4, misconfigured** — Pacer answered and rejected the request, almost always
  a token set in Pacer but not in `PACE_TOKEN`. Proceed if you must, but **tell
  the user**: the run is unpaced and one line of configuration would fix it.
- **3, unknown or stale** — no gate has run, or the last verdict is older than
  `--max-age` (default 15 min). A verdict has a shelf life: an orchestrator
  that died an hour ago left its last word on disk, and obeying it is obeying a
  window that has since moved. Re-gate.

A bad `--window` (1) *does* stop you, because a selector that matches nothing
would otherwise report GO forever.

**Two runs at once need two state files.** The shared default is what makes
`status` free; two orchestrations sharing it means last-writer-wins on a
verdict the other is about to obey. Set `PACE_RUN=<name>` (or `--state`) per
orchestration.

## 3. Orchestrator protocol

Invoke with a cap (default **85**). For a big fan-out:

1. **Pre-flight:** `pace.sh report` so you and the user see the starting
   headroom.
2. **Before each wave:** `pace.sh gate --cap 85`.
   - exit 0 → spawn the wave; give every subagent the clause in §4.
   - exit 10 → do **not** spawn; go to step 4.
3. Keep waves small enough to finish in a few minutes, so a mid-wave trip is
   caught at the next gate.
4. **On PAUSE — checkpoint (crash-safe, never touches the default branch):**
   - If the work is in worktrees, the default branch stays clean. In each
     active worktree: `git add -A && git commit -m "pace-checkpoint"` (or
     `git stash push -u`).
   - Write or refresh the **resume manifest** (§5): done / in-flight / pending.
   - Tell the user which window tripped, at what %, and its reset time.
5. **Sleep until reset without burning turns** — launch the waiter in the
   background (`run_in_background: true`):

   ```
   ~/.claude/skills/pacer/pace.sh wait --cap 85
   ```

   It blocks *across turns* until the window resets, then **exits — which
   re-invokes you**. On wake: read the manifest, re-dispatch the in-flight and
   pending items (in-flight ones resume from their checkpoint commits), and
   merge the finished worktrees as usual.
   - If `wait` exits **20**, the blocker resets further out than `--max-wait`
     (a weekly cap, usually). Do not sleep: leave the manifest, tell the user
     the reset time, and stop. They resume by re-running you after reset.

## 4. The clause to paste into EVERY subagent prompt

> **Usage gating:** before you start, and before any expensive step, run
> `~/.claude/skills/pacer/pace.sh status`. If it prints `paused` (exit 10):
> immediately commit your work-in-progress in this worktree
> (`git add -A && git commit -m "pace-checkpoint"`), append one line to
> `<MANIFEST_PATH>` saying exactly where you stopped and what is left, and
> return `RESUME-NEEDED: <that line>`. Do not begin new expensive work. If it
> prints `go`, proceed. If it prints `unknown` or `stale`, proceed but say so
> in your final message — nobody is pacing this. It is a local file read — call
> it freely.

**In a Workflow script** (the deterministic `Workflow` tool): gate *between
stages* instead — before each `parallel()`/`pipeline()` wave, run an `agent()`
that calls `pace.sh gate` and returns its verdict; if paused, stop enqueuing,
return the partial results plus the manifest, and **end the workflow cleanly**
so it can be resumed with `resumeFromRunId` after the reset. Do not hold a
workflow open for hours.

## 5. Resume manifest

A plain file you own — `.pace/resume.json` in the repo (gitignored) or
`~/.claude/pace/resume-<run>.json`. Minimum shape:

```json
{
  "run": "big-refactor",
  "cap": 85,
  "pausedAt": "2026-07-03T01:10:00Z",
  "resetsAt":  "2026-07-03T05:20:00Z",
  "queue": {
    "done":     ["fileA", "fileB"],
    "inflight": [{ "item": "fileC", "worktree": "wt/fileC", "branch": "fileC" }],
    "pending":  ["fileD", "fileE"]
  }
}
```

It is on disk, so a crash *during* the pause is recoverable: on restart, re-read
it and continue. Keep it current as items complete.

## 6. Parameters and policy

- `--cap N` (default 85): pause when **any** watched window is at or over N%.
- `--window SEL` (default all): case-insensitive substring of a window's label
  or identity — `5h`, `7d`, `fable`. Use it to ignore a window you do not care
  about; a selector matching nothing is an error, not a free pass.
- `--account ID|all` (default: the active login): whose windows to read.
- `--interval S` (default 300, floored to 300): poll cadence while waiting.
  Pacer updates about every 5 minutes; polling faster is wasted.
- `--max-wait S` (default 21600 = 6h): auto-sleep only if the reset is within
  this. A further-out reset returns exit 20 so you checkpoint and stop instead
  of sleeping for days.
- `--max-age S` (default 900 = 15 min): how old a state file may be before
  `status` calls it stale. It is also how long `wait` holds a pause through an
  unreadable API before giving up.
- **Short windows vs long ones:** a 5-hour window is the one you actually wait
  out. A weekly cap — account-wide or per-model — is usually stop-and-notify.
- Env: `PACER_API` (default `http://127.0.0.1:7223`), `PACE_TOKEN` (if Pacer
  requires a bearer), `PACE_ACCOUNT`, `PACE_RUN` (names a per-run state file),
  `PACE_STATE` (default `~/.claude/pace/state.json`).

## 7. External supervisor (no agent involved)

`pace-guard.sh [claude args…]` blocks until there is headroom, then execs
`claude`. `PACE_THRESHOLD` (default 85) sets the cap. Good for wrapping an
unattended run from your own terminal.

## Caveats

- **Pacer's API is opt-in.** If `report` says the API is unreachable, turn it on
  in Pacer → Settings → Integrations → "Local API & metrics server". Everything
  here degrades to "proceed ungated" while it is off.
- A single Claude session **cannot `sleep` out a multi-hour reset** (the Bash
  tool caps out around 10 minutes) — that is why the wait runs as a
  *background* process whose **exit** wakes you.
- The background waiter dies if the machine sleeps (lid close). On wake, re-run
  the orchestrator — the manifest makes that safe.
- **Pacer restarting does not end a pause.** It installs its own silent updates,
  so any wait long enough to matter will meet a minute where nothing answers.
  `wait` holds the pause through that rather than reading it as headroom.
- **"API off" ≠ "no budget left."** Off means no signal; proceed ungated.
- Window labels come from the window's identity, so a per-model cap reads as
  the model name ("Fable"). If the server ever reports an opaque model id, the
  label is that id — `pace.sh json` always shows the full identity.
