# Pacer reference — what every number means

The detail behind SKILL.md: what `report`, `accounts` and `sessions` print,
how the gate decides, and every flag. **None of it is for planning** unless
informed pacing is on ([planning.md](planning.md)); it is for answering the
user's questions about usage, and for debugging a verdict.

## `report`: every window, and the other logins

```
$ ~/.claude/skills/pacer/pacer report
5h         15.6% est · read 15% 1m ago · +33%/h now (+0 avg) · resets in 4h 48m  (Thu 6:39 PM)
7d           81% used · +7%/h now (+2 avg) · resets in 3d 16h  (Mon 5:59 AM)
Fable        99% used · +8%/h now (+2 avg) · full in 6h 24m · resets in 3d 16h
```

**A whole number is Anthropic's reading; a decimal is Pacer's estimate.**
Readings are whole points. Between them Pacer estimates the meter from the
spend since the last one (the live meter), and writes that with one decimal
and `est`, followed by the reading it started from and its age. A window
nothing has been spent on since its reading shows the reading, `used`.

**Two rates, and the difference is the point.** `now` is measured straight from the readings: over the last half hour, or, when the whole-point readings rose under 2 points in it (a weekly window at a few %/h usually does), between their last ticks, up to a tenth of the window back (16.8 hours on a weekly one), and never more than one point over the time since the last tick. `avg` is the engine's fitted slope over
a much longer lookback — 90 minutes on a session window, 24 hours on a weekly
one. It only appears when the two disagree by more than five points, and when
it does you are in a burst: the 5-hour row above is climbing at 33%/h while its
smoothed average still reads zero.

One row per window Pacer tracks for **your** login, with how fast it is
climbing and — when a window is projected to fill before it resets — when.
`json` gives the machine form, including each window's full identity.

**Whose windows?** The account this session is signed into — resolved from
`CLAUDE_CODE_SESSION_ID`, independent of `--model`. On a machine with more than
one login, a gate that cannot identify the session says so in its output rather
than quietly reporting the active login's numbers, because "GO at 0%" off an
idle account is the most expensive thing this tool can say. A session pinned to
its own profile (`CLAUDE_CONFIG_DIR`, which is how two accounts run at once)
gets that account's windows: the script hands Pacer the directory and Pacer
resolves it, because only Pacer knows which login is signed into it. Otherwise
the active login. `--account all` shows every account, prefixed by id;
`--account <id>` picks one, and the 8-character id `accounts` prints is
enough. A `wait` looks the session's account up again on every poll, so a switch onto a login with headroom ends it. A `/login` run in another session does not move sessions already running: they keep their token. After a login change no switcher explains, such a session is judged on every login it may still be billing (the most constrained decides) and the verdict says so. Switching away and back with your account switcher moves every session and ends that.

