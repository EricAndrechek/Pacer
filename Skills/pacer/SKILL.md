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
5h           15% used · +33%/h now (+0 avg) · resets in 4h 48m  (Thu 6:39 PM)
7d           81% used · +7%/h now (+2 avg) · resets in 3d 16h  (Mon 5:59 AM)
Fable        99% used · +8%/h now (+2 avg) · full in 6h 24m · resets in 3d 16h
```

**Two rates, and the difference is the point.** `now` is measured over the last
half hour, straight from the readings. `avg` is the engine's fitted slope over
a much longer lookback — 90 minutes on a session window, 24 hours on a weekly
one. It only appears when the two disagree by more than five points, and when
it does you are in a burst: the 5-hour row above is climbing at 33%/h while its
smoothed average still reads zero.

One row per window Pacer tracks for **your** login, with how fast it is
climbing and — when a window is projected to fill before it resets — when.
`json` gives the machine form, including each window's full identity.

**Whose windows?** The account this session is signed into. A session pinned to
its own profile (`CLAUDE_CONFIG_DIR`, which is how two accounts run at once)
gets that account's windows: the script hands Pacer the directory and Pacer
resolves it, because only Pacer knows which login is signed into it. Otherwise
the active login. `--account all` shows every account, prefixed by id;
`--account <id>` picks one.

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

## 3. Say which model you are

**A per-model cap only gates work that uses that model.** A Fable weekly window
at 95% has nothing to say to an Opus agent, and pausing one for it is a pause
nobody needed. So pass the model your work will actually use:

```
$ pace.sh gate --cap 85                 # every window binds — the safe reading
pace: PAUSE — Fable at 95% >= cap 85%, resets in 3d 17h.

$ pace.sh gate --cap 85 --model opus    # Fable is not this agent's problem
pace: GO — 5h 40%, 7d 32% (cap 85%).

