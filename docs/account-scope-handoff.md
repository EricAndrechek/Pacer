# Account scope — working state and continuation brief

Operational companion to [`multi-account.md`](multi-account.md), which holds the
*design*. This one holds the **state, the invariants, and the traps** — written
so a session picking this up cold does not re-learn them the expensive way.

Branch `feat/account-attribution`, 44 commits, 772 tests, `make verify-data`
green. Schema at 28 models, cost recompute version **14**.

---

## Read this before touching anything

### 1. `make verify-data` is the gate, and it must be run quiesced

It cross-checks each per-account rollup against its global counterpart. **It has
caught four real bugs that would otherwise have shipped**, three of them mine
in the same session:

- the daily incremental fast path never updating account rows,
- a two-month-stale pricing snapshot billing new models at `$0`,
- a session fetch that could not see the cycle's pending inserts,
- `recomputeOne` missing a call site entirely.

**Quit Pacer before trusting a failure.** With the app running, the global
rollups legitimately trail the samples by a turn or two mid-cycle, and that
reads as drift. Quit, verify, relaunch:

```sh
osascript -e 'quit app "Pacer"'; sleep 3
make verify-data
open -g -a Pacer
```

Do **not** wrap that in a retry loop that quits and relaunches each iteration.
I did; it interrupted the rebuild before it could persist its version, so the
rebuild ran 36 times and never completed, and the resulting failures were the
harness's, not the code's.

### 2. Adding a per-account rollup

Four exist: `AccountDailyAggregate`, `AccountHourlyAggregate`,
`AccountProjectDailyAggregate`, `AccountSessionInfo`. To add another:

1. Sibling `@Model` **alongside** the global one — never add `accountId` to the
   existing key. Views that map aggregates one-to-one onto rows (the per-model
   breakdown) would list a model twice the moment two accounts used it the same
   day.
2. Emit from **all three write paths**: incremental fast path, per-bucket
   recompute, bulk worker. Missing one is the single most likely mistake — I
   made it twice.
3. If the rollup has a **non-additive field** (a distinct count, a `topModel`
   chosen by comparing totals), put the maths in a shared value type
   (`ProjectRollupValues`, `SessionRollupValues`) so one algorithm writes both
   rows. "Recompute twice" and "recompute once, write twice" differ here.
4. Add a cross-check to `bin/dev-verify-data.sh`. Compare **tokens and cost
   only** — session and model *counts* legitimately do not sum, because a
   session spanning a switch belongs to both accounts' sets and once to the
   global one.
5. Bump `currentCostRecomputeVersion`; rows only exist for buckets recomputed
   since.

### 3. Making a view scope-aware

Two live `@Query`s (global + scoped) and a computed property choosing between
them. **The scope must arrive as an initialiser parameter** — a `@Query`
predicate is captured once at init, so a view reading the scope itself stays
pinned to whatever was selected when it first appeared. The parent holds
`@State private var scope = UsageScope.shared` and passes `scope.accountId`.

Views outside the view tree — widgets, the CSV exporter, the menu bar — read
`UsageScope.storedAccountId` instead. It lives in **App Group** defaults; the
widget process cannot see `UserDefaults.standard`.

Normalise with `DailyRow` / `HourlyRow` / `SessionRow` / `ProjectDailyReadable`
so the body renders either source.

---

## Traps that cost real time

**A `str.replace()` without an assertion is a silent no-op.** One edit anchored
on `sessionId: sessionId` where the code said `sessionId: sid`. It did nothing,
built fine, and I reported the feature as landed. Every edit in this series that
asserted was correct; the one that did not was the one that broke.
**Assert every anchor.**

**File-level greps overstate coverage.** `HistoryView.swift` counted as "scoped"
because two of its three cards were, while `TopDaysContent` sat in the same file
reading the global rollup. Audit **per struct**:

```sh
python3 - <<'PY'
import pathlib, re
files = list(pathlib.Path("App").rglob("*.swift")) + list(pathlib.Path("Widgets").rglob("*.swift"))
rollups = re.compile(r"\[(DailyAggregate|HourlyAggregate|ProjectDailyAggregate|SessionInfo)\]")
for p in sorted(files):
    for part in re.split(r"\n(?=(?:private )?struct \w+)", p.read_text()):
        m = re.match(r"(?:private )?struct (\w+)", part.strip())
        if m and rollups.search(part) and "UsageScope" not in part and "ScopedReads" not in part:
            print(f"global: {m.group(1)} ({p.name})")
PY
```

