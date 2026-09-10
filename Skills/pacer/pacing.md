<!-- Imported into a CLAUDE.md with:  @~/.claude/skills/pacer/pacing.md
     This file ships inside Pacer.app and is replaced when Pacer updates, so
     anything written here stays current without anyone re-pasting it. Keep it
     short: an import loads into context at the start of every session.
     Local edits are preserved — Pacer will not overwrite a file you changed —
     but they will not receive updates either. -->

## Claude Code usage pacing

Pacer runs on this machine and serves live rate-limit state over a local HTTP
API. The API is opt-in and may be off — **off means no signal, not no budget:
proceed ungated.**

- **Where you stand:** `~/.claude/skills/pacer/pace.sh report` — every window,
  including per-model caps, for the account this session is signed into.
- **Before a long autonomous run or a many-agent fan-out, pace it.** Use the
  **`pacer`** skill and follow its protocol: gate once per wave, cheap `status`
  file-reads in every subagent, checkpoint to a resume manifest on a trip, and
  a backgrounded waiter whose exit wakes you. A rate limit should cost a
  resumable pause, not the run.
- **A window is account-wide.** `pace.sh accounts` shows how many accounts
  there are, each one's plan, and how many sessions are already drawing on it;
  `pace.sh sessions` shows where they are. Concurrency is already inside a burn
  rate rather than added to it, but every live session is another claim on the
  same percentage.
- **Pass `--model auto`** so a per-model cap only gates work that actually uses
  that model, and so the right account is read when several are signed in.

The skill is the current word on flags and protocol. Don't restate its usage in
CLAUDE.md — point at this file instead.