`pacer report` prints this session's login's windows, then, when other logins exist, one line: `other logins: 1 with room (7d 4%), 1 near its limit, 2 spent until Sat`. "Spent" means an account-wide window is at or over its safe limit (the gate's rule). "With room" means room to resume onto: every account-wide window at least `--resume-headroom` points below its limit (by default 20 minutes at the higher of that login's burn and this one's, at least 5) — the bar `wait` applies to a switch and the one a rotation controller applies. "Near its limit" is under the limit by less than that. A window is account-wide, not machine-wide: one login's percentage is not the machine's capacity. The line is omitted with one login and under `--account all`. `pacer json` carries the same in `otherAccounts` (`withRoom`, `nearLimit`, `spent`, `spentUntilSeconds`, and per login its `state`: `room`, `near` or `spent`). Pacers before this one counted every login under its safe limit in `withRoom`, near ones included.

When an account switcher is running (see "Rotation" below), `report` adds `rotation: on — at this login's limit the account switcher moves sessions to a login with room`, or that it is holding, and a `full in` on an account-wide window reads `(rotation moves on)`: it is this login filling, not the machine. `report` may also print `note: N login changes today had no switch behind them — check the switcher's log`: the switcher's log is not being read, so sessions may be judged on the old login.

## `accounts` and `sessions`: every login, and who is on it

**A rate-limit window is account-wide.** Every session signed into an account
draws on the same percentage, so a burn rate already includes all of them.
`accounts` lists each login with its plan, how many sessions are drawing on it,
its windows, and (with more than one login) `room`, `near its limit` or
`spent until …`, plus `rotation target` where a running switcher would pick it.

```
$ pacer accounts
2 accounts

  a1b2c3d4   max · active login
    0 sessions drawing on it now
    5h 0%  7d 39%  Fable 57%
    room

  e5f6a7b8   max
    4 sessions drawing on it now
    5h 55%  7d 89%  Fable 100%
    room · rotation target
```

```
$ pacer sessions
active  e5f6a7b8  acme-api (main)         claude-opus-5     /Users/…/acme-api
active  e5f6a7b8  globex-web (feat/login) claude-opus-5     /Users/…/globex-web  ← git@github.com:…
recent  e5f6a7b8  core (main)             claude-fable-5-1  /Users/…/acme/core
```

- **The plan** reads `Max 20×` when Anthropic reports a tier and falls back to
  the coarse family (`Max`) when it does not; Pacer never guesses a multiplier.
- **Concurrency is already in the rate, not additive to it.** Four sessions
  producing 20%/h between them is 20%/h, not 80%.
- **Branches are read when you ask, never stored.** A branch changes without
  producing a turn for Pacer to observe, so a recorded one would be wrong more
  often than right. `sessions` runs `git rev-parse` against each live path at
  the moment you run it.

## The gating model (why it scales to hundreds of agents)

Pacer only recomputes every **~5 min**, and you must not have 200 subagents
each curling it. So it is **one poller, many cheap readers**:

- **One poller** — the orchestrator runs `pacer gate` once per
  fan-out *wave*. That is the single read of Pacer; it writes a shared
  **state file**.
- **Many cheap readers** — every subagent runs `pacer status`, a **file
  read**, and obeys it. When the verdict has gone stale (older than
  `--max-age`, a pause whose window has reset, or one gated before the login switched to another account) or there is none yet,
  `status` re-gates it by the verdict's own settings (an `--account` it was gated for included) — one reader takes a lock
  and reads Pacer, the rest wait up to ~3 s for its answer — so a lane that
  runs for an hour never goes blind, and a hundred lanes still cost one read
  per staleness period. `--no-refresh` keeps the pure file read.
- **A GO lasts only while there is room.** `gate` records when the soonest
  binding window reaches its limit at its recent burn (within `--max-age`),
  and `status` prints `go (until 22:41Z)` and re-gates after that: near a
  limit, every few minutes instead of every 15.

Exit codes:

| | 0 | 10 | 3 | 20 | 2 | 4 | 1 |
|---|---|---|---|---|---|---|---|
| `gate` | GO | PAUSE | — | — | no Pacer | misconfigured | bad `--window` |
| `status` | GO | PAUSE | unknown / stale | — | — | — | — |
| `wait` | resume | — | — | far-off reset → checkpoint & stop | no Pacer | misconfigured | bad `--window` |

Three of those are "no signal" rather than "no budget", and they are not the
same as each other:

- **2, no Pacer** — there is nothing to read: Pacer is not installed, or its
  command line could not be found or could not open Pacer's data. Not the
  local API being off: with it off, `pacer` reads Pacer's data directly.
  Proceed ungated; this is the ordinary case on a machine without Pacer.
- **4, misconfigured** — Pacer answered and rejected the request, almost always
  a token set in Pacer but not in `PACE_TOKEN`. Proceed if you must, but **tell
  the user**: the run is unpaced and one line of configuration would fix it.
- **3, unknown or stale** — the verdict is about another model, margin or `--account`,
  Pacer could not be read to refresh it, or (with `--no-refresh`) no gate has
  run, the last verdict is older than `--max-age` (default 15 min), it was a
  pause whose window has reset since, a GO past its projected expiry, or one gated before the login moved to another account. A verdict has a shelf life: an
  orchestrator that died an hour ago left its last word on disk, and obeying
  it is obeying a window that has since moved.

A bad `--window` (1) *does* stop you, because a selector that matches nothing
would otherwise report GO forever.

**Each session has its own state file.** In a Claude Code session the default
is `~/.claude/pace/state-session-<first 8 of CLAUDE_CODE_SESSION_ID>.json`;
subagents run under their parent's session id, so a session's lanes share one
verdict and no other session obeys it. Outside a session (a terminal) it is
`state.json`. Two orchestrations in one session still need two files — set
`PACE_RUN=<name>` (or `--state`) per orchestration.

## Say which model you are

**A per-model cap only gates work that uses that model.** A Fable weekly window
at 95% has nothing to say to an Opus agent, and pausing one for it is a pause
nobody needed. So pass the model your work will actually use:

```
$ pacer gate --model all              # every window binds
pace: PAUSE — Fable at 99% >= safe limit 98%, resets in 3d 17h.

$ pacer gate --model opus             # Fable is not this agent's problem
pace: GO — 5h 40%, 7d 32% (safe limit 5h 96%, 7d 99%).

$ pacer gate                          # in a session: what this session runs
pace: GO — 5h 40%, 7d 32% (safe limit 5h 96%, 7d 99%). (model auto: detected claude-opus-5)
```

**With no `--model`, a session gates as `--model auto`.** Claude Code exports
`CLAUDE_CODE_SESSION_ID` into every command it runs, and that id names the
transcript Pacer already parses — so Pacer can answer what model the session is
running, and which account its work is billed to. The verdict says
`(model auto: …)` so you can see what it was judged by. Outside a session
(no id) every window binds, as does `--model all`.

**Inside a fan-out, `auto` cannot tell you apart — so name your model.** A
subagent does *not* get its own session id; its turns are written under the
parent's, and nothing in the environment names a per-agent model. So when a
session has more than one model in flight, `auto` will not guess: it binds only
the account-wide windows and says so.

```
$ pacer gate --model auto              # Fable orchestrator, Sonnet builders
pace: GO — 5h 12%, 7d 32% (safe limit 5h 97%, 7d 99%). (model auto: ambiguous (claude-fable-5-1,
claude-sonnet-5) — account-wide windows only; pass --model to gate on yours)
```

That is deliberate, and it is the lesser of two wrong answers. Guessing used to
mean a Sonnet builder gated on its orchestrator's Fable cap — a window at 95%
that does not bind it and does not reset for three days, stalling the whole
fan-out. Binding only what certainly applies never does that. The cost is the
other direction: an orchestrator running `auto` mid-fan-out is no longer
stopped by its own per-model cap.

**So an orchestrator should pass `--model` explicitly and tell each subagent
its own** — it chose the model, so it is the one thing in the system that knows.
`auto` is the fallback for a session running one model, where it is exact.

It falls back to "every window binds" when Pacer has not yet seen a turn from
the session at all, which is the safe reading of "cannot tell".

Account-wide windows (5h, 7d) bind everything, always — those are never
skipped. Only per-model caps are filtered: by the model you name, or in a
session by `auto`. A caller with no session id and no `--model` might be using
anything, so every window binds it.

**A verdict belongs to the model it was gated for.** The state file records it,
and `status --model opus` refuses a verdict gated for something else (exit 3,
re-gate) rather than letting an Opus wave inherit a Fable pause. So gate once
per model your fan-out uses, and give each group its own run name:

```
PACE_RUN=opus-wave  pacer gate --model opus
PACE_RUN=fable-wave pacer gate --model fable
```

## Parameters and policy

- `--cap N` (default: the **safe limit**): pause when any watched window is at
  or over N%. The default stops just before the limit, nothing earlier.
  When Pacer has a **live value** for a window (the last reading plus what
  the spend since it adds), the gate judges that, and the safe limit is 100%
  minus the live value's own error at the window's burn: 1 point under 20%/h,
  2 up to 60%/h, 3 above. Otherwise (no fit yet, or a reading over 15 minutes
  old) it judges the reading: 100% minus the window's recent burn × (the
  reading's age + one worst-case 5-minute poll). Always at least 1 point.
  Heavy use stops near 97% with a live value and near 90% without; light use
  near 99%. The gate judges the estimate's whole points (`15.6% est` is 15).
  `report` shows the estimate with the reading beside it, `json` gives
  `usedPercent` (the reading), `livePercent` (one decimal when
  `liveIsEstimate`), `liveWholePercent` (what the gate judged) and the
  `safeLimit` it was judged against, and `pacer safecap` prints the limit
  `gate` would apply to each binding window, one per line, for scripts.
  **Pass `--cap` only when the user, or the task, decides to keep part of a
  window in reserve.** How much to spend is their call, not a default's.
- `--margin N` (default 0; `PACE_MARGIN`): stop N points below each window's
  safe limit, so the reserve tracks the burn instead of being a fixed number.
  With `--cap`, each window takes the lower of the two. `status` refuses a
  verdict gated with a different margin.
- `--model NAME|auto|all` (default: `auto` in a Claude Code session, else
  `all`): only gate on windows that constrain this model. `auto` asks Pacer
  what this session is running. Account-wide windows always bind; per-model
  caps bind only when the name matches theirs, compared loosely so `opus`,
  `claude-opus-5` and `Opus 5` all mean the same window.
- `--eta DURATION` (default off): also pause when a binding window is projected
  to fill within that horizon — `90m`, `2h`, or plain seconds. It pauses with
  room left (planning.md); an option, not a default.
- `--window SEL` (default all): case-insensitive substring of a window's label
  or identity — `5h`, `7d`, `fable`. Use it to ignore a window you do not care
  about; a selector matching nothing is an error, not a free pass. `--window`
  is about what you *watch*; `--model` is about what *binds you*.
- `--account ID|all` (default: the active login): whose windows to read.
- `--interval S` (default 15, floor 5): how often `wait` looks. Readings
  change about every 5 minutes, but a login switch shows up within seconds,
  and each look is a request to this machine.
- `--max-wait S` (default 21600 = 6h): auto-sleep only if the reset is within
  this. A further-out reset returns exit 20 so you checkpoint and stop instead
  of sleeping for days.
- `--max-age S` (default 900 = 15 min): how old a state file may be before
  `status` re-gates it (or, with `--no-refresh`, calls it stale). A GO's own
  projected expiry (`goUntil` in the state file) can only shorten it. It is
  also how long `wait` holds a pause through an unreadable API before giving up.
- `--resume-headroom N|auto` (default auto; `PACE_RESUME_HEADROOM`): the points
  `wait` needs below the paused window's limit on a newly switched-to login
  before it resumes onto it. `auto` is 20 minutes at the higher of the old
  and new login's recent burn (the sessions move with the work), at least 5;
  `0` resumes on any room.
- `--pacing gate|informed` (`PACER_PACING`; `pacer mode` for a session): what
  agent-facing output says. Gate-only (the default in a Claude Code session)
  prints go / pause / resume and what ends a pause, no percentages; informed
  (the default in a terminal) prints the numbers. Precedence: the flag, then
  `PACER_PACING` (the user's setting, so an agent's `pacer mode` cannot
  override a repo's choice), then `pacer mode`, then the default. An unusable
  `PACER_PACING` or mode file is skipped with a warning on stderr, never an
  exit 1; only a bad `--pacing` is an error.
- `--switch-grace S` (default 600): how long `wait` holds a pause whose window
  resets beyond `--max-wait` while a running account switcher has a target with
  room, before it gives up and exits 20.
- **Short windows vs long ones:** a 5-hour window is the one you actually wait
  out. A weekly cap on one login is a switch away when another login has room
  (see "Rotation" below); with no other login, it is stop-and-notify. An Ultra account
  has no 5-hour window at all: its report and gate show the weekly and
  per-model windows only.
- Env: `PACER_API` (default `http://127.0.0.1:7223`), `PACE_TOKEN` (if Pacer
  requires a bearer), `PACE_MODEL`, `PACE_MARGIN`, `PACE_RESUME_HEADROOM`, `PACE_ACCOUNT`, `PACE_RUN`
  (names a per-run state file), `PACE_STATE` (default this session's
  `~/.claude/pace/state-session-<id>.json`, or `state.json` outside a session).
  `CLAUDE_CONFIG_DIR` is read if the session has one, to pick the right
  account. `PACER_PACING` (gate|informed), `PACE_ROTATION` (the switcher's
  heartbeat; default `~/.claude/pace/rotation.json`).

## Rotation: when another login ends a pause

A PAUSE on a machine with several logins says what ends it, and stores it in
the state file as `switch`:

- **expected** — an account switcher is running and has a login with room to
  move to. `wait` resumes on the switch, and holds for it (`--switch-grace`)
  even when the paused window resets days away.
- **possible** — no switcher is running, but another login has room. Switching
  to it ends the pause; tell the user, who decides.
- **none** — no other login has room: wait for the reset, or stop if it is
  beyond `--max-wait`.

Pacer cannot see a switcher on its own. A controller tells it by writing a
heartbeat every loop to `~/.claude/pace/rotation.json` (`PACE_ROTATION`
overrides the path):

```json
{"v": 1, "updatedAt": "2026-11-17T15:06:33Z", "active": "a1b2c3d4",
 "holding": false, "targets": ["e5f6a7b8"]}
```

`targets` are the accounts it would switch to now, by its own bar (an id, or
its first 8 characters); `holding` means it has nowhere to go. A heartbeat
older than three minutes is a stopped controller and is ignored. While one is
fresh, its word wins over Pacer's own reading of the other logins: it knows its
exclusions and caps.

## The shape of a window over time

`GET /v1/limits/history?hours=24&bucket=15m` gives every window's utilization
as a series, so a consumer can see whether the last hour was a steady climb or
one enormous step, and fit its own slope. Each point carries a `cycle` index
that increments on a rollover — segment on that, never on `resetsAt`, which
drifts by milliseconds between polls. Fitting a line across a reset produces a
number that means nothing.

## How fresh a percentage can be

Pacer polls Anthropic no faster than once
  per five minutes *per token*, which is what keeps it off the ~30-minute
  throttle. An account with several tokens is read proportionally more often;
  an account with one is read every 5 minutes while you are active and every
  10 when you are not. So a half-hour `now` rate rests on six readings in the
  first case and two in the second, and drops to `null` rather than guessing
  when it has fewer than two, or when the newest reading is over half an hour old. Readings are whole points: a window that rose under 2 points in the half hour is measured from its last ticks instead, so a weekly window climbing 1–4%/h does not read 0 between ticks. Nothing can make the *percentage* finer than the
  poll — it is the server's number — but `/v1/limits/history?bucket=5m` gives
  you every reading Pacer has, to fit whatever you like.
