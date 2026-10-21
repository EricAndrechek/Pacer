---
name: account-rotation
description: Keep every Claude Code session on a Mac running by rotating the default login between cswap accounts, switching before a 5-hour limit onto an account with real room, and supervising the sessions a limit stops. Use when asked to manage/rotate/pace accounts, to resume the rotation after a restart, or when a session reports it is out of usage.
---

# Account rotation

Read `$ROTATE_HOME/LOCAL.md` for this machine's owner rules before acting; they
override defaults here.

A detached bash controller does the switching. No model is needed for that: it
reads usage every minute, decides, and runs `cswap switch`. Your job is to keep
it running, watch what it does, and handle the people and sessions around it.

## Requirements

- macOS with more than one Claude login managed by
  [claude-swap](https://github.com/realiti4/claude-swap) (`cswap`, a version
  with `cswap list --json`). Without it there is nothing to rotate.
- Pacer, for burn rates and fresher readings through its local API
  (`http://127.0.0.1:7223/metrics`). Without it the controller still runs on
  cswap's readings and assumes `BURN_UNKNOWN`.
- bash 4+ at `/opt/homebrew/bin/bash` (associative arrays), `jq`, `python3`.
- `analysis/` only: `uv` (it runs with `uv run --with duckdb --with pyarrow`)
  and the `duckdb` CLI for the queries.

## Install

Run the controller and watcher from a copy outside git, so a branch switch or a
pruned worktree never pulls a script out from under a running process:

```sh
mkdir -p ~/.local/state/pacer-account-rotation/bin
cp rotate.sh watch.sh stuck.py burn.py ~/.local/state/pacer-account-rotation/bin/
cp -n rotate.conf.example ~/.local/state/pacer-account-rotation/rotate.conf
```

Re-copy after changing the tracked scripts, then `stop` and `start`.

## Commands

```sh
D=.claude/skills/account-rotation          # from the repo root
$D/rotate.sh status      # running? last status/switch lines, active account
$D/rotate.sh start "why" # detached; survives the starting session and a Claude Code restart
$D/rotate.sh stop
$D/rotate.sh log 30      # last 30 lines of state/rotate.log
$D/rotate.sh dry         # one decision pass on live readings, printed; never switches
$D/watch.sh 55           # run in the background: EXITS on something to act on (the wake)
python3 -I $D/burn.py 60 # who is spending the 5h window: per-session weight, ctx, turns/h
python3 -I $D/stuck.py 6 # main sessions whose last turn was a usage-limit stop
$D/tests.sh <script>     # decision tests against a fake cswap, e.g. tests.sh $D/rotate.sh
```

**Runtime home.** Config and state live outside the repo, in
`ROTATE_HOME` (default `~/.local/state/pacer-account-rotation`): `rotate.conf`,
`LOCAL.md` and `state/` (log, pid file, stdout, last switch). A branch switch,
`git clean` or a removed worktree never touches a running controller.
`ROTATE_STATE` and `ROTATE_CONF` override the state directory and the conf
file individually (tests.sh uses both). `start` refuses to run a second copy.
After a reboot nothing is running until someone runs `start` again.

**Thresholds are in `rotate.conf`** (start from `rotate.conf.example`),
re-read every loop: an edit applies within a minute, no restart. Per-slot 7d
ceilings (`WEEK_MAX_<slot>`), never-target slots (`EXCLUDE`) and the reserve
live there. Never edit `rotate.sh` or `watch.sh` in place while they run (bash
reads scripts as it goes): write `<file>.new`, `chmod +x`, `mv` it over (the
running process keeps the old inode), or `stop`, edit, `dry`, `start`.

## Accounts

Whatever `cswap list --json` reports, keyed by slot; the account id is the
first 8 hex of the org uuid. A new cswap login is picked up with no edit.

## What it decides (every 60 s, at most one switch per 5 min)

