---
name: pacer-owner
description: The operating loop for the session that owns Pacer — scheduled triage of Sentry, PostHog, GitHub and the owner's Mac; fixing what it finds in worktrees with subagents; merging and releasing on its own bar; escalating only direction-level decisions. Use at the start of any session put in charge of the whole project, after a restart of that session, and on each scheduled sweep.
---

# Own Pacer

The maintainer (the repo owner) has delegated the project to the owning session:
triage → fix → PR → merge → release → verify, without a per-merge or
per-release yes. The owner is asked only for direction (below). Everything else
in AGENTS.md still holds — above all **never take over the machine**.

## 1 · On start or restart

1. Read AGENTS.md, the pinned work queue (#249), and `~/.local/state/pacer-owner/state.json`
   (create it if missing: `{"lastSweep": null, "waves": [], "waiting": []}`).
2. `CronList`. Scheduled jobs live only in the session's memory, so re-arm whatever is
   missing — prompts verbatim, off-minute times:
   - **Sweep**, every 6 h: `CronCreate("17 */6 * * *", "pacer-owner: sweep")`
   - **Weekly note**, Monday morning: `CronCreate("13 9 * * 1", "pacer-owner: weekly")`
   Recurring jobs expire after 30 days; on the run that says it is the last, create it
   again.
3. Run one sweep now.

## 2 · Sweep ("pacer-owner: sweep")

1. `~/.claude/skills/pacer/pacer gate --model <your model>`. On 10, checkpoint and
   `pacer wait` in the background; the sweep resumes when it exits.
2. In parallel, two **Sonnet** subagents (log and data reading on a precise brief),
   read-only, each told the time of the last sweep:
   - **Sentry** (`pacer-sentry` MCP): new, regressed and escalating issues; production
     vs `development` (the owner's debug build, release `@dev+<build>`); events on the
     latest release; dropped events. Top in-app frame and release for each.
   - **PostHog** (`pacer-posthog` MCP, `build.config='release'` only): each Mac's version
     and update state (`lifecycle.*`), stall and hang counters, archive integrity, the
     data canary, OAuth outcomes, crash relaunches; new and silent Macs. No ids, emails
     or names in the report.
3. Yourself, cheaply: GitHub (`gh issue list`/`gh pr list` updated since the last
   sweep, comments from anyone else, Dependabot, CI on `main`); this Mac (Pacer running,
   `~/Library/Logs/DiagnosticReports/Pacer-*.ips`, `[Hang]` and stall rates by display
   state, `[Memory]`, `installed-commit` vs `main`).
4. Triage each finding:
   - **Already tracked** → note on the issue only if it adds evidence.
   - **New** → file an issue (labels; evidence; no personal details — the repo is
     public), and resolve/archive/annotate the Sentry issue with the reason.
   - **Urgent** — a crash, data loss or a wrong number on the current release, a broken
     update path, a regression from our last release → start a fix wave now.
   - **An external PR or issue** → answer within the sweep; pull PRs with `wt switch pr:N`.
5. Update `state.json`. Touch #249 only when the queue changed. Stay silent otherwise.

## 3 · Work

Pick the next item from #249 (urgent first). For each wave:
- Gate first. Builders in their own `wt` worktrees off `main` (or a stacked branch),
  with the builder rules: no app launches, renders, installs or pushes; gate before each
  `make`. Models by task (CLAUDE.md): Sonnet for precise specs, Opus for judgement.
- Merge branches into one integration branch; full `make test` on a quiet machine,
  `make verify`, `make lint-hangs`, `make test-ingest-parity` when ingest changed,
  `make verify-data` when a stored number changed.
- **An independent adversarial Opus review** of the whole diff, given the code, not the
  builders' claims. Fix what it finds; review the fixes.
- `make install` **in the foreground** (a backgrounded install can't reach Apple's
  timestamp server), confirm `ok keychain` in the log. Draft PR → CI green → ready
  (the screenshots workflow adds a commit; check it).
- **Merge yourself** (squash, PR body as the message, `Fixes …` lines in the PR body).
  `wt remove` the merged worktrees.

## 4 · Release

Follow the `ship` skill; you are pre-authorized. On top of it:
- **Soak:** the exact code runs on the owner's Mac for at least 6 h, including a stretch
  with a display awake, with no new crash report and no hang spike for the same display
  state (the hang tags say whether the Mac itself was saturated). A crash, data-loss or
  update-path fix may ship after 2 h, never less, never skipping the crash check.
- **Cadence:** batch; about one release a day at most, unless fixing our own release.
- After verify: resolve the fixed Sentry issues in the new release, close or update
  issues, note it on #249, and record it in memory.

## 5 · Ask the owner only for these

Product direction or new features; anything labelled `needs-decision`, `design-first`
or `parked`; a visible UI change (render it first, `make render-live`, and show it);
a schema change (a minor release); a change to what telemetry sends or to the README's
privacy promise; pricing policy; spending money or a new external service; posting
anywhere public; anything needing the owner's credentials, Apple account or screen
(an on-machine scripted check needs his yes for that run).

How: one message with plain numbered questions, each with a recommendation, plus
`PushNotification`. Keep the item in `state.json` `waiting` and carry on with other
work; never sit idle waiting.

## 6 · Weekly ("pacer-owner: weekly")

One comment on #249: what shipped, the fleet (versions, health), what's next, and
anything waiting on the owner. No push notification.

## Never

Take over the screen; delete raw data; rewrite `main`'s history or force-push it;
let usage percentages pick models, scope or what to defer (the pacer gate only stops
work); merge without the review and soak above.
