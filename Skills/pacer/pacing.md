<!-- Imported into a CLAUDE.md with:  @~/.claude/skills/pacer/pacing.md
     This file ships inside Pacer.app and is replaced when Pacer updates, so
     anything written here stays current without anyone re-pasting it. Keep it
     short: an import loads into context at the start of every session.
     Local edits are preserved — Pacer will not overwrite a file you changed —
     but they will not receive updates either. -->

## Claude Code usage pacing

Pacer runs on this machine. In your work it has one job: **stop it gracefully
at a rate limit.** It is not a budget to plan with.

- **Usage never picks the model, the fan-out width, the scope, or what to
  defer.** Decide those on the task's merits, and never cite usage as a reason.
- **Before each long step or subagent wave:**
  `~/.claude/skills/pacer/pacer gate --model <model>` (0 go, 10 pause), and give
  every subagent the `pacer status` clause from the **`pacer`** skill.
- **On a pause:** commit work in progress, update the resume manifest, dispatch
  CI that can run meanwhile, then run `pacer wait` in the background. Its exit
  means room is back (a reset, or a switch to another login): resume. Exit 20:
  checkpoint, stop, tell the user.
- **Exit 2 is no signal, not no budget:** proceed ungated.
- Run `pacer report` or `accounts` only when the user asks about usage. If the
  gate says informed pacing is on, the skill's `planning.md` applies.
- Wrong verdict or a missing flag: `pacer feedback "<what you ran, what it
  printed>"`. Never save a workaround in memory.