**A native control failing app-wide is almost never the control.** Menus and
popovers were opening in a screen corner. I replaced `Picker` with a hand-rolled
popover, then a segmented control, then a `Stepper` — three commits of
avoidance. The cause was mine four commits earlier:
`MainWindowPlacement.holdPlacement` scheduled `setFrame` calls from
`didBecomeKey`, so every click into the window moved it for two seconds,
including out from under an open menu. Symptoms that should have pointed at my
own change: **intermittent, sometimes self-correcting, affecting several
different control types, not display-dependent.**

**Scripted UI verification can falsify but not confirm.** I reported a window fix
as verified because the frame was *identical* across an install — it was stably
wrong. Synthetic AppleScript clicks are also not user gestures, so macOS refuses
the activation they depend on; "0 windows" was measuring my own harness. Frame,
focus and window counts can all be right while the thing still looks wrong. Ask
Eric.

**Headless diagnostic modes open a window unless stopped.** `.accessory` does not
prevent macOS restoring one for the bundle, and these run as a *second* instance
beside the user's real app. Fixed for all four modes; keep it that way if you
add a fifth — and remember every mode must appear in **both** launch gates in
`PacerAppDelegate`, or it silently gets an in-memory store and reports
confidently on no data.

---

## Environment

- `make install` needs Keychain access for notarization that an agent session
  cannot get. Use `PACER_DEV_SKIP_NOTARIZE=1 make install`. **Every install this
  session used it — the branch has never had a notarized build.**
- The dev install relaunches with `open -g` and must not steal focus or move the
  window. If it does, something re-entered the frame-setting path.
- Eric keeps the dashboard open on a portrait display at x≈2500. Leave Pacer
  running and its window where it was.

---

## What is done

Attribution (`AccountActivation` trail, `TokenSample.accountId`, backfill,
follow-the-login), four per-account rollups, and **23 scoped surfaces**: every
dashboard card, history, projects, collections, models, heatmap, the three
drill-down modals, the menu bar, four widgets, advisor badges, CSV export.

**Rate limits are per account now too** — the big item on the old list. Every
account writes the live sample tables stamped with `accountId`, switching is a
flag flip rather than 107,705 rows moving, and `LimitScope` scopes every read.
Read the "Rate limits are per account too" section of `multi-account.md` before
touching any of it; the short version is that a read which forgets to scope is
silently wrong, not empty.

**The forecast engine is per account too** — this was the last item on the
"what is next" list. `EngineHost` keeps one `UsageIntelligenceEngine` per
`EngineScope`; `.allAccounts` is byte-identical to what shipped (its surfaces
stay unsuffixed) and each account's surfaces are suffixed `#<accountId>`.
Everything the engine feeds is therefore scoped: the Now tile, the pace
projections and their bands, the advisor badges, the outlook chips.

Two traps live in there. `await engine.x()` called from a `@MainActor` type
runs the callee **inline on the main thread** — Swift's uncontended-actor
optimisation — and so does a plain `Task {}` started from one; `askEngine`
(`Task.detached`) exists because five call sites had that shape and cost 7.9 s
of launch stall between them. And a projection refresh must be gated on
*starting*, not debounced: the engine's ~14 s launch refit serializes every
pending pass behind it, so they all complete in the same second no matter how
long you delayed each one.

The API asks explicitly: `GET /v1/accounts` lists the ids, `/v1/usage/daily`
and `/v1/usage/models` take `?account=`, and `/metrics` emits per-account
series. Unscoped output is unchanged. Accounts can be renamed (Settings →
Tokens), and a typed name outranks the observed email in `Account.label`.

Deliberately **not** scoped, with reasons in `multi-account.md`: alerts (a
display filter must not silence a budget alarm), the HTTP snapshot (scripted
consumers get the active login and are told which it is), and the three
project-management views.

Verified on the real store: a mixed day splits `$70.78` (work) + `$1,187.71`
(personal) = `$1,258.49` (global). Fresh-install cold start builds all 28 models
and 108,660 entries in 22.8 s with no migration.

---

## What is next, with honest sizing

**1. Per-account alert rules.** A feature, not a fix. Inheriting the window's
scope is explicitly the wrong way to get it.

**2. Notarized build + PR.** Both Eric's call. CI only runs on `main` or PRs, so
this branch has no CI signal.

---

## One more trap, from the API work

**A leak the tests could not see, because they had never seen real data.**
`pacer_account_info` published `organizationName` as its label, on the reasoning
that the org name is coarser than the email. It is not: Anthropic *derives* the
org name from the email, so it reads `"<someone>@<domain>'s Organization"` for
every real account. The unit test passed because its fixture said `"Acme"`.
Caught by curling the live endpoint after installing.

The general shape: **a test fixture is an assumption about the world.** When the
assertion is "this output never contains X", the fixture that proves it is the
one taken from the real store, not the one that reads nicely in a diff. There is
now a test using an email-derived org name, and `metricsName` falls back past
everything observed to `Account <last 4 of id>`.

---

## Three more, from the rate-limit work

