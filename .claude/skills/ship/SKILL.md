---
name: ship
description: >-
  Ship a Pacer release using the install-first, single-gate flow. Use when the
  maintainer asks to release / ship / cut / publish a version, or — after a
  local install they've reviewed — to land and release the current work. Covers
  the version-bump + release-notes gate, landing the PR, and the backgrounded
  tag → watch → verify. Do NOT start a release mid-work: it only begins once the
  work is done AND approved (either up front — "…and release it" — or at the
  post-install gate). The mechanical half is `bin/ship.sh`; the human process +
  one-time secret setup is `docs/releasing.md`.
---

# Ship a Pacer release

This skill is the **orchestration and the gate**. The deterministic plumbing —
computing the next version, tagging, watching the Release workflow, verifying
the published artifact — is in `bin/ship.sh`. Read `docs/releasing.md` for the
pipeline and one-time setup.

**There is exactly ONE human gate: a single approval right after a local
install.** Everything after it is autonomous and backgrounded. The whole point
is that a release costs almost no attention (and almost no expensive model
tokens): the waiting and verifying happen in a backgrounded script, and the
draft/review chores go to a cheap model.

## 0 · Before a release (during the work)

- Branches and PRs are your judgement — stack/rename branches freely as scope
  grows, push for backup whenever. **Do not open the PR yet**, and never
  tag/merge here.
- When the work is done, `make install` so the maintainer can see it live.
  Stop there.

## 1 · The gate — right after `make install` is live

1. `bin/ship.sh preflight` → prints the suggested bump (patch, or **minor** if a
   `@Model`/schema change is detected — you confirm; minor = a SwiftData reset)
   and the next version.
2. `bin/ship.sh notes <version>` → previews the **exact** notes CI will publish
   (`--generate-notes`), so what you show matches what ships.
3. Surface **bump + notes**:
   - **Not pre-authorized** → ask **once** with `AskUserQuestion` (it push-
     notifies the maintainer and blocks). Offer: ship it · hold · change the
     bump. This is the *only* AskUserQuestion in the flow.
   - **Pre-authorized** — the kickoff request already said to ship ("…and
     release it", "ship it autonomously", "merge and release") → send a
     `PushNotification` FYI with the bump + notes, then proceed.

The only other permitted interruption anywhere is a genuine implementation/
direction fork you shouldn't guess on.

## 2 · Prep — into the PR, before merge

Do the release housekeeping and commit it to the branch **before** merging (so
the shipped PR is self-contained):

- If any UI changed: `make screenshots`, eyeball them, commit the PNGs.
- Update README / docs / `docs/releasing.md` / any stale internal `.md` for what
  changed. Update your durable memory if a real lesson came out of the work.
- **PII scan** the screenshots + new docs. Delegate to a **Haiku subagent**
  (vision): "flag any real names, emails, absolute home paths, tokens; public
  examples must be fictional (Acme/Globex)." Fix anything it finds.

Commit it all, then open the PR.

## 3 · Land — autonomous, background the waits

- Push, open the PR.
- `bin/ship.sh wait-ci <branch>` — **background it**. On failure: pull the logs
  (a Haiku subagent can summarize), **fix recursively yourself**, re-push,
  re-wait. No gating.
- Squash-merge to main; `git checkout main && git pull`.
- Converge any other session branches the same way; if a merge changes rendered
  output, regenerate screenshots/docs onto main.
- `bin/ship.sh wait-ci main` (backgrounded) — main must be green before tagging.

## 4 · Release — autonomous, backgrounded

- `bin/ship.sh release <version>` — **run it with `run_in_background: true`**. It
  tags, watches the Release run, then verifies (asset present · appcast
  advertises the version · enclosure length matches the asset · EdDSA signature
  validates against the app's embedded `SUPublicEDKey`). One notification when
  it's done.
- If it exits non-zero: fix the cause and cut an autonomous **patch** bump with a
  short note (e.g. "fix release pipeline"), no gating — these are needed to make
  the *already-approved* release actually work. Repeat until
  `bin/ship.sh verify <version>` is green.
- **Never** try to drive the maintainer's GUI to confirm the Sparkle download/
  relaunch — screen control is not allowed. The headless signature check already
  proves the update path works.

## 5 · Recap

Relay a short what-shipped summary — version, release + PR links, and the
`verify` checklist. A Haiku subagent can draft it.

## Token discipline (why this exists)

- **Background** `wait-ci` and `release` — never poll them turn-by-turn; each
  poll re-reads the whole context on an expensive model.
- **Delegate** the draftable + visual chores (notes/recap wording, CI-failure
  summaries, the PII/screenshot review) to **Haiku subagents**
  (`Agent` with `model: haiku` — Haiku has vision).
- Keep the expensive model for the three things that actually need it: the gate
  judgement, the patch-vs-minor call, and non-trivial CI fixes.
