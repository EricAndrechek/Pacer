# Agent guide — Pacer

Native macOS Claude Code usage tracker. SwiftUI + SwiftData + Charts.
Single-binary menu-bar agent shape (LSUIElement=true). Two targets
(Pacer.app + PacerWidgets.appex) sharing data through an App Group.
See `docs/design.md` for the full v1 design.

## Where to look first

- `docs/design.md` — full architecture, data sources, schema, IPC, scope.
- `docs/research/ccusage-reference.md` — ground-truth analysis of `ccusage`
  internals: path discovery, JSONL schema, cost modes, dedup correctness,
  pricing source. Read before touching parsing or cost code.
- `docs/research/realtime-mechanisms.md` — analysis of statusline, hooks,
  OTel, MCP for live Claude Code data.
- `docs/research/tcc-app-management.md` — investigation of the
  every-launch "would like to access data from other apps" prompt,
  what was tried, current signing/notarization state, and the
  open SMAppService verification question for v1 release.
- `docs/research/ccusage-outputs/` — captured `bun x ccusage` JSON outputs
  for the local dataset. **Use these as ground-truth in tests** — every
  metric Pacer surfaces should match `ccusage`'s number for the same
  range, with exactly **two deliberate deviations**:
  1. the cache 5m/1h split (we track them separately, ccusage flattens);
  2. **output tokens on streamed messages** — ccusage dedups first-wins,
     which keeps the mid-stream snapshot instead of the finished message
     and under-counts output by ~63% on a real corpus (correctness rule
     §7). Pacer is deliberately higher here. If a ccusage comparison
     shows us reporting *more* output than ccusage, that is the fix
     working — do not "correct" it back.
- **`AGENTS.md` → "SwiftUI state and data flow"** (below) — read before
  adding any `@State`, binding, sheet, modal, cached value, reload signal or
  `ModelContext` use. A view updates only on what its own `body` read;
  anything that updates because *something else* redrew is a bug that
  removing redraw work will expose.
- **`AGENTS.md` → "Performance — invariants and patterns"** (below) —
  read before adding ANY `@Query`, `FetchDescriptor`, computed view
  property, widget provider, or new rollup table. Codifies hard-won
  rules from five rounds of read-path optimization. The rules look
  nitpicky in isolation; in aggregate they're what keeps the app
  responsive while the in-process scan loop is firing every 5–60s.
- **`docs/perf-tuning.md`** — current cycle-time / CPU state, the
  measurement tooling (phase-timed scan log, `make perf-snapshot`),
  every perf commit's mechanism + measured win, and the open
  refactors that are deferred. Read before reintroducing animations,
  per-cycle SwiftData fetches, or adding any new always-running
  background work.

## Never take over the machine — no cursor, no windows, no focus

**Never without the owner's explicit, in-the-moment go-ahead.** Someone is
sitting at this Mac using it while you work. You do not get the input devices,
the windows, the focus, or the active Space — not briefly, not "just to check
something", not because a flag was set for you once in the past.

There is exactly one way this is allowed, and it is narrow:

1. You have already built and tested everything that *can* be tested off-screen,
   so the on-machine run is confirming one specific thing.
2. The whole run is scripted end to end, deterministic, and takes seconds. It
   asks nothing, guesses no coordinates, and restores what it touched.
3. You describe exactly what it will do, and the owner says go — **for that
   run**. Consent does not carry to the next one.

**Never explore, debug, or iterate on his screen.** If the scripted run fails,
it fails; take the artifacts away and work out why off-screen. A second attempt
needs a second go-ahead. "I'll just try it and see" is the thing that caused
this rule.

Concretely, never write, run, or leave behind anything that:

- posts synthetic input — `CGEvent`, `NSEvent` posting, `CGWarpMouseCursorPosition`,
  `CGDisplayMoveCursorToPoint`, `IOHIDPostEvent`;
- drives the UI through Accessibility or AppleScript — `osascript` with System
  Events, `AXUIElement` actions, `click`/`keystroke`/`key code`, `tell application
  … to activate`;
- runs an AppKit event loop against a *visible* window to simulate interaction —
  an `NSApp.run()` harness that dispatches mouse-moved events is exactly the
  thing this rule exists to stop;
- activates, raises, resizes, moves, closes or Spaces-switches any window,
  including Pacer's own;
- records the screen or captures another app's windows — with one sanctioned
  exception, below.

**The one screen-recording tool: `make record`** (`bin/dev-record.sh`).
Committed at the owner's request so any session can use it, and bound by the
same rule as everything above: **it records the screen, so it runs only with
the owner's go-ahead** — per run, or for a stretch of work he explicitly
approves ("iterate on the layout shifts, record as often as you need"). Run it
bare first; it prints its plan and exits. Scenarios:

- `SCENARIO=relaunch` — `make install`, i.e. quit → replace → relaunch;
- `SCENARIO=tabs` — Pacer switches through every tab and back to where it was,
  via `bin/pacer-select-tab.swift` (a distributed notification the app acts on
  itself: no input events, no activation, no focus change);
- `SCENARIO=idle` — nothing; whatever changes on its own.

What makes it acceptable to run while he works (`bin/pacer-window-recorder.swift`):
ScreenCaptureKit, one stream cropped to the dashboard's current frame with
**every other application excluded** — only Pacer's pixels are ever captured,
nothing is dimmed (`screencapture -V -R` dims every other display, which is why
it is not used), and a relaunched Pacer is captured from its first frame because
a new process is not in the exclusion list. Frames are PNGs named by wall-clock
ms, the log has ms timestamps, so they line up exactly; `changes.txt`
(`bin/dev-frame-diff.sh`) lists every frame that differs from the last, with the
changed area. Output goes to `screenshots/recordings/` (gitignored) — delete a
run's folder once it has been analysed. Do not extend it to other apps, whole
displays, input, or unattended runs.

Reading is fine: `NSEvent.mouseLocation` to place a window the *user* asked
for, `NSScreen.frame`, and so on. The line is between observing the machine and
operating it.

**What to do instead.** Everything Pacer needs to see it can render off-screen,
headlessly, as a PNG — that is the entire reason `make render-live` and
`OffscreenRenderer` exist (next section). The README screenshots render in CI
(when a PR is marked ready for review); a local `make screenshots APPROVED=1`
captures the screen, invisibly, and needs the owner's go-ahead like any other
capture. Behaviour that
is not visual belongs in a unit test. If something genuinely can only be
confirmed on a real session — an `NSMenu` tooltip is the standing example,
because NSMenu tracking cannot be exercised off-screen at all — then build it,
test your half headlessly, and **hand over a single prepared run**. Reporting
"this needs you to check" is a complete, acceptable answer.

Prefer making the *app* drive its own check over scripting coordinates from
outside: it knows where its own views are, so there is nothing to guess and
nothing to retry. See `PACER_TOOLTIP_SELFTEST` in `MenuBarTooltipSelfTest` for
the shape — env-gated, self-contained, restores the cursor, exits.

**Make it report a verdict, not a photograph.** That harness took three
authorised runs to produce an answer and all three failures were in the
instrument: it captured the wrong monitor, then a frame with no cursor in it
(`screencapture -C` does not composite the pointer under `-R`), so "the thing
did not happen" and "we never actually did it" looked identical. It only became
useful when it started asking the window server whether a window appeared and
logging where the pointer actually was. Every run costs somebody their machine
for a few seconds — spend the effort up front so one run is enough.

