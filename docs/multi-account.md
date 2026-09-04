# Multi-account: attribution, switching, and parallel sessions

> Working state, invariants and traps live in
> [`account-scope-handoff.md`](account-scope-handoff.md). This file is the
> design.

How Pacer knows which account a turn belongs to, why that needed a new
mechanism, and what is still open.

Written 2026-09-03, when the maintainer started running two accounts through
[claude-swap](https://github.com/realiti4/claude-swap) (`cswap`) — work and
personal — and Pacer turned out to be reporting the wrong one.

## The symptom

Pacer's menu bar, dashboard, `/metrics` and `/v1/snapshot` all read
`7d = 100%`: a weekly window belonging to an account that had not served a
request in over three hours. Claude Code was billing a different account
sitting at 1%. Every consumer of that API — including the `usage-guard` skill
that paces long agent runs — was being told to slow down for a limit that did
not apply.

## Why the account dimension stopped halfway

Pacer had tracked accounts since the multi-account work landed, but only on
one side of the app.

| Fed by | Tables | `accountId`? |
|---|---|---|
| The OAuth poller | `RateLimitSample`, `ExtraUsageSample`, `UsageLimitSample`, `AccountUsageArchive`, `AlertRule` | yes |
| Parsing JSONL transcripts | `TokenSample` | **no** |

The poller resolves each token's `anthropic-organization-id` from a response
header, so it *knows* whose usage it just read. The transcript side has no
such luxury, and this is the load-bearing fact for everything below:

> **Claude Code's JSONL carries no account identity on a billable turn.**
> `accountUuid` appears only on `artifact-autoreact-ledger` bookkeeping lines
> — 12 occurrences across a 283,000-turn corpus, none of them on an assistant
> message. `~/.claude.json`'s `oauthAccount` names only whoever is logged in
> *right now*, and is overwritten in place on every switch.

So the account a turn belongs to is **not recoverable from the turn**. It has
to be recorded as it happens, or it is gone.

## The design

### An activation trail

`AccountActivation` records intervals: *account X was the active login from
T1 to T2*. `ActiveAccountObserver` watches `oauthAccount` in Claude Code's own
config — the object Claude Code rewrites on every login change — so a switch
is noticed no matter what caused it.

Deliberately **tool-agnostic**. It works for a switcher, for someone typing
`/logout` and `/login`, and for a tool that does not exist yet. Nothing in the
core depends on `cswap` being installed.

Not the keychain: a credential blob says a token changed, not whose it is.
Resolving that costs an API call, while `oauthAccount` already carries the org
id for free. Reads are gated on the file's mtime, because the config is
~180 KB and a JSON parse of it on every 20-second scan cycle is exactly the
kind of unwatched background work that once cost a quarter of a CPU core.

**The write rule is asymmetric, on purpose.** An activation is only ever
closed by a *successful* read showing a *different* account. An unreadable
config, a missing `oauthAccount`, a file caught mid-rewrite: all leave the
trail untouched. A missed switch self-corrects on the next cycle; a false
switch splits one account's session across two and is undetectable
afterwards.

### Attribution by timestamp, and by root

`SamplePersister` stamps each sample from the trail using **when the turn
happened**, not who is logged in now — a scan cycle routinely ingests lines
written before the last switch.

That is enough while one account is live at a time. It is not enough for
parallel sessions, where the trail has two valid answers for one instant. The
tie-break already exists on disk: a session pinned to its own
`CLAUDE_CONFIG_DIR` writes to that profile's own `projects/` directory, and
that directory belongs to exactly one account. `ParsedUsageEntry.rootPath`
carries it from scanner to persister.

A pinned root that no activation covers resolves to **nil, never the default
account** — those turns are known not to be the default account's, so
"unknown" is the honest answer.

### The data model is always parallel; only the presentation adapts

Activations may overlap. `AccountTrail.hasConcurrentAccounts` reads
switching-vs-parallel off the trail, so someone who switches gets the simple
view and someone running accounts in parallel gets the richer one, with no
mode to configure — and history stays correct across the transition, because
the model was parallel the whole time.

### Unattributable stays unattributed

`TokenSample.accountId` is nullable, and nil is a **permanent, expected
state** for every row written before the trail existed. Splitting that history
by "whoever is logged in now" would produce a per-account cost breakdown that
is confidently fiction — the same shape as a missing price rendering as `$0`,
where a legal-looking number means nothing ever revisits it.

There is exactly one automatic backfill, and it is a fact rather than a
convenience: **a store that has only ever seen one account** attributes its
whole history to it, because there is no other candidate. Two accounts gets
nothing automatic. `make assign-accounts SPEC='<accountId>|<from>|<through>'`
is where the user supplies what Pacer cannot know.

### Session profiles are discovered, not configured

`ClaudePathResolver` resolves roots from the environment, and Pacer is a
background agent that never has `CLAUDE_CONFIG_DIR` set — so it structurally
could not find a directory that a *terminal* pinned. That was not
misattribution; it was **absence**. Every turn from a parallel session was
missing from tokens, cost and project history with nothing to indicate a hole.

`resolveAllRoots()` adds any per-account profile a switcher has created. Each
is bound to its account from the profile's *own* `oauthAccount` — never the
switcher's say-so — before its transcripts are parsed.

### Labels

Two accounts on the same plan derive the identical placeholder
("Claude account (max)"), and running two accounts on one plan is precisely
what a switcher is for. `Account.label` falls through email → org name →
display name → id. The live login's identity comes free from `oauthAccount`;
accounts Pacer has only met as a second token get theirs from
`ExternalAccountDirectory`, which reads a switcher's roster.

A roster can attach a name to an org id Pacer resolved for itself. It can
never *establish* identity. A tool mislabelling a slot can make a label wrong;
it cannot move usage between accounts.

## How claude-swap works, in the parts Pacer depends on

The join key is free: cswap's `sequence.json` records `organizationUuid` per
account, and `Account.id` **is** the `anthropic-organization-id`.

**Switch mode** (`cswap switch` / `auto`) swaps the active login in place — on
macOS the `Claude Code-credentials` keychain item plus `oauthAccount`. Both
accounts' transcripts land in the same `~/.claude/projects/`.

**Session mode** (`cswap run N`) sets
`CLAUDE_CONFIG_DIR=~/.claude-swap-backup/sessions/<n>-<slug>/` for one
terminal. Claude Code sha256s that env *string* (NFC, first 8 hex) into a
per-profile keychain service `Claude Code-credentials-<digest>` — one-way, so
Pacer can go path→digest but never digest→path. The profile gets its own
`projects/` unless `--share-history` symlinks it back.

Machine-readable surfaces worth knowing: `cswap list|status|switch --json`
(all `schemaVersion: 1`), and `cswap auto --json`, a newline-delimited event
stream documented as additive.

## The live tables are a cache, not the record

`AccountUsageArchive` is the record and is never pruned. The live sample
tables hold the **active account's recent window** — the widest reader is the
engine's 32-day backtest, every view reads 8 days, so the bound is 35 days.

This matters because the swap moves every row it touches. Measured at the
counts a real machine reaches: **107,705 rows, 14.3 seconds** in memory
(`SwapCostBench`), and 177,689 archived rows had accumulated in five months.
Three things keep it survivable — the 35-day bound, an hourly eviction pass so
single-account users stay bounded too, and running the swap on `@ScanActor`
rather than the main thread, batched and yielding.

Eviction is not deletion: every row is written to the archive before it is
removed.

## What follows the scope, and what doesn't

A menu in the window toolbar selects "all accounts" or one, persisted in **App
Group** defaults so the widget extension — a separate process — can read it
too. It renders nothing when only one account exists.

**Follows the scope** (23 surfaces): every dashboard card, history, projects
and collections, models, the heatmap, all three drill-down modals, the menu
bar, all four data widgets, the advisor badges, and CSV export.

**Deliberately doesn't:**

| surface | why |
|---|---|
| Rate limits (pace chart, menu-bar gauges) | A property of the *login*, not a view preference. They are always the active account's. |
| Alerts | A view shows what you asked to see; an alert tells you what you didn't. A spend threshold a display filter can silence is a footgun — scope to work in the morning, stop hearing about personal spend all day. Per-account *rules* are a fine feature; inheriting the window's scope is not the way to get them. |
| The HTTP API | A scripted consumer wants to say what it means, not get different numbers depending on what a human last clicked in an app it cannot see. Per-account figures belong behind an explicit parameter. |
| `ToolbarFreshness` | Data freshness, not usage. |
| Project management (merge sheet, collections manager, alias manager) | They list *paths*; totals are ordering context. Scoping could hide a project you are trying to merge. |

### How a view becomes scope-aware

Two live `@Query`s — global and per-account — and a computed property picking
between them. The scope arrives as an **initialiser parameter**, because a
`@Query` predicate is captured once at init: a view that read the scope itself
would stay pinned to whatever was selected when it first appeared.

`DailyRow`, `HourlyRow`, `SessionRow` and the `ProjectDailyReadable` protocol
normalise the two tables so a view body renders either without knowing which.
That is what keeps the switch a change of *source* rather than a second copy
of every view. `SessionsTable` and `CollectionUsageRollup` moved onto those
types for the same reason.

Surfaces outside the view tree — the widgets, the CSV exporter, the menu bar —
read `UsageScope.storedAccountId` directly, since they have no parent to pass
a parameter down.

One asymmetry worth knowing: `HourlyRow.sampleCount` exists only on the global
rollup, so a scoped row reports 0. It feeds a "quiet hour" hint, never a number
anyone reads.

## Four rollups, and what they cost

`AccountDailyAggregate`, `AccountHourlyAggregate`,
`AccountProjectDailyAggregate` and `AccountSessionInfo` sit **alongside** their
global counterparts rather than replacing them, so no existing read site
changed and both scopes are always available without a recompute.

Each is written by the same pass that writes its global counterpart, across
all three write paths (incremental fast path, per-bucket recompute, bulk
worker). Where a rollup has non-additive fields — a distinct-session count, a
`topModel` chosen by comparing per-model totals — the computation moved into a
shared value type (`ProjectRollupValues`, `SessionRollupValues`) so one
algorithm produces both rows. "Recompute twice" and "recompute once, write
twice" are genuinely different once a field is not a sum.

**`make verify-data` cross-checks every pair.** That check has caught four real
bugs that would otherwise have shipped: the daily fast path skipping account
rows, the pricing drift, a session fetch that could not see pending inserts,
and a call site that was never added. It compares tokens and cost but *not*
session or model counts — a session spanning an account switch belongs to both
accounts' sets and once to the global one, so those legitimately do not sum.

The session fast path is single-account only. It cannot maintain account rows
incrementally, because an account's `topModel` may differ from the session's;
installs with one account keep it, anyone running two pays a full session
recompute for correctness.

## Deferred, with the reasoning

**Double-polling.** cswap and Pacer both poll Anthropic's usage endpoint for
the same accounts, neither aware of the other. Measured on the maintainer's
machine: cswap every 600s (busy account) and 1800s (idle); Pacer holds each
token to ≤1 poll per 300s across 7 discovered lanes, of which 5 sit in long
cooldown, so ~2 are effectively live. Not currently a problem, and cswap's
`cache/usage.json` (schemaVersion 2, with `lastGood`, `fetchedAt`,
`nextPollAt`, `pollIntervalS`) is the obvious thing to read instead of issuing
our own calls if it becomes one. Deliberately *not* re-tuning the scheduler on
speculation: the adaptive multi-token cadence was carefully derived and is
load-bearing.

**Absorbing the switcher.** Decided against, for now. The complaint about
cswap is its *packaging* — a uv tool install, a foreground menubar process, a
launchd plist, `launchctl kickstart` after every upgrade — and Pacer is
already a signed, auto-updating `.app` with a menu bar. But its switching
carries real hard-won correctness: it takes Claude Code's own credential locks
so a swap cannot interleave with a token refresh, quarantines accounts whose
refresh token died, uses hysteresis and a cooldown to stop flip-flopping, and
seeds session profiles with MCP mirroring. Reimplementing that has a "logged
out mid-session" failure mode. Delegate first; absorb only if it proves out.

## Things that will bite the next person

- **A diagnostic mode omitted from either launch gate in `PacerAppDelegate`
  silently gets an in-memory store** and reports confidently on no data. This
  cost an hour: `PACER_ACCOUNT_ASSIGN=list` cheerfully printed "every turn is
  attributed to an account" against an empty database.
- **Session roots and `rootPath` must land together.** Adding a root to the
  scan without threading its path through `ParsedUsageEntry` attributes a
  second account's turns to the first — the exact failure the nullable
  `accountId` exists to prevent, arriving through the back door.
- **`make install` needs Keychain access for notarization** that an agent
  session cannot get. `PACER_DEV_SKIP_NOTARIZE=1 make install` is the local
  iteration path; a real notarized build is required before any release.
