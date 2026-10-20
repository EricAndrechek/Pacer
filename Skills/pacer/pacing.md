<!-- Imported into a CLAUDE.md with:  @~/.claude/skills/pacer/pacing.md
     This file ships inside Pacer.app and is replaced when Pacer updates, so
     anything written here stays current without anyone re-pasting it. Keep it
     short: an import loads into context at the start of every session.
     Local edits are preserved — Pacer will not overwrite a file you changed —
     but they will not receive updates either. -->

## Claude Code usage pacing

Pacer runs on this machine and tracks live rate-limit state; `pacer` reads
it whether or not Pacer's local API is on. Exit 2 means there is no Pacer to
read — **no signal, not no budget: proceed ungated.**

- **Where you stand:** `~/.claude/skills/pacer/pacer report` — every window,
  including per-model caps, for the account this session is signed into.
- **Before a long autonomous run or a many-agent fan-out, pace it.** Use the
  **`pacer`** skill and follow its protocol: gate once per wave, cheap `status`
  file-reads in every subagent, checkpoint to a resume manifest on a trip, and
  a backgrounded waiter whose exit wakes you. A rate limit should cost a
  resumable pause, not the run.
- **A window is account-wide.** `pacer accounts` shows how many accounts
  there are, each one's plan, and how many sessions are already drawing on it;
  `pacer sessions` shows where they are. Concurrency is already inside a burn
  rate rather than added to it, but every live session is another claim on the
  same percentage.
- **In a session, `pacer` already judges by your model** (`--model auto` is the
  default when `CLAUDE_CODE_SESSION_ID` is set), so a per-model cap only gates
  work that uses that model. **In a fan-out, name the model**: a subagent's
  turns are recorded under its parent's session id, so `auto` cannot tell a
  builder from its orchestrator, and with several models in flight binds only
  the account-wide windows. Pass `--model <yours>` to gate on your own cap.
- **Work until the gate pauses.** Its default stops just before the limit;
  `--eta` pauses earlier and is an option, not a default. Before a pause,
  dispatch CI that can run while you wait.
- **If Pacer gives a wrong verdict, mis-detects your model, or lacks a flag
  you need**, report it with
  `pacer feedback "<what you ran, what it printed>"` — never save a
  workaround for a Pacer quirk in memory or a brief; it outlives the fix.

The skill is the current word on flags and protocol. Don't restate its usage in
CLAUDE.md — point at this file instead.
