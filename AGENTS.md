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
  range, modulo the cache 5m/1h split (we track separately, ccusage
  doesn't).
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

## What NOT to do

- **Do not auto-write to `~/.claude/settings.json`** without explicit
  user confirmation per write. Coordination with `ccstatusline`,
  `claude-hud`, etc. depends on a "watch + notify + offer" UX, not silent
  re-injection.
- **Do not bundle `bun`, `node`, or `ccusage`.** The whole point of the
  Swift port is to own the parsing and ship a small native bundle.
- **Do not rely on `~/.claude/stats-cache.json` for primary data.** It
  lags by hours and has fewer categories than JSONL. Use only as a
  sanity-check probe.

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