This is written down because it happened: an agent investigating why `.help()`
does not fire inside an `NSMenuItem` built an event-dispatch harness and took
over the cursor while the repo owner was working.

## Non-negotiable correctness rules

These are subtle, easy to miss, and break user-visible numbers:

1. **Cross-file dedup on `${messageId}:${requestId}`.** Resumed sessions
   spawn new JSONL files that replay prior turns. Without dedup, costs
   inflate 2–3× for active users. Sort files by earliest timestamp first
   so dedup is deterministic.
2. **Skip `model == "<synthetic>"`** in every aggregation path.
3. **Stream JSONL line-by-line.** Sessions can be 10MB+; never load whole
   files into memory.
4. **Aggregate from BOTH `~/.config/claude/` and `~/.claude/`** when both
   exist. Don't pick one. `CLAUDE_CONFIG_DIR` is exclusive when set.
5. **Track `cache_creation.ephemeral_5m_input_tokens` and
   `ephemeral_1h_input_tokens` separately.** ccusage does not; we do.
   Required for accurate Anthropic-rate cost calculation.
6. **Defensive parse-or-skip everywhere.** A single malformed line
   (often a truncated final line on a live session) must not break the
   scan.
7. **A repeat `dedupKey` is not automatically a duplicate.** Claude Code
   appends the same assistant message to the transcript several times
   while it streams; only the last copy carries the real `output_tokens`
   and a non-null `stop_reason`. First-wins dedup (ccusage's rule, right
   for *replayed* duplicates) kept the mid-stream snapshot and discarded
   29.5M output tokens — 63% of the output recorded. Precedence lives in
   `ParsedUsageEntry.supersedes`: finished message first, else larger
   output. Do not "simplify" it back to skip-on-seen. See
   `docs/duckdb-archive.md`.
8. **Verify ingest changes against a REAL store, not a synthetic one.**
   Both performance bugs and the dedup bug above were invisible on a
   fresh in-memory store — an empty store has nothing to upgrade and no
   cursors to rewrite. Freeze a copy of a real `~/.claude`, point at it
   with `CLAUDE_CONFIG_DIR`, and run `PACER_COLD_START_PROBE=1` (see
   `App/Background/ColdStartProbe.swift`), which reports phase timings
   AND all six per-field token totals. Row count alone proves nothing
   about field mapping — a swapped cache tier leaves every count
   identical while changing everyone's cost.
9. **Never match a rate-limit cycle with `resetsAt ==`.** The server
   re-serializes `resets_at` per response and it jitters in the
   milliseconds — one 7-day cycle carries thousands of distinct reset
   instants. Cycle membership goes through `RateLimitCycle.contains`
   (within half a window, `nil` counts as in-cycle), which both
   `RateLimitSample.inCycle` and `UsageLimitSample.inCycle` call.
   Exact equality matches ~1 row and collapses a chart to a single dot.

## What NOT to do

- **Do not take over the cursor, the windows, or the focus.** Own section
  above; it is the one rule here with no exceptions.
- **Do not auto-write to `~/.claude/settings.json`** without explicit
  user confirmation per write. Coordination with `ccstatusline`,
  `claude-hud`, etc. depends on a "watch + notify + offer" UX, not silent
  re-injection.
- **Do not bundle `bun`, `node`, or `ccusage`.** The whole point of the
  Swift port is to own the parsing and ship a small native bundle.
- **Do not rely on `~/.claude/stats-cache.json` for primary data.** It
  lags by hours and has fewer categories than JSONL. Use only as a
  sanity-check probe.

## Look at the UI yourself — `make render-live`

Pacer can render its own cards, against the real store, to PNGs:

```sh
make render-live                 # all-accounts plus every account
make render-live SCOPES=all      # or name scopes explicitly
```

They land in `screenshots/live/` (gitignored) and an agent can open them. Use
this before asking a human whether something looks right — several rounds of
"does this look wrong to you?" in the account work could each have been one
render and a look. It found two things no amount of reading the code would
have: a `5-HOUR · SOMEBODY@EXAMPLE.COM` heading wrapping onto three lines,
and a card confidently reporting "a quiet Friday so far" on the account's
biggest day.

It is **not** `make screenshots`. That one seeds synthetic data because its
output ships in the README; this one shows what the user is actually seeing.

This is also the *only* sanctioned way to look at the UI. Rendering off-screen
is not a convenience over driving the real window — driving the real window is
forbidden (see "Never take over the machine"). If a page you need is not in
`LiveRenderMode.Page`, add a case; that is a one-line change and it is how
Settings got there.

Three things it does so you do not have to remember them, all in
`LiveRenderMode` and `bin/dev-render-live.sh`:

- **Read-only store.** A second process writing the live store while the app
  runs is not something to discover later.
- **`.prohibited` activation policy.** It runs as a second process of the *same
  bundle* beside the app the user is working in. With `.accessory` macOS still
  treats it as an activatable instance — launching it pulled the real window
  onto the active Space and left it out of place. `.prohibited` cannot activate
  at all.
- **The real app is re-opened on the way out**, on success, failure or Ctrl-C.

The view scope is set *ephemerally* while walking scopes — `UsageScope.select`
persists to App Group defaults, which the running app reads, so walking scopes
with it would leave the user's dashboard on whichever account the render
stopped at.

## UI components live in PacerUI — check before you build one

**Before writing any view that shows something the app already shows
somewhere, search `PacerCore/Sources/PacerUI/` for it.** If it exists, use it.
If it nearly exists, extend it. Only write a new one when nothing fits, and
put that new one in PacerUI if a second screen could plausibly want it.

This is not a tidiness preference. Two hand-rolled copies of the same thing do
not merely look different, they *disagree*: the Tokens settings account row and
the dashboard's Accounts card both showed 5h/7d utilisation, and the settings
copy carried its own colour thresholds (`>=85` red, `>=50` orange, else green)
against `UsageBand`'s canonical mapping (`<50` green, `<75` yellow, `<90`
orange). 60% rendered orange on one screen and yellow on the other — the same
number, two answers, depending which screen you were on. Nobody decided that;
it is just what happens to a copy.

Rules that follow from it:

- **Never re-derive a mapping that exists in `PacerCore`.** `UsageBand`,
  `PaceBand`, `PacerModelPalette`, the project colour hash — these are the
  definition, not a suggestion. A local `if pct >= 85` is a bug in waiting.
- **A shared component takes a plain value, not a model type.** `PacerAccountRow`
  takes its own `Model` struct rather than `Account` or `AccountStatusSummary`,
  because the moment a third caller holds neither, a component typed on one of
  them stops being shareable and gets copied instead.
- **Give it a trailing slot rather than a mode flag.** Screens differ in what
  they put on the right (an Active badge, a Switch button, a turn count); a
  `@ViewBuilder` slot absorbs that without the component growing branches.
- **Extending a shared component changes every caller.** That is the point, and
  it also means a visual change needs the same sign-off any shared view does —
  flag it, don't slip it in as a side effect of unrelated work.

## Conventions

- Bundle ID: `com.ericandrechek.pacer`. App Group: `YZXWMJ5VBY.com.ericandrechek.pacer`
  (TeamID-prefixed; the legacy `group.` prefix triggered the Sequoia
  App Management prompt — see `docs/research/tcc-app-management.md`).
- Source paths in commit messages: `Component/File.swift:NN` style for
  navigation.
