# Account scope — working state and continuation brief

Operational companion to [`multi-account.md`](multi-account.md), which holds the
*design*. This one holds the **state, the invariants, and the traps** — written
so a session picking this up cold does not re-learn them the expensive way.

Branch `feat/account-attribution`, 39 commits, 750 tests, `make verify-data`
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

Deliberately **not** scoped, with reasons in `multi-account.md`: rate limits
(a property of the login), alerts (a display filter must not silence a budget
alarm), the HTTP API (scripted consumers want explicit control),
`ToolbarFreshness`, and the three project-management views.

Verified on the real store: a mixed day splits `$70.78` (work) + `$1,187.71`
(personal) = `$1,258.49` (global). Fresh-install cold start builds all 28 models
and 108,660 entries in 22.8 s with no migration.

---

## What is next, with honest sizing

**1. Rate-limit history per account — big, risky, not started.**
Still swap-based: switching archives one account's samples and restores the
other's, so the non-active account's pace chart does not exist. Making it
per-account is **45 read sites, 13 of them compile-time `static let`
descriptors**, across the menu bar, widgets, alerts, the API and the forecast
engine — the most load-bearing path in the app. Do not start it casually.

The narrower win: the archive already holds the other account's history
(**45,943 rows per window, current to now**, because secondary accounts archive
their readings). A per-account sparkline in the Accounts card would surface the
trend without touching that path — but it is new UI, and Eric's rule is rendered
options and sign-off before building visual work.

**2. Per-account alert rules.** A feature, not a fix. Inheriting the window's
scope is explicitly the wrong way to get it.

**3. An `account` parameter on the HTTP API.** A feature. The API deliberately
reports every account today.

**4. Notarized build + PR.** Both Eric's call. CI only runs on `main` or PRs, so
this branch has no CI signal.