**The target bar.** A target needs 5h room (points below its own switch point,
safe limit minus `EARLY`) of at least `max(BRIDGE_MIN_PTS, BRIDGE_MIN_MINUTES of
the active account's recent burn)`. Every session follows the login, so the
active account's burn is the demand a target must carry. During a hold the
sessions are paused and the measured burn falls, so the burn from the start of
the hold is kept as the floor until the hold ends, or the bar would sink and
the controller would bridge onto a sliver again. With no burn from Pacer,
`BURN_UNKNOWN` %/h is assumed.

| rule | when | to |
|---|---|---|
| limit | active 5h at its switch point and some target meets the bar | the best-ranked target. There is no "GAP below the active" test: any target with the bar's room beats pausing every session, a nearly full one bridges, and this rule or stagger brings the login back later |
| 7-day | active 7d >= its WEEK_MAX | the best-ranked target |
| expiring | another account's running 5h window resets within `EXPIRE_WINDOW`, before the active's own, and has room for the bar (at least `EXPIRE_MIN_PTS`), **and the room is spendable**: burn x minutes to its reset / 60 >= `EXPIRE_MIN_PTS` | that account: use it or lose it. Blocked while the active's own room is about to expire first |
| stagger | active window has <= `STAGGER` left and another account is idle (5h at 0%) | that idle account, soonest 7d reset first |
| reserve | **off** unless `RESERVE_SLOT` is set: active at its limit and nothing else qualifies | the reserve, up to `RESERVE_WEEK_MAX`; past that, one `ERROR` line and the owner decides |
| hold | near/at a limit (within 3 points of the switch point) and **nothing qualifies** | stays; one `HOLD` line per episode, a quiet `holding:` every 30 min, `hold over` when it ends |

**Ranking is expiring-first.** Among qualifying targets, the room that is lost
soonest is spent first: a running window ranks by its reset time, an idle
account (whose room does not expire; using it starts a fresh 5 h window) ranks
as now + 5 h. Ties go to the sooner 7d reset, then to the most 5h room.

**No target the stagger rule would leave at once.** If the limit or 7-day rule's
pick has a running window with more than `EXPIRE_WINDOW` but at most `STAGGER`
left while an idle account qualifies, the idle account is taken instead: one
switch, not two (two cache rewrites in every busy session). Inside
`EXPIRE_WINDOW` the pick stays, because stagger yields to its expiring room.

**Ping-pong guard.** Never go back to the slot just left within
`MIN_SWITCH_GAP`, unless its 5h window has reset since or its use has fallen.
The last switch is kept on disk, so a stop/start does not forget it.

A target also needs: not in `EXCLUDE`, `usageStatus` ok, both readings present
(a missing figure is never read as 0%), and 7d at least `WEEK_ROOM_MIN` (3)
points below its ceiling: one point of weekly room is a few minutes of work,
then a second switch off it.

Readings: `cswap list --json` (fresh, every account, a quarter of a second);
Pacer's `/metrics` may only *raise* a figure, and only for the same window. A
reset instant in the past counts as 0% for that window (5h and 7d). If cswap
fails, the last figures and cached reset times are used.

A switch made outside the controller (by hand) is logged as `EXTERNAL` and
adopted, never fought.

## Supervising it

Run `watch.sh` with `run_in_background`; its exit is the wake. Relaunch it
after handling each wake.

**Keep the heartbeat under an hour (`watch.sh 55`).** A main session's prompt
cache lasts 1 hour; a supervisor that wakes after longer idle rewrites its
whole context, many times what a warm wake costs. Longer heartbeats look
thrifty and cost more.

**While the controller holds, `watch.sh` switches itself to room-only wakes**
(SWITCH / hold over / ERROR / a dead controller), whatever mode was asked, and
suppresses the heartbeat. A wake during a hold fails on the limit, and with
the watcher gone nothing would wake the supervisor when room returns. You can
still start it as `watch.sh 150 room` by hand.