- Comments: explain *why*, not *what*. Especially load-bearing for
  decisions where Pacer deviates from ccusage (e.g. cache-tier split,
  Anthropic OAuth fallback) — leave a comment so the next reader doesn't
  "fix" it back.

## Opening and landing pull requests

- **Open every PR as a draft** (`gh pr create --draft`) once the work is
  pushable. CI runs on drafts.
- **Mark it ready only on the owner's go-ahead to ship.** Marking it ready runs
  `.github/workflows/screenshots.yml`, which renders the README images on a
  `macos-26` runner and pushes a `docs: regenerate README screenshots` commit
  onto the PR branch — the owner reviews that commit before anything merges.
- **Merge only after that review**, and always squash. A commit pushed by the
  workflow's token triggers no CI run of its own; `main` is unprotected, so this
  does not block the merge, but say so when asking.
- **Keep personal details out of commits and comments** — monitor layouts and
  coordinates, usernames, real paths. The repo is public.
- **Mind the free runners' space.** No artifacts from new workflows (the
  screenshots workflow's output is its commit), and no new caches without a
  reason — reuse `prepare-build`'s.

## Reviewing pull requests

- **Always pull a PR into an isolated worktree with `wt`** — never check
  it out over your working tree. Use the [`wt`](https://worktrunk.dev)
  CLI:

  ```sh
  wt switch pr:7          # fetches PR #7, creates ./.worktrees/<branch>, cds in
  ```

  Worktrees keep the PR's build artifacts, generated `Pacer.xcodeproj`,
  and any local fix-ups from polluting `main`, and let the installed
  `/Applications` app come from exactly one branch at a time.

  **Worktree lifecycle.** Create with `wt` and remove when done:
  - **Create:** `wt switch --create <branch>` or `wt switch pr:N`. The project
    hook (`.config/wt.toml`) copies the gitignored DuckDB framework in first,
    only what `.worktreeinclude` names, reflinked (no extra disk). If a
    worktree didn't come from `wt` (Claude Code's own, a plain `git worktree
    add`), `make verify` / `make app` / `make install` run `make vendor`, which
    clones or builds it. Don't copy it in by hand after a failed build: Xcode
    caches the missing framework in `Build/`, and `make vendor` clears that.
  - **Remove:** a worktree that has built is ~1–2 GB (`Build/` plus
    `PacerCore/.build`). When its PR is squash-merged, `wt remove <branch>`.
    `make prune` sweeps every worktree and branch already merged into `main`
    (squash merges included, older than a day).
  - **Subagents** get `wt` worktrees too, not the Agent tool's
    `isolation: "worktree"`. Claude Code only cleans those up when the agent
    changed nothing, which is how 14 stale ones built up.

- **Verify before merging — build *and* run it.** `make test` +
  `make verify` is the floor; `make install` and watch `make logs` is the
  bar. Two classes of bug only show up when you actually run the branch:
  - **Build-path drift.** Xcode's product dir under `-derivedDataPath`
    is version-dependent (`<ddp>/Products/Debug` vs
    `<ddp>/Build/Products/Debug`). Resolve the bundle by its
    `*/Products/Debug/Pacer.app` suffix, never a hardcoded nesting — a
    path that works on the contributor's toolchain can break on yours.
  - **Keychain v1/v2 compat.** Confirm the OAuth poller logs
    `[OAuthPoller] ok …` after install — that proves the live keychain
    read still works. The reader tries `-a NSUserName()` (Claude Code
    2.x per-user item) first and falls back to no-acct only on
    `errSecItemNotFound`, so v1 (`acct=""`) installs keep working.

## App target — what's where

The SwiftUI app is organized like this (under `App/`):

```
App/
  PacerApp.swift                — @main scene graph (single Window + commands).
                                  Wires the AppDelegate via @NSApplicationDelegateAdaptor and
                                  reads container/exports from it. Help-menu replaced with
                                  "Show Database in Finder" / "Open Logs Folder" so users
                                  have somewhere to look when something goes wrong.
  ContentView.swift             — NavigationSplitView shell (Dashboard / History / Projects /
                                  Models / Settings), ⌘1..⌘4 keyboard shortcuts. Selection
                                  persisted via @SceneStorage. .navigationTitle +
                                  .navigationSubtitle expose current rate-limit % to the
                                  window title bar / Dock. .toolbar hosts a freshness
                                  pill on the trailing edge (sidebar header is
                                  brand-only).

  Background/
    PacerAppDelegate.swift      — NSApplicationDelegate. Owns the SwiftData container, the
                                  AppBackgroundService (in-process scan + OAuth poller),
                                  Dock-icon visibility (.regular when window open,
                                  .accessory otherwise), AND the menu-bar NSStatusItem
                                  (custom rather than SwiftUI's MenuBarExtra so we get
                                  right-click context menu, popover hosting, and pulse
                                  animation). Redirects stderr to
                                  ~/Library/Logs/Pacer/Pacer.err.log so Log.write output
                                  survives non-terminal launches. Posts a "Pacer paused"
                                  banner from applicationShouldTerminate. Container open
                                  failure surfaces an NSAlert pointing at the store / logs
                                  rather than a silent fatalError crash.
    AppBackgroundService.swift  — In-process background data collector. Constructs and
                                  runs ScanCoordinator (FSEvents JSONL scan + OAuth polling
                                  + SwiftData persistence) inside the app process.
                                  start() is idempotent; stop() is awaited from
                                  applicationShouldTerminate so saves flush before exit.

  Settings/
    PacerSettings.swift         — App Group UserDefaults wrapper + enum types for menu bar
                                  style/icon and notification thresholds. Single source of
                                  truth for prefs across all targets.

  Notifications/
    NotificationCoordinator.swift — UNUserNotificationCenter wrapper. Posts banners on
                                    each rate-limit threshold crossing the user has
                                    configured (50/75/90 etc., per window) and on the
                                    daily-cost ceiling. Cycle dedup keys include the
                                    threshold value so each threshold can fire once per
                                    cycle without re-firing.
    NotificationsHost.swift     — invisible View under ContentView that holds @Query
                                  subscriptions and dispatches to the coordinator on
                                  upward crossings. Seeds lastSeen* on appear.

  Export/
    CSVExporter.swift           — three flavors (daily totals / daily by model / project
                                  totals). RFC 4180 escape, NSSavePanel, NSAlert on error.

  Views/
    DashboardView.swift         — header + WelcomeCard + Today + LiveActivity + PaceChart +
                                  DailyCost + PerModelToday.
    HistoryView.swift           — Lifetime + Heatmap + Monthly + TopDays. Sheet to DayDetail.
    ProjectsView.swift          — range picker + search + Top-5 donut + full list. Sheet to
                                  ProjectDetail.
    ModelsView.swift            — range picker + token-share donut + per-date stacked trend
                                  chart + full per-model table.
    SettingsView.swift          — Settings as a main-window tab — flat sectioned form with
                                  General, Menu Bar, Notifications, Cost, Storage. About
                                  lives in the application menu (CommandGroup
                                  .appInfo → orderFrontStandardAboutPanel) — native
                                  NSPanel rather than a Settings tab. Reachable via Cmd+5
                                  or Cmd+, (which posts `.pacerOpenSettings` and
                                  ContentView flips the tab).

    MenuBarContent.swift        — MenuBarLabel (SwiftUI view rendered into the
                                  NSStatusItem.button via NSHostingView, with tooltip,
                                  pulse animation on threshold crossings, palette-rendered
                                  SF Symbol band coloring) + MenuBarContent (popover —
                                  pace columns, today's totals, hover-state footer
                                  buttons). PacerAppDelegate hosts both; right-click on
                                  the status item shows a native NSMenu (Open Pacer /
                                  Settings / Quit) instead of the popover.

    Components/
      CircularGauge.swift       — donut + percentage primitive used by PaceChart, MenuBar,
                                  widgets. Color from UsageBand.

    PaceChartCard.swift, TodaySummaryCard.swift, DailyCostChartCard.swift,
    PerModelTodayCard.swift, LiveActivityCard.swift, TodayTimelineCard.swift,
    HeatmapCard.swift, DayDetailView.swift, ProjectDetailView.swift,
    WelcomeCard.swift  — dashboard cards.
```

