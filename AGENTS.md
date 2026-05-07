# Agent guide — Pacer

Native macOS Claude Code usage tracker. SwiftUI + SwiftData + Charts.
Five targets sharing data through an App Group. See `docs/design.md` for
the full v1 design.

## Where to look first

- `docs/design.md` — full architecture, data sources, schema, IPC, scope.
- `docs/research/ccusage-reference.md` — ground-truth analysis of `ccusage`
  internals: path discovery, JSONL schema, cost modes, dedup correctness,
  pricing source. Read before touching parsing or cost code.
- `docs/research/realtime-mechanisms.md` — analysis of statusline, hooks,
  OTel, MCP for live Claude Code data.
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

- Bundle ID: `com.ericandrechek.pacer`. App Group: `group.com.ericandrechek.pacer`.
- Source paths in commit messages: `Component/File.swift:NN` style for
  navigation.
- Comments: explain *why*, not *what*. Especially load-bearing for
  decisions where Pacer deviates from ccusage (e.g. cache-tier split,
  Anthropic OAuth fallback) — leave a comment so the next reader doesn't
  "fix" it back.

## Project layout & build

- `project.yml` is the source of truth — `Pacer.xcodeproj` is generated
  by XcodeGen and gitignored. Run `xcodegen generate` after edits.
- Targets:
    - `App/` → `Pacer.app` (SwiftUI app, embeds widgets)
    - `Daemon/` → `PacerDaemon` (CLI tool, LaunchAgent in M3+)
    - `Widgets/` → `PacerWidgets.appex` (widget extension)
    - `PacerCore/` → local Swift package (models, parsers, store)
- Each non-package target has its own `.entitlements` file declaring the
  shared App Group `group.com.ericandrechek.pacer`. The App Group lets
  the daemon, app, and widgets share a single SwiftData container at
  `~/Library/Group Containers/group.com.ericandrechek.pacer/pacer.sqlite`.
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

`make install` is idempotent: it stops any running daemon, regenerates
the Xcode project from `project.yml`, builds with signing, replaces
`/Applications/Pacer.app`, writes a fresh dev LaunchAgent plist at
`~/Library/LaunchAgents/com.ericandrechek.pacer.daemon.dev.plist`, and
boots the daemon via `launchctl bootstrap`. After it returns, the user
can `make open` to see your changes in the running app.

`make help` lists every target. The ones you'll reach for most often:

| Target | When to use |
| --- | --- |
| `make install` | After code changes that should reach the user. |
| `make logs-tail` | First check when something feels off — last 100 daemon log lines. |
| `make status` | Full diagnostic snapshot (app present, daemon PID, store size, recent logs). |
| `make daemon-fg` | Live debug — runs daemon in your terminal so you see crashes/output as they happen. |
| `make reinstall` | When something feels wedged (uninstall + install). |
| `make verify` | Fastest "does this compile" — no signing, no install. |
| `make test` | PacerCore Swift Testing run. |

Logs at `~/Library/Logs/Pacer/PacerDaemon.err.log` — read this directly
when debugging. SwiftData store at
`~/Library/Group Containers/group.com.ericandrechek.pacer/pacer.sqlite`.
Both survive `make uninstall`; only `make clean-data` removes them
(and it prompts).

### When `make install` is wrong

- **Pure PacerCore work** (parser, persister, calculator) — `make test`
  is faster feedback. Only run `make install` when you're done.
- **UI-only work in `App/Views/`** — `make verify` confirms it
  compiles; the user will see the change next time they run
  `make install` (which you should run before claiming the change is
  done, since the App Group entitlement matters).

### Why two LaunchAgent paths exist

Pacer has two parallel ways to run the daemon at login:

1. **Dev launchctl** — label `com.ericandrechek.pacer.daemon.dev`, plist
   at `~/Library/LaunchAgents/`, registered via `launchctl bootstrap`
   from `bin/dev-install.sh`. This is what `make install` sets up.
2. **SMAppService** — label `com.ericandrechek.pacer.daemon`, plist
   embedded at `Pacer.app/Contents/Library/LaunchAgents/`, registered
   via `SMAppService.agent(plistName:).register()` from inside the
   running app (Debug tab → Register button).

`SMAppService` is the modern Apple-blessed path and is what shipped
builds will use. It can't be the dev path because:

- `SMAppService.agent.register()` must be called from inside the
  running app process — not invokable from a shell script.
- First-time registration triggers a System Settings → Login Items
  approval prompt. Fine for end users, friction for an AI dev loop
  that runs `make install` repeatedly.
- The state machine has a `requiresApproval` failure mode after
  signature drift, requiring an explicit unregister + re-approve.

The `.dev` suffix on the launchctl label means the two registrations
can coexist without racing the same launchd slot. `bin/dev-install.sh`
boots out BOTH labels before bootstrapping the dev one, so a user who
has clicked Register in the Debug tab and then runs `make install`
ends up with only the dev daemon running. The Debug tab's
`LaunchAgentInstaller.combinedStatus()` surfaces both states so it
never shows "notFound" while a daemon is plainly running.

When the project ships through Sparkle, the dev path becomes
unnecessary; production users will register via SMAppService once and
upgrades silently re-register against the same identity. Until then,
keep the dual path documented and don't try to "simplify" by removing
the dev variant — `make install` depends on it.

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

These came up the first time the daemon actually ran from
`/Applications` under launchd; the test suite stayed green through
all of them. Mentioned here so future agents don't repeat them:

1. **FSEventStream needs `kFSEventStreamCreateFlagUseCFTypes`.** The
   callback's path data is a `char**` by default; treating it as an
   NSArray crashes inside fast-enumeration. Tests use `.manual`
   watcher mode so they never see this. The flag is set in
   `FSEventStreamWrapper.start`; don't remove it.
2. **`Bundle.module` requires the resource bundle next to the
   executable.** Xcode auto-copies `PacerCore_PacerCore.bundle` into
   `Pacer.app/Contents/Resources/` for the .app target, but tool
   targets like `PacerDaemon` get nothing. The
   `Pacer.app`-target postBuildScript copies it next to the daemon
   binary at `Contents/Library/LaunchServices/`. If you add another
   tool target that links PacerCore, do the same copy or
   `Bundle.module` will fatalError on first pricing access.
3. **A daemon that re-reads the active JSONL on every FSEvent will
   peg CPU and silently fail to write new data.** Without per-file
   byte-offset cursors (`JSONLFileCursor`), every line Claude Code
   writes triggered a ~10s rescan that re-parsed hundreds of existing
   lines and re-loaded every TokenSample dedup key. Tests scan static
   fixtures once each, so they never see the loop. The fix is in
   `JSONLScanner` (chunked reads from a saved offset) plus a hoisted
   long-lived `SamplePersister` in `ScanCoordinator`. Don't reintroduce
   per-cycle persister construction or whole-file re-reads.
4. **A `PacerDaemon` killed via SIGKILL while inside a SwiftData scan
   can land in `STAT SX` (kernel-stuck) and keep its guarded SQLite fd
   open indefinitely.** This blocks every subsequent
   `makeModelContainer()` at `__guarded_open_np` — the new daemon
   silently hangs with no log output. SIGTERM/SIGKILL won't dislodge an
   SX zombie; only a reboot clears them. `PacerDaemon.runDaemon()`
   logs a 30s watchdog warning when container creation stalls. If you
   see a launchctl-managed daemon at 0% CPU with no log output, run
   `lsof "$HOME/Library/Group Containers/group.com.ericandrechek.pacer/pacer.sqlite"`
   — any SX-state daemon listed there is the culprit.

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