$ pace.sh gate --cap 85 --model auto    # ask Pacer what this session runs
pace: GO — 5h 40%, 7d 32% (cap 85%).
```

**`--model auto` means you never have to say.** Claude Code exports
`CLAUDE_CODE_SESSION_ID` into every command it runs, and that id names the
transcript Pacer already parses — so Pacer can answer what model this session
is running, and which account its work is billed to. A subagent gets its own
session id, so it resolves to the *subagent's* model, not its parent's. Export
`PACE_MODEL=auto` once and every call in that session is model-aware.

It falls back to "every window binds" when Pacer has not yet seen a turn from
the session — a brand-new subagent, most often — which is the safe reading of
"cannot tell".

Account-wide windows (5h, 7d) bind everything, always — those are never
skipped. Only per-model caps are filtered, and only when you name a model. With
no `--model` every window binds, because a caller that did not say is a caller
that might be using anything.

**A verdict belongs to the model it was gated for.** The state file records it,
and `status --model opus` refuses a verdict gated for something else (exit 3,
re-gate) rather than letting an Opus wave inherit a Fable pause. So gate once
per model your fan-out uses, and give each group its own run name:

```
PACE_RUN=opus-wave  pace.sh gate --cap 85 --model opus
PACE_RUN=fable-wave pace.sh gate --cap 85 --model fable
```

## 4. Gate on the forecast, not just the level

`--cap` asks "am I nearly out". `--eta` asks the better question — **"will this
wave finish before I run out"**:

```
$ pace.sh gate --cap 85 --eta 90m
pace: PAUSE — 5h at 40% is projected to fill in 45m (horizon 1h 30m).
```

40% is nowhere near any cap, but it is climbing at 24%/h and the wave you are
about to launch takes an hour. Pacer already forecasts every window with a
calibrated band; this is the one line that uses it. Set the horizon to roughly
how long your wave runs.

## 5. Orchestrator protocol

Invoke with a cap (default **85**). For a big fan-out:

1. **Pre-flight:** `pace.sh report` so you and the user see the starting
   headroom.
2. **Before each wave:** `pace.sh gate --cap 85 --model <yours> --eta <wave length>`.
   - exit 0 → spawn the wave; give every subagent the clause in §6.
   - exit 10 → do **not** spawn; go to step 4.
3. Keep waves small enough to finish in a few minutes, so a mid-wave trip is
   caught at the next gate.
4. **On PAUSE — checkpoint (crash-safe, never touches the default branch):**
   - If the work is in worktrees, the default branch stays clean. In each
     active worktree: `git add -A && git commit -m "pace-checkpoint"` (or
     `git stash push -u`).
   - Write or refresh the **resume manifest** (§7): done / in-flight / pending.
   - Tell the user which window tripped, at what %, and its reset time.
5. **Sleep until reset without burning turns** — launch the waiter in the
   background (`run_in_background: true`):

   ```
   ~/.claude/skills/pacer/pace.sh wait --cap 85
   ```

   It blocks *across turns* until there is headroom again, then **exits —
   which re-invokes you**. Two things can end the wait, and it says which:

   ```
   pace: reset — headroom restored (5h 4%, 7d 61%). Resume.
   pace: account switched (427af130 → 74598a77) — headroom on the new login. Resume.
   ```

   The second is the common one under sequential accounts: switching logins
   restores headroom immediately, and a waiter that called that "reset" would
   be telling you something false about where your budget went. A waiting
   process polls every 60 s rather than every 5 minutes for exactly this
   reason — a reset cannot arrive faster than Pacer's readings, but a switch
   can. On wake: read the manifest, re-dispatch the in-flight and
   pending items (in-flight ones resume from their checkpoint commits), and
   merge the finished worktrees as usual.
   - If `wait` exits **20**, the blocker resets further out than `--max-wait`
     (a weekly cap, usually). Do not sleep: leave the manifest, tell the user
     the reset time, and stop. They resume by re-running you after reset.

## 6. The clause to paste into EVERY subagent prompt

> **Usage gating:** before you start, and before any expensive step, run
> `~/.claude/skills/pacer/pace.sh status --model auto`
> (with the same `PACE_RUN` the orchestrator used). If it prints `paused` (exit 10):
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

## 7. Resume manifest

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

## 8. Parameters and policy

- `--cap N` (default 85): pause when **any** watched window is at or over N%.
- `--model NAME|auto` (default: every window binds): only gate on windows that
  constrain this model. `auto` asks Pacer what this session is running. Account-wide windows always bind; per-model caps bind
  only when the name matches theirs, compared loosely so `opus`,
  `claude-opus-5` and `Opus 5` all mean the same window.
- `--eta DURATION` (default off): also pause when a binding window is projected
  to fill within that horizon — `90m`, `2h`, or plain seconds.
- `--window SEL` (default all): case-insensitive substring of a window's label
  or identity — `5h`, `7d`, `fable`. Use it to ignore a window you do not care
  about; a selector matching nothing is an error, not a free pass. `--window`
  is about what you *watch*; `--model` is about what *binds you*.
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
  requires a bearer), `PACE_MODEL`, `PACE_ACCOUNT`, `PACE_RUN` (names a per-run
  state file), `PACE_STATE` (default `~/.claude/pace/state.json`).
  `CLAUDE_CONFIG_DIR` is read if the session has one, to pick the right
  account.

## 9. External supervisor (no agent involved)

`pace-guard.sh [claude args…]` blocks until there is headroom, then execs
`claude`. `PACE_THRESHOLD` (default 85) sets the cap. Good for wrapping an
unattended run from your own terminal.

## 10. The shape of a window over time

`GET /v1/limits/history?hours=24&bucket=15m` gives every window's utilization
as a series, so a consumer can see whether the last hour was a steady climb or
one enormous step, and fit its own slope. Each point carries a `cycle` index
that increments on a rollover — segment on that, never on `resetsAt`, which
drifts by milliseconds between polls. Fitting a line across a reset produces a
number that means nothing.

## Caveats

- **How fresh a percentage can be.** Pacer polls Anthropic no faster than once
  per five minutes *per token*, which is what keeps it off the ~30-minute
  throttle. An account with several tokens is read proportionally more often;
  an account with one is read every 5 minutes while you are active and every
  10 when you are not. So a half-hour `now` rate rests on six readings in the
  first case and two in the second, and drops to `null` rather than guessing
  when it has fewer than two. Nothing can make the *percentage* finer than the
  poll — it is the server's number — but `/v1/limits/history?bucket=5m` gives
  you every reading Pacer has, to fit whatever you like.

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