**A migration that under-drains must be repeatable, not guarded.** The one-time
fold moved 111,250 archived rows and then reported 1,250 still recent — rows a
`sampledAt >= cutoff` fetch should plainly have returned. I never explained it.
A meta-key guard would have made that a permanent hole in the chart; running
the pass every launch cost three index probes and fixed it on the next start.
When a one-shot migration's correctness is not provable, make it idempotent and
let it run again.

**A mirror in defaults will drift, so repair it rather than trusting it.** The
active account id is mirrored into App Group defaults for the widget process.
`publishStatus` wrote the poller's in-memory `activeAccountKey`, which is
`Account.defaultKey` until a response carries an org header — so defaults said
`"default"` while the store said a uuid, and every read scoped to it matched
nothing. The failure mode is the dangerous kind: no error, no empty state, the
gauges just stopped having a value. Both ends now publish only ids the store
knows, and `reconcileScopeMirror` repairs whatever is there at launch.

**`defaults read` lies.** It served a stale value for minutes after the app had
written the correct one. Read the plist under the group container
(`plutil -p ~/Library/Group\ Containers/<group>/Library/Preferences/<group>.plist`)
before concluding a write did not happen.

**Adding a predicate to a hot `@Query` is a performance change.** This is the
single most expensive lesson of the account work. A `@Query` re-executes on
every model-context change, and Pacer's context changes every scan cycle. An
*unpredicated* capped fetch survives that fine — CoreData serves it from its
row cache — which is why the menu bar, the notification host and the toolbar
pill all ran free before accounts existed. Adding `accountId == x` to each made
every one a real fetch, several times a second, on the main thread. Scoping
them was correct; leaving them as `@Query` was not. The pattern that works is
a one-row **unpredicated** `@Query` as a signal plus the real load into
`@State` behind it — `PaceChartCard` documents it and now so do the other four.

And measure before fixing. I optimised the pace chart's fetch twice (off the
main actor, then 2.5× fewer rows) and neither made a felt difference, because
the cost was somewhere else entirely. `MainThreadStallWatchdog` plus a
`sample` of the process found it in one pass: 91 of 92 main-thread samples in
one view's body were two fetches. Three plausible culprits reasoned from the
code, all three wrong.

**SwiftData does not add indexes to an existing store.** `#Index` is applied
when SwiftData *creates a table*; lightweight migration adds columns and
silently skips the indexes. So the four rollup tables created new have theirs
and every pre-existing table gained an `accountId` predicate on every read with
nothing backing it. A fresh install and an upgraded one get *different query
plans*, which makes a performance report impossible to reproduce.

`StoreIndexRepair` fixes this: raw `CREATE INDEX` at launch, `pacer_ix_`-named,
skipping anything already covered by a leading prefix, never dropping. **Adding
an `#Index` to a model is only half the change** — add the same entry to
`StoreIndexRepair.desired` and to the `make verify-data` index check, or it
exists only for people who install fresh. Check with
`sqlite3 <store> "SELECT name FROM sqlite_master WHERE type='index'"`.

**A conditional body cannot start its own `.task`.** SwiftUI does not run
lifecycle modifiers on an `EmptyView`, so a view whose body is `if let x { … }`
with `.task { load x }` attached to it never loads: the task waits for a view
that only exists once the task has run. This is a live hazard for exactly the
pattern this work introduced everywhere — replacing a `@Query` (data present on
the first body evaluation) with `@State` + a keyed fetch. Wrap the content in a
real container before attaching the modifiers. It cost the dashboard's
"via oauth · 1m ago" chip, which was simply absent for the whole branch.

**Scoping is not finished until the *live* probes are scoped.** The rollups
were the visible half. The invisible half is every "newest row in the table"
fetch — last turn, last session, last sample — which under a scope reports
whoever wrote last. The Now tile read "Nothing running." and "Last activity 15s
ago" at the same time, one from scoped hourly rows and the other from the other
account's newest turn, with a "live" chip from a third unscoped probe. Grep for
`FetchDescriptor<TokenSample>` / `<SessionInfo>` before believing a surface is
scoped.

**A donut's legend and its hover index must walk one array.** Three cards had a
metric picker (or a fixed metric) on the chart and a *separate* sort control on
the table beside it, and took `rows.prefix(n)` from the table's order — so
"Top projects" listed five arbitrary projects and hovering a wedge named the
wrong model. Same class: a bar whose length is one metric under a heading that
names another (History's "Heaviest token days" drew cost).

**Tests write to the machine's real App Group suite.** `PacerPreferences.store`
resolves to the live group container in the test process too, so a test that
sets a scope leaves a fixture id where the running app reads it. Capture and
restore, and mark the suite `.serialized` — parallel tests otherwise clobber
each other's restore.