`Widgets/` holds three real widgets (TodayCost / PaceGauges / DailyChart) bundled by
`PacerWidgetsBundle.swift`. Each widget has its own `TimelineProvider` that reads the
shared SwiftData container directly — no IPC.

## macOS versions, SDKs, and appearance

Pacer supports **macOS 15.0 and up**. That is the deployment target in
`project.yml`, it does not move, and one binary serves every supported
release — the macOS 27 SDK's own floor is 13.1, so building against a new SDK
never drops an old OS.

**The SDK you build with decides the app's appearance; the OS it runs on does
not.** macOS applies Liquid Glass only to binaries linked against the macOS 26
SDK or later, so a build made with Xcode 16 keeps the older look even on
macOS 27. This is the usual linked-on-or-after gate, and it is why Pacer still
renders the pre-Liquid-Glass design: CI and `release.yml` both run on
`macos-15` runners.

Consequences worth knowing before you touch a build setting:

- **Local `make install` on a Mac with only Xcode 26/27 produces a Liquid
  Glass build**, which will not match the released DMG. "Looks right on my
  machine" stops implying "looks right for users" — check which SDK you built
  with (`defaults read /Applications/Pacer.app/Contents/Info.plist DTSDKName`)
  before trusting a visual review.
- **There is no opt-out once you build with the 27 SDK.**
  `UIDesignRequiresCompatibility` is ignored from that SDK on. Staying on the
  older appearance means building with an older Xcode, not setting a key.
- **`docs/screenshots/` ships in the README**, so regenerate it from a build
  whose SDK matches what releases use, or the README shows chrome users do not
  have.

### macOS 26+ behaviour changes already hit

Both were invisible to review and to CI, and both were found by rendering the
same scenes on each SDK and diffing:

- **`URL` directory-ness is now decided by the filesystem.**
  `contentsOfDirectory(at:)` and even `standardizedFileURL` may return a
  directory URL *with* a trailing slash where macOS 15 returned it without.
  `path` is unchanged, but `URL ==` compares `absoluteString`, so the same
  directory can compare unequal depending only on how the URL was built. Never
  compare or key on a bare directory `URL` — use `URL.canonicalPathURL`.
- **`AxisMarks(values:)` is not honoured on a categorical (band) axis.** Every
  band gets a mark, so a 90-day trend renders 90 overlapping labels. Decide in
  the label content instead — `PacerDateAxis.labelIfMarked(_:)`. Continuous
  (e.g. `Int` hour) axes still honour `values:`.

## Project layout & build

- `project.yml` is the source of truth — `Pacer.xcodeproj` is generated
  by XcodeGen and gitignored. Run `xcodegen generate` after edits.
- Targets:
    - `App/` → `Pacer.app` (SwiftUI app, embeds widgets, hosts the
      in-process scan + OAuth poller via `AppBackgroundService`)
    - `Widgets/` → `PacerWidgets.appex` (widget extension)
    - `PacerCore/` → local Swift package (models, parsers, store,
      `LoginItemController` wrapping `SMAppService.mainApp`)
- Each non-package target has its own `.entitlements` file declaring the
  shared App Group `YZXWMJ5VBY.com.ericandrechek.pacer`. The App Group
  lets the app and widgets share a single SwiftData container at
  `~/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/pacer.sqlite`.
- Local PacerCore tests: `cd PacerCore && swift test`.
- Full build verification (no-sign): `xcodebuild ... CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`
  (see README for the full invocation).
- Local dev runs through Xcode with the user's own team selected.

## Team IDs and signing

