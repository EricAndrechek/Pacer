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
- Reference implementation in Go: `<reference Go implementation>/`.
  ~2,900 LOC covering OAuth/Keychain, JSONL parsing, SQLite schema,
  pace charts, and pricing primitives. The Swift port mirrors this
  closely.

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

## App target — what's where

The SwiftUI app is organized like this (under `App/`):

```
App/
  PacerApp.swift                — @main scene graph (WindowGroup + Settings + MenuBarExtra).
                                  Wires the AppDelegate via @NSApplicationDelegateAdaptor and
                                  reads container/exports from it.
  ContentView.swift             — top-level TabView (Dashboard / History / Projects /
                                  Models / Debug), ⌘1..5 keyboard shortcuts.

  Background/
    PacerAppDelegate.swift      — NSApplicationDelegate. Owns the SwiftData container, the
                                  AppBackgroundService (in-process scan + OAuth poller), and
                                  drives Dock-icon visibility (.regular when window open,
                                  .accessory otherwise). Redirects stderr to
                                  ~/Library/Logs/Pacer/Pacer.err.log so Log.write output
                                  survives non-terminal launches. Posts a "Pacer paused"
                                  banner from applicationShouldTerminate.
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
                                    rate-limit threshold crossings and daily-cost ceiling.
                                    Cycle dedup via ClaudeCodeMeta keys.
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
                                  Startup, Menu Bar, Notifications, Cost calculation,
                                  Storage, About. Reachable via Cmd+5 or Cmd+, (which
                                  posts `.pacerOpenSettings` and ContentView flips the tab).

    MenuBarContent.swift        — MenuBarLabel (status item) + MenuBarContent (popover).
                                  Both honor PacerSettings.

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

## Team IDs

Two certs in keychain (`security find-identity -v -p codesigning`):
- `<REDACTED_DEV_TEAM_ID>` — Apple Development cert for local dev signing
- `YZXWMJ5VBY` — Developer ID Application cert for distribution

`project.yml` currently sets `DEVELOPMENT_TEAM: YZXWMJ5VBY`. If a Debug
build trips on missing provisioning profiles, the user should open the
project in Xcode and let it auto-resolve, or manually flip the team in
the Signing & Capabilities tab. Distribution (M8 Sparkle release) will
use `YZXWMJ5VBY` explicitly with the Developer ID cert.

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

The user's project.yml has `DEVELOPMENT_TEAM: YZXWMJ5VBY` (Developer ID
team for distribution) but the Apple Development cert that's actually
present in the keychain is under a different cert team
(`<REDACTED_DEV_TEAM_ID>`). `xcodebuild` resolves this through Xcode's
`-allowProvisioningUpdates` flag, which the install scripts pass.
Don't try to work around signing with `CODE_SIGN_IDENTITY=""` for the
install flow — that produces an unsigned bundle that macOS refuses to
launch and that can't access the App Group container.

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
   TokenSamples (Projects, ProjectDetail, History), don't iterate
   raw samples in body — even off-main-thread iteration of 30k rows
   is hundreds of ms of wall-clock latency on every scan tick. The
   pattern is: precompute a view-ready rollup table, maintained by
   the in-process scan's recomputer in the write path, keyed by the
   dimension the view groups on. We have three:
   `DailyAggregate` (date × model) — backs Today / DailyCost /
   History / Models; `ProjectDailyAggregate` (project × date) —
   backs Projects / ProjectDetail's summary, daily series, models
   donut; and `SessionInfo` (per session) — backs ProjectDetail's
   sessions list. Add another `@Model` + recomputer if a future
   view needs a new grouping.
   Views then just `@Query` the small precomputed table and group
   in the body — sub-10ms over hundreds of rows. Don't add a
   `RollupWorker`-style background actor on top of a precomputed
   table; the actor was a transitional half-measure, removed once
   every view had its own rollup.

   Recomputers are wired into `ScanCoordinator.runScanCycle` in this
   order: `AggregateRecomputer` → `ProjectAggregateRecomputer` →
   `SessionInfoRecomputer`, all reading the same `dirty*` sets the
   `SamplePersister` collected during inserts. None of them call
   `context.save()` themselves on the per-pair (main-context) path;
   the cycle's terminal save in `ScanCoordinator` commits everything
   (cursors + meta + every recomputer's changes) in one shot. That
   collapses steady-state cycles to 1-2 saves/cycle, which halves
   the `@Query` re-fire fan-out on every scan tick.

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
   (project, date) / sessionId is folded into the dirty set and
   the recomputer rebuilds the table. One-shot; subsequent cycles
   see no gaps.
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