| wake | meaning | do |
|---|---|---|
| `SWITCH → N [reason]` | it switched | run `stuck.py`, nudge (below) |
| `hold over` | room is back (a reset or a switch) | same: run `stuck.py`, nudge |
| `HOLD N at X% … nowhere with room` | the active account is at its limit, nothing qualifies | sessions should already be gating (below); a resume time is fine, a "wind down" is not |
| `EXTERNAL: active A → B` | someone else switched | nothing; the controller adopted it |
| `stuck:` lines | a main session stopped on a usage limit | if there is room now, nudge it; else wait for `hold over` |
| `ERROR …` | a switch failed, or the reserve hit its cap | `cswap status`; retry by hand only onto real room; reserve cap -> the owner |
| `WARN …` | readings failed (for the active account: only after 300 s of no reading; shorter gaps right after a switch are normal and just hold) | `cswap list` by hand, then `rotate.sh status` |
| `controller NOT running` | it died | `rotate.sh start "restart after …"`, read `state/rotate.out` |
| `feedback:` lines | an agent ran `pacer feedback` (a Pacer bug or missing flag) | reproduce, fix in a Pacer branch, reply to the reporter if it's a live session |
| `heartbeat` | nothing happened for the heartbeat | `burn.py 60`; message any new heavy waste pattern; relaunch |

### After a limit: nudge, do not wait

**Background Claude Code sessions do not auto-continue after a usage limit.**
They wait for input, and only a cross-session message restarts them. So after
every `hold over` or `SWITCH`:

1. Run `python3 -I stuck.py 6` (finds main sessions whose last assistant line
   is `"error":"rate_limit"`, "You've hit your session limit · resets …").
2. Send each stopped main session a one-line message ("room is back on the
   login, resume").
3. Resume your own subagents (`SendMessage` to each stopped one).

`claude agents --json` state `blocked` means a session is waiting on the
owner's input, not stopped by a limit. Don't nudge it.

## Other sessions

- Find them with `ListAgents`. Reply to a peer with `SendMessage` to the exact
  `from=` address of its message. **Reply locally even when the report is also
  on GitHub**, so the sender doesn't have to poll GitHub to hear back.
- If a peer reports a Pacer bug, it goes to the main Pacer session; a rotation
  subagent only relays it.
- **Every message wakes its receiver, which re-reads its whole context.** Don't
  broadcast to idle sessions; message the ones a finding is about. Keep
  messages short and factual.
- **A coming-limit notice says KEEP WORKING, and the gate decides when to
  stop.** A notice like "reach a handoff point before 22:15Z" halts every
  session at once with much of the 5h window unused. Send instead: before each
  heavy step or dispatch
  `PACE_RUN=<name> ~/.claude/skills/pacer/pacer gate --model <model>` with the
  DEFAULT safe limit and no `--cap` (a cap replaces the dynamic limit rather
  than tightening it); on exit 10, `pacer wait --model <model>` in the
  background. It exits by itself when room is back, a login switch included, so
  the session resumes unattended.
- **Encourage dispatching CI before a pause.** CI runs on the host's runners
  while sessions wait, so dispatch everything needed next before the gate trips
  and note the run ids. Never advise holding CI back for a quota reason.
- **Gate before launching subagents, and give every subagent brief a gate plus
  a checkpoint.** A subagent that trips a limit mid-task should leave a resume
  note, not a half-finished edit.

## Running it from a lighter model

The main session can delegate the watching. Suggested prompt for a background
`Agent` on **sonnet**, the right model for a precise spec like this:

> Use the account-rotation skill (`.claude/skills/account-rotation/SKILL.md`)
> and read `$ROTATE_HOME/LOCAL.md`. Ensure the controller is running
> (`rotate.sh status`; `start` if not). Run `watch.sh` in the background and
> handle each wake per the skill's table, relaunching it after. Never change
> thresholds, never switch onto an account without real room, and obey the
> local rules about 7-day budgets. Keep going until told to stop; report only
> switches, errors, restarts and resumed sessions.

A subagent can't receive peers' messages: those arrive at the parent session.
The main session handles them.

## Don'ts

- Don't run `pacer gate`/`wait` experiments without a private
  `PACE_STATE=…` on that one command. The default state file is the pause
  signal every session on the Mac obeys.
- Don't kill other people's processes to relieve memory pressure. Note it for
  the owner instead.
- Don't publish account ids or emails. The cswap list output carries emails;
  mask them (`sed -E 's/[^ ]+@[^ ]+/<email>/g'`).