Pacer ships from `YZXWMJ5VBY` (Eric Andrechek's Apple Developer team). The
Developer ID Application cert under that team signs every release build;
the same Team ID prefixes the App Group identifier
(`YZXWMJ5VBY.com.ericandrechek.pacer`) so the macOS Sequoia App
Management prompt stays quiet (see `docs/research/tcc-app-management.md`).

If you're building Pacer from source under a different Apple Developer
account, you'll need to replace `YZXWMJ5VBY` in `project.yml`,
`App/Pacer.entitlements`, `Widgets/PacerWidgets.entitlements`, and
`bin/dev-install.sh`'s `SIGN_IDENTITY` with your own Team ID, and
re-create the App Group + Developer ID Application cert in App Store
Connect. `xcodebuild` resolves provisioning through Xcode's
`-allowProvisioningUpdates` flag, which the install scripts pass.

## Build, test, and verification commands

Fast inner loop while iterating on PacerCore:
```sh
cd PacerCore && swift build && swift test     # or: make test
```

Verification build (regenerates Xcode project, unsigned compile-only):
```sh
make verify
```

Full signed install — the user's daily-driver path. Use this whenever
you've made changes the user will want to actually run:
```sh
make install
```

`make install` is idempotent: it quits the running Pacer.app GUI (so
the in-memory binary releases the bundle), regenerates the Xcode
project from `project.yml`, builds with signing, notarizes via
`xcrun notarytool`, staples the ticket, replaces
`/Applications/Pacer.app`, boots out any leftover legacy daemon
LaunchAgent (from before the single-binary refactor), and re-opens
Pacer.app if it was running before — so the user lands back on the
new binary without a manual quit/reopen. `make reinstall` preserves
GUI state across the uninstall→install boundary the same way.

Pacer is a single-binary agent: there is no separate daemon binary
or LaunchAgent. Data collection runs inside the app process via
`AppBackgroundService` and starts from
`PacerAppDelegate.applicationDidFinishLaunching`. To run at login,
the user toggles "Open at Login" in Settings → General, which
registers via `SMAppService.mainApp`.

`make help` lists every target. The ones you'll reach for most often:

| Target | When to use |
| --- | --- |
| `make install` | After code changes that should reach the user. |
| `make logs-tail` | First check when something feels off — last 100 app log lines. |
| `make status` | Full diagnostic snapshot (app present, app PID, store size, recent logs). |
| `make reinstall` | When something feels wedged (uninstall + install). |
| `make verify` | Fastest "does this compile" — no signing, no install. |
| `make test` | PacerCore Swift Testing run. |

Logs at `~/Library/Logs/Pacer/Pacer.err.log` — read this directly
when debugging. PacerCore.Log writes to stderr; the AppDelegate
`freopen`s stderr to that file early in init so log lines survive
non-terminal launches (Finder, SMAppService at-login). SwiftData store
at `~/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/pacer.sqlite`.
Both survive `make uninstall`; only `make clean-data` removes them
(and it prompts).

### When `make install` is wrong

- **Pure PacerCore work** (parser, persister, calculator) — `make test`
  is faster feedback. Only run `make install` when you're done.
- **UI-only work in `App/Views/`** — `make verify` confirms it
  compiles; the user will see the change next time they run
  `make install` (which you should run before claiming the change is
  done, since the App Group entitlement matters).

### Run-at-login

Pacer registers the *app itself* for login-launch via `SMAppService.mainApp`
(see `PacerCore/LoginItem/LoginItemController.swift`). The user
toggles this in Settings → General → "Open Pacer at Login". Pacer
never auto-registers; the toggle is the only path. First-time
registration prompts the user to approve in System Settings → Login
Items & Extensions.

There is intentionally no separate daemon binary or LaunchAgent.
Data collection runs inside the app process; if the user wants
collection while logged in but not actively using Pacer, they keep
"Open at Login" on and let the LSUIElement-hidden agent run. The
agent stays alive after the last window closes (see
`applicationShouldTerminateAfterLastWindowClosed` returning false).

`bin/dev-install.sh` boots out any leftover legacy daemon LaunchAgent
(`com.ericandrechek.pacer.daemon.dev` or `com.ericandrechek.pacer.daemon`)
and removes the old plist on every install — the migration is
automatic for users coming from the prior daemon-based architecture.

### Why we do not use the Xcode project's signing flags from CLI directly

`project.yml` sets `DEVELOPMENT_TEAM: YZXWMJ5VBY` (the Developer ID team
that ships releases) but a developer's local Apple Development cert may
live under a different cert team. `xcodebuild` resolves this through
Xcode's `-allowProvisioningUpdates` flag, which the install scripts
pass. Don't try to work around signing with `CODE_SIGN_IDENTITY=""` for
the install flow — that produces an unsigned bundle that macOS refuses
to launch and that can't access the App Group container.

### Real-run bugs the test suite cannot catch

These came up the first time the app actually ran from `/Applications`
under launchd / from-Finder; the test suite stayed green through all
of them. Mentioned here so future agents don't repeat them:

1. **FSEventStream needs `kFSEventStreamCreateFlagUseCFTypes`.** The
   callback's path data is a `char**` by default; treating it as an
   NSArray crashes inside fast-enumeration. Tests use `.manual`
   watcher mode so they never see this. The flag is set in
   `FSEventStreamWrapper.start`; don't remove it.
2. **`Bundle.module` requires the resource bundle next to the
   executable.** Xcode auto-copies `PacerCore_PacerCore.bundle` into
   `Pacer.app/Contents/Resources/` for the .app target. Tool/extension
   targets that link PacerCore (e.g., `PacerWidgets.appex`) need the
   bundle next to *their* binary too — Xcode handles widget extensions
   automatically, but if you add another non-app target that links
   PacerCore, copy the bundle yourself or `Bundle.module` will
   fatalError on first pricing access.
3. **A scan loop that re-reads the active JSONL on every FSEvent will
   peg CPU and silently fail to write new data.** Without per-file
   byte-offset cursors (`JSONLFileCursor`), every line Claude Code
   writes triggered a ~10s rescan that re-parsed hundreds of existing
   lines and re-loaded every TokenSample dedup key. Tests scan static
   fixtures once each, so they never see the loop. The fix is in
   `JSONLScanner` (chunked reads from a saved offset) plus a hoisted
   long-lived `SamplePersister` in `ScanCoordinator`. Don't reintroduce
   per-cycle persister construction or whole-file re-reads.
4. **Unbounded `@Query` results murder the in-process scan loop.**
   With data collection in the app process, every SwiftData save
   fires @Query refreshes on the same MainActor that the scan loop
   runs on. A 40k-row materialization on each save turned a 200ms
   scan into a 6-minute one. Always set `fetchLimit` (or a tight
   predicate) on `@Query<TokenSample>` reads — `WelcomeCard`,
   `DashboardHeader`, and `LiveActivityCard` use a static
   `FetchDescriptor` with `fetchLimit` set; follow that pattern for
   any new card that just needs a recent sample or "is the table
   non-empty" probe.

   For views that legitimately need to *aggregate* across many
   TokenSamples (Projects, ProjectDetail, History, Today's hour
   timeline, Live activity burn rate), don't iterate raw samples in
   body — even off-main-thread iteration of 30k rows is hundreds of
   ms of wall-clock latency on every scan tick. The pattern is:
   precompute a view-ready rollup table, maintained by the in-process
   scan's recomputer in the write path, keyed by the dimension the
   view groups on. We have four:
   `DailyAggregate` (date × model) — backs Today / DailyCost /
   History / Models; `HourlyAggregate` (date × hour × model) —
   backs `TodayTimelineCard` (24-bar hour-of-day chart) and
   `LiveActivityCard` (last-hour burn rate);
   `ProjectDailyAggregate` (project × date) — backs Projects /
   ProjectDetail's summary, daily series, models donut, and
   DayDetailView's per-project breakdown; and `SessionInfo` (per
   session) — backs ProjectDetail's sessions list. Add another
   `@Model` + recomputer if a future view needs a new grouping.
   Views then just `@Query` the small precomputed table and group
   in the body — sub-10ms over hundreds of rows. Don't add a
   `RollupWorker`-style background actor on top of a precomputed
   table; the actor was a transitional half-measure, removed once
   every view had its own rollup.

   Recomputers are wired into `ScanCoordinator.runScanCycle` in this
   order: `AggregateRecomputer` → `HourlyAggregateRecomputer` →
   `ProjectAggregateRecomputer` → `SessionInfoRecomputer`, all
   reading the same `dirty*` sets the `SamplePersister` collected
   during inserts. None of them call `context.save()` themselves on
   the per-pair (main-context) path; the cycle's terminal save in
   `ScanCoordinator` commits everything (cursors + meta + every
   recomputer's changes) in one shot. That collapses steady-state
   cycles to 1-2 saves/cycle, which halves the `@Query` re-fire
   fan-out on every scan tick.

   Each recomputer has a per-pair main-thread path (used for
   incremental scans, ≤64 dirty entries) and a bulk
   `@ModelActor`-backed background path (used for backfill,
   thousands of dirty entries). The bulk path owns its own
   `ModelContext` on a non-MainActor actor, fetches everything
   once, groups in memory, upserts, then saves through that
   context — SwiftData fans the committed changes out to the
   MainActor `@Query` subscribers automatically. The bulk path
   commits the main context first so its own fetches see any
   in-flight inserts; that's a one-extra-save cost on first
   install and zero in steady state. Bulk paths also `await
   Task.yield()` every 32 pairs/ids as a small extra responsiveness
   hedge.

   The `consumeMissing*` recovery paths on `SamplePersister` are
   the bootstrap for newly-added rollup tables: on first scan after
   a schema bump, every existing TokenSample's (date, model) /
   (date, hour, model) / (project, date) / sessionId is folded into
   the dirty set and the recomputer rebuilds the table. One-shot;
   subsequent cycles see no gaps. When adding a new rollup, wire a
   matching `consumeMissing*` + `addDirty*` pair so users upgrading
   from a build without the table get a one-cycle bootstrap.

   See the **Performance — invariants and patterns** section below
   for the full set of read-path rules the rollup tables are just
   one piece of (query scoping, fetchLimit, indexes, body work,
   widget container reuse).
5. **macOS Sequoia 15+ App Management prompt — RESOLVED 2026-05-07.**
   The fix was the App Group identifier format, not the architecture.
   Sequoia gates the legacy `group.<bundleid>` prefix; the modern
   `<TeamID>.<bundleid>` form is exempt. Pacer's old App Group was
   `group.com.ericandrechek.pacer`; renaming to
   `YZXWMJ5VBY.com.ericandrechek.pacer` (Team ID `YZXWMJ5VBY`) eliminated
   the prompt while keeping widgets and the App Group container.

   Confirming evidence: every non-prompting app on the user's machine
   (iTerm `H7V7XYVQ7D.iTerm`, Stats `RP2S87B72W.eu.exelban.Stats.widgets`,
   Raycast `SY64MV22J9.com.raycast.macos.shared`,
   OrbStack `HUAQ24HBR6.dev.orbstack`) uses the TeamID-prefix format.
   The prior "Service Policy" diagnosis was correct as a symptom but
   missed that the policy *is* keyed on the identifier prefix. The
   3-hour signing/notarization deep-dive in
   `docs/research/tcc-app-management.md` documents what was tried
   (everything except renaming the App Group itself).

   `bin/dev-install.sh` does a one-shot copy of `pacer.sqlite` (+ WAL/SHM)
   and the UserDefaults plist from the legacy container path to the
   new path between "quit old app" and "install new app", so existing
   dev installs upgrade transparently.

**Trust `swift build` and `swift test`, not SourceKit diagnostics.**
Real Swift 6 compile errors are flagged by the build. SourceKit's IDE
diagnostics frequently complain "Cannot find type X in scope" right
after writing new files — these are stale indexing artifacts and
resolve on the next build. Don't chase ghost errors.

## Swift 6 patterns proven during M1/M2

These caught us during the build; document so the next agent doesn't
relearn:

1. **`ISO8601DateFormatter` is not Sendable.** Apple documents
   `.date(from:)` as thread-safe, so using a static instance is fine —
   declare it `nonisolated(unsafe) private static let formatter = ...`
   to silence the strict-concurrency error. Don't allocate per call;
   the historical scan parses hundreds of thousands of timestamps.

2. **`FileManager.DirectoryEnumerator.makeIterator()` is unavailable
   from async contexts.** Drain to an array synchronously in a
   `nonisolated` helper before the async loop:
   ```swift
   while let next = enumerator.nextObject() as? URL { urls.append(next) }
   ```
   `for case let url as URL in enumerator` from an async function
   won't compile.

3. **`Dictionary(uniqueKeysWithValues:)` crashes on duplicate keys.**
   When deriving lookup tables from external data (LiteLLM has
   case-collisions like `together_ai/baai/bge-base-en-v1.5` appearing
   twice), use `Dictionary(_:uniquingKeysWith:)` or just don't
   pre-build the dict — at 2700 entries, a linear scan is fast enough.

4. **Per-entry decoding for messy JSON dictionaries.** LiteLLM's
   pricing JSON has a `sample_spec` doc entry where numeric fields are
   strings ("LEGACY parameter..."). A whole-dict `JSONDecoder.decode`
   would reject every model. Pattern: `JSONSerialization.jsonObject`
   for the top-level shape, then re-encode each value to `Data` and
   try-decode with `JSONDecoder` per entry, dropping failures
   silently. ccusage does the same.

5. **Closures passed to `@Sendable` async APIs can't mutate captured
   locals under strict concurrency.** Either accumulate in an actor or
   refactor the API to return values (or stream via `AsyncStream`).
   We may want to give `JSONLScanner` an `AsyncThrowingStream` API in
   addition to the callback form so consumers can iterate naturally.

## SwiftUI state and data flow — how updates actually happen

Read before adding any `@State`, binding, sheet, modal, cached value, reload
signal or `ModelContext` use. Sources and the evidence for each rule are in
`docs/research/swiftui-state-apple-guidance.md`.

**Why this section exists.** Clicking a project or a History day set the
page's `@State modalRoot`, and the detail appeared only when something
unrelated redrew the page. For months that was a second or two, because
scans and saves redrew most of the app constantly, so it read as "lag". When
the 2026-09 perf work removed the incidental redrawing it became 45 s. An
audit then found about twenty more places that only worked because something
else redrew them. **Anything that only updates because something else happens
to redraw is a bug, and removing redraw work is what exposes it.**

### The rule Apple documents: a view updates only on what its own `body` read

SwiftUI records a dependency when a view's `body` *executes a getter* — reads
the value. Declaring, holding or passing a value records nothing. Passing
`$x` down records nothing either. A write marks only recorded dependents
dirty. If nothing read the value, the write schedules nothing, and the new
value shows up the next time something unrelated re-runs that `body`.

- **State that must change what is on screen is read, by value, in its
  owner's `body`.** Don't rely on a read inside a `ViewModifier`'s body
  reached through a `Binding`. The first modal fix did exactly that, and the
  modal still took 43 s. Apple has filed bugs of this shape. The pattern that
  works is `.pacerModalNavigation(modalRoot, root: $modalRoot)`: the page
  reads the value and passes it in as a plain input, and the binding is only
  for writes.
- **A read belongs to whichever `body` executes it.** A read inside an
  escaping content closure that another view stores and calls later
  (`PageScaffold`'s content, `List` / `LazyVStack` rows, sheet and overlay
  content) makes *that* inner view depend on the value, not the page.
  History and Projects put their whole body inside `PageScaffold`'s closure.
- **A `ViewModifier` is not a safe place to be the only reader** of state
  its caller owns. Pass the value in.

### Every cached value needs an explicit trigger for every input

`@State cached…` refreshed only by `.onAppear` plus the scan-meta tick is
stale whenever an input changes without a scan: scope or account switch, cost
mode, range, day rollover, a poll for a non-active account. List every input
the cache derives from, and give each one an `.onChange` or a `.task(id:)`
key. `DailyCostChartCard` and `ProjectsView` show the scope case. An idle
machine is the test: switch scope with Claude Code quiet, and see whether
every card follows.

### Reload signals change on every write

A signal a view keys a reload on must change on *every* relevant write.
Increment a generation counter. A max timestamp misses rows older than the
newest (archive folds, restamps). Truncating it to whole seconds collapses
two writes in the same second. A notification posted only for the active
account misses the others. `RateLimitWriteSignal` is the rate-limit one; the
view must read it in `body`.

### Identity

- `if` / `else` / `switch` branches are distinct identities, including a
  branch around a modifier. Toggling resets `@State` below it and cancels
  in-flight interactions. Prefer changing a modifier's value
  (`.opacity(c ? 0.5 : 1)`) over branching the view.
- `.id(x)` tears the subtree down when `x` changes. Know what that closes:
  `ContentView`'s `.id(dayKey)` closes an open modal and clears the Projects
  search at midnight.
- No `AnyView` in `ForEach` / `List` rows. It forces every row to be built.
- `.equatable()`: `==` must cover every input that changes the output,
  or the view silently stops updating.

### Reference types, sheets, and mutation

- A plain (non-`@Observable`) class held in `@State` and mutated in place
  **never** updates the view. The only acceptable use is a render-time memo
  that nothing displays. `FirstRenderMemo` is one, and says so.
- Don't mutate state while `body` runs. Defer it to an action, `.task` or
  `.onChange`.
- **Sheets:** `.sheet(item:)` with one `Identifiable` request that carries
  every input. Not `isPresented` plus separate `@State` inputs, which the
  sheet closure captures stale.
- `@Observable` models and singletons that views read are `@MainActor`, and
  are only mutated on the main actor.

### SwiftData facts that shape the architecture

- **`@Query` re-fetches on every save of its context**, whatever changed.
  Apple DTS has confirmed it. That is why always-mounted surfaces (menu bar,
  toolbar, `NowStrip`, `NotificationsHost`) must not hold `@Query`s as
  change signals. Use `RateLimitWriteSignal` or the scan notification.
- **Nothing documents that a save in one `ModelContext` reaches another
  context's `@Query`.** Forum reports are inconsistent and OS-dependent.
  Don't rely on it: refresh explicitly from the notification the writer posts
  *after* its save.
- **`propertiesToFetch` may be a no-op.** Two independent SQL-level checks
  found SwiftData still selects every column. This is not yet verified in
  Pacer (run with `-com.apple.CoreData.SQLDebug 1` to check). Until then,
  the dependable levers are a tight predicate and `fetchLimit`.
- `ModelContext` is not `Sendable`. A `Task.detached` has no actor, so
  create its own `ModelContext(container)` inside and return Sendable values.
  A detached task is **not cancelled** with the task that spawned it.
  Coalesce, or check `Task.isCancelled` between batches.

### Proving an interaction fix

An off-screen harness is not proof for a missed-update bug. A self-test that
hosted the real `ContentView` off-screen opened the modal instantly **on the
broken build too**. What does prove it:

- the always-on `[Click]`, `[Navigation]` and `[Modal]` log lines (each
  click's delivery lag, whether its action ran, when the modal opened);
- an `xcrun xctrace record --template 'Time Profiler' --attach <pid>` trace
  across the repro, to see whether the main thread was busy or idle;
- the owner's repro.

Never call an interaction bug fixed on reasoning alone. That happened once
in this incident, and the fix did nothing.

## Performance — invariants and patterns

The view + widget read path hit several hard performance problems during
M1–M5 and they all converged on the same handful of patterns. Every new
view, widget, query, and rollup should follow them. Re-litigating any of
these wastes effort and risks regressing user-visible cost — search the
git log for "Views/Widgets: scope @Query" or "HourlyAggregate" or
"PacerStore + widgets" for the commits that established them.

### Default to scoped fetches; nothing should fetch then filter

- **Always predicate-scope `@Query` and `FetchDescriptor`** to the rows
  the view actually renders. Don't fetch everything and filter in memory.
  Chart cards (`DailyCostChartCard`, `DailyChartWidget`,
  `MonthlyChartCard`) all used to do `fetch-all + .suffix(N)` and were
  materializing 700+ rows per scan tick for charts that show 30.
- **For runtime-variable ranges** (a card with a 7d / 30d / 90d / all
  picker), use the **Card+Content split with `.id(range)`** pattern.
  The outer Card owns the range `@AppStorage` and picker UI; the inner
  Content takes `range` as an init argument and configures the @Query
  predicate accordingly. `.id(range)` on the Content forces re-init
  when the user picks a new window — the only way to bind a runtime
  value into a property-initialized @Query. See
  `HistoryView.LifetimeSummaryCard` / `TopDaysCard` and `ModelsView`.
- **Probe queries get `fetchLimit = 1`.** "Is the table empty?" /
  "what's the latest sample?" checks must cap the fetch. Without it,
  every SwiftData save materializes the whole table just to answer the
  question — see `WelcomeCard`, `LiveActivityCard.latestSampleProbe`,
  `LiveSessionWidget`.
- **A per-item fetch is a bulk-path bug waiting to happen.** An indexed
  lookup per item is the right shape for the handful an incremental
  cycle touches and ruinous for the thousands a full scan does. Two
  places had it, both invisible until run against a real store: the
  dedup upgrade path fetched by `dedupKey` per row (98% CPU, >2 GB
  resident), and `saveCursors` fetched by path per cursor (1,701
  round-trips to avoid reading a 1,701-row table — 33.7 s of a 70 s
  scan). Both now switch to one fetch + a dictionary above a threshold.
  When you add a bulk path, ask what it costs at 100× the item count.
- **Don't re-read the same table once per worker.** All four rollup
  workers fetched the whole sample table into their own `ModelContext`.
  They can't share SwiftData objects (context-bound, separate actors),
  so they share `SampleSnapshot` — a `Sendable` value projection built
  at most once per cycle, lazily, so incremental cycles never
  materialize it.
- **Bound history queries by TIME, not row count.** A `fetchLimit` on a
  series a chart *draws* is a silent cap on how much of that series the
  user can see, and it moves whenever write cadence does. The scoped pace
  line was capped at 600 rows shared across every `limits[]` window; when
  polling went adaptive (~1/min, #120) that became ~3 hours of a 7-day
  cycle and the chart rendered as a stub. Use a cutoff predicate matching
  what's plotted, plus `propertiesToFetch` to keep it cheap; keep
  `fetchLimit` only as a burst backstop, set far above the real volume.
  Compute the cutoff per view init — a `static let` freezes at process
  start and widens the query by a day for every day the app stays open.

### Body work — cache derived values; never iterate raw rows in a view

- **Computed properties re-run on every body pass.** Hover state, sort
  changes, parent re-renders all trigger body re-fires. Anything more
  expensive than O(N=10) belongs in a `@State` cache refreshed via
  `.onChange(of: scanMeta.first?.value)` — the scan-meta tick is the
  canonical "data changed" signal. Pattern in `TodayTimelineCard`,
  `HeatmapCard`, `ModelsView`, `ProjectsView`, `ProjectDetailView`.
- **Never iterate raw `TokenSample`s in a view body.** Always go
  through a rollup. The four rollups (`DailyAggregate`,
  `HourlyAggregate`, `ProjectDailyAggregate`, `SessionInfo`) cover
  every aggregation any production view needs. If you find yourself
  reaching for `@Query<TokenSample>` in a non-modal view, stop and
  ask whether a rollup can answer the question.
- **Cost fields on rollup tables are already mode-applied** by the
  recomputer. Don't call `effectiveCostUSD(mode:)` per row from a
  view body unless you're explicitly working with raw TokenSamples
  (Subprojects card is the one accepted exception — modal-only,
  predicate-bounded to one project).
- **Modal views that need raw samples** (`ProjectDetailView`'s
  Subprojects card) should use a manual `context.fetch` with
  `propertiesToFetch` slimmed to the columns the rollup actually
  reads, scoped tight via predicate, and gated on the relevant scan
  notification (`pacerScanCycleDidComplete` filtered to
  `samplesChanged`) — not @Query, which re-materializes the result
  set on every save.

### Indexes — match every sort and predicate

- **Add `#Index` for any column used in a sort or predicate.** All
  rollup `@Model` types and `TokenSample` have indexes for the
  predicates they're actually queried with; `RateLimitSample` was
  unindexed for nearly a year before we caught that every "most recent
  sample" probe was a full-table scan. SwiftData lightweight
  migration handles index additions cleanly — no `VersionedSchema`
  needed.
- Compound indexes for compound predicates (`(date, model)` for the
  recomputer's per-pair upsert, `(sampledAt, window)` for the
  rate-limit window-filter sweep).

### Widget extension — share one ModelContainer

- **Use `PacerStore.sharedModelContainer()`, not `makeModelContainer()`,
  from widget providers.** Container open is 50–200ms of SQLite open +
  schema validation; doing it per refresh is documented anti-pattern.
  The cached singleton is process-wide within the widget extension.
  The app process keeps using `makeModelContainer()` at startup because
  `PacerAppDelegate` owns container lifecycle explicitly.

### Adding a new rollup table

If a new view legitimately needs a grouping no existing rollup covers,
add a new rollup following the template. The full set of touchpoints:

1. **`@Model` type** in `PacerCore/Sources/PacerCore/Models/` — `@Attribute(.unique)` PK string `"date|model|..."`, `#Index` for every column used in a predicate or sort, columns mirror the rollup's metric needs (tokens, totalCostUSD, sampleCount). Register in `PacerStore.makeModelContainer()`'s schema list.
2. **Dirty-set in `SamplePersister`** — `dirtyXBuckets: Set<...Triple>` populated by `insert(_:)`, also from `markEverySampleDirty()` (cost-recompute version bump), cleared in `clearDirtyPairs()`. Add `addDirtyXBuckets(_:)` for external folding.
3. **Recovery drain** — `missingXBuckets: Set<...>` computed during `preloadFromStore()` as `sampleXBuckets.subtracting(existingRollupXBuckets)`. `consumeMissingXBuckets()` returns and clears, one-shot.
4. **Recomputer** in `PacerCore/Sources/PacerCore/Persistence/` — `@MainActor` class with per-pair path, plus a sister `@ModelActor` worker for the bulk path above the 64-pair threshold. Cost mode + `PricingTable` threaded through both paths; per-entry cost summation (not sum-tokens-then-price; see comment in `AggregateRecomputer` for the ccusage-parity reasoning).
5. **Wire into `ScanCoordinator.runScanCycle`** — drain the missing set into the dirty set, log the recovery line, run the recomputer in the existing sequence, include its stats in `ScanReport` and `cycleDidWork`, add to `formatReport`.
6. **Tests** in `PacerCoreTests/` — single insert→dirty, clearDirty, recomputer single-bucket, multi-bucket, multi-model-within-bucket, upsert-on-second-pass, missing-bucket-bootstrap. Float-cost expects need an epsilon (`abs(actual - expected) < 1e-9`).
7. **Update the in-memory test container** in `PersistenceTests.swift` and `ScanCoordinatorTests.swift` so the new `@Model` registers.

### Anti-patterns that hide behind benign SwiftUI/SwiftData APIs

These all looked innocent in review and were caught only by `sample(1)`
on the live process. Mechanisms are subtle enough that grep won't catch
them — keep this list in mind on any new view/animation/save site.

1. **`.repeatForever(autoreverses:)` in views hosted by `NSStatusItem`.**
   Each frame triggers SwiftUI body re-eval → NSHostingView signals
   content-change to its enclosing NSStatusItem → `_updateReplicants`
   → `cacheDisplayInRect` rasterizes the whole status item to a
   bitmap at 60 Hz. Cost is ~40 % of MainActor as long as the
   animation runs. Removed the `ActivityDot` pulse for exactly this
   reason; if you need a "live" indicator, the dot's mere presence
   already conveys it, or use a `CALayer`-driven animation that
   bypasses SwiftUI's per-frame body re-eval.
2. **`TimelineView(.animation)` in views hosted by `NSToolbarItem`.**
   Even with a fixed external frame and a transform-only effect
   (`.scaleEffect`), each tick rebuilds the SwiftUI subtree →
   NSHostingView size-change signal → `NSToolbarItem _scalableMinSize`
   → AutoLayout pass on the whole toolbar item chain. `FreshnessPulse`
   carried this cost continuously while the main window was open.
   Same workaround if you need animation in a toolbar item.
3. **Per-cycle `FetchDescriptor<X>()` with no predicate.** Even with
   `propertiesToFetch` slimming, materializing a 1000-row table per
   cycle is 70-150 ms under MainActor contention. Cache the dict in
   memory at the first call site, write-through on updates. See
   `ScanCoordinator.cursorsCache` for the pattern.
4. **`await pricingTable.snapshot()` (or any actor hop) on a hot
   recomputer path.** Each hop is ~150 ms under MainActor contention.
   Read `SampleCostCache.current()` instead — process-wide nonisolated
   Sendable snapshot warmed at app launch.
5. **Coalesce timers that yield without checking their buffer.** If a
   concurrent scan can drain the buffer between record time and flush
   time, the yielded trigger fires an empty-buffer cycle → full FS
   walk for nothing. `JSONLWatcher.flushPending` guards with
   `guard !changedPaths.isEmpty` for this reason.
6. **Reading sanity-check / debug-only probes per cycle.** The
   `StatsCacheProbe` and `ProjectGitRootAutoAliaser` both fall in
   this category — they're explicitly documented as "not feeding
   user-facing data" but were running every cycle. Throttle to ≥60 s.
7. **60-second backstop walks during quiet idle.** Modern FSEvents is
   reliable enough that 5-min safety-net cadence is sufficient. A
   ~900-file full walk per minute, times 24/7, is exactly the kind
   of always-on CPU that puts a menu-bar app in the top-10.

### Before adding new view / widget / query code

Ask:
1. Will this fetch fire per scan tick (every 5–60s when active)?
2. Will it materialize more rows than the view actually renders?
3. Is there an existing rollup table that covers the grouping?
4. Should derived values be `@State` cached behind a scan-meta tick?
5. Does any predicate or sort hit an unindexed column?
6. (Widgets) Is this calling `makeModelContainer()` instead of `sharedModelContainer()`?

If you can answer "yes" to (1) and (2), or "no" to (3), or "yes" to (5)
or (6), you're about to add a hot path. Either scope the query, route
through a rollup, add an index, or push the work to a recomputer.

## Engineering standard

The level of paranoia in M1/M2 sets the bar — keep it or raise it:

- **Catch what ccusage missed.** Cache 5m/1h split, deterministic
  dedup ordering, path-union over both legacy + XDG locations,
  defensive parse-or-skip on every line. The `docs/research/` notes
  call out specific things ccusage flattens or skips that we don't —
  preserve those deltas; the comments in code mark them.
- **Validate against ground truth.** `bun x ccusage daily --json` is
  the canonical reference. Whenever a feature surfaces a number, add
  a test that compares to ccusage's output for the same range
  (modulo the cache-tier split deviation).
- **Comments explain *why*, not *what*.** Especially load-bearing on
  decisions where Pacer deviates from ccusage — leave a "we keep this,
  ccusage doesn't, here's why" comment so future readers don't "fix"
  it back.
- **Defensive over clever.** A single bad line in a 10MB transcript
  must never break the scan. Active sessions write concurrently;
  partial last lines are normal. Always skip-and-log, never throw.
- **No backwards-compatibility hacks.** This is a fresh project; if
  a refactor is right, do the refactor cleanly. Don't leave
  `// removed` comments or rename-shim layers.
- **Performance is a first-class invariant, not an afterthought.**
  Every `@Query`, `FetchDescriptor`, computed property, and per-row
  loop in a view body fires on a scan tick. The cost of *each* is
  small; the cost of *not noticing* compounds into the kind of bug
  we already fixed twice (40k-row materializations turning a 200ms
  scan into 6 minutes; 3000-sample per-row `effectiveCostUSD` walks
  per scan tick). Before adding a fetch or a loop in the read path,
  walk through the "Before adding new view / widget / query code"
  checklist in **Performance — invariants and patterns** above. If
  unsure whether a pattern is hot, profile by counting: rows the
  fetch returns × fire rate (scan tick, hover, body re-eval) ×
  per-row work. Anything above ~1ms per scan tick belongs behind a
  `@State` cache + scan-meta tick refresh; anything above 100 rows
  iterated belongs in a rollup.
