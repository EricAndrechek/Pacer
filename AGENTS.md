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
cd PacerCore && swift build && swift test
```

Full project regen + verification build (run after `project.yml` edits):
```sh
xcodegen generate
xcodebuild -project Pacer.xcodeproj -scheme Pacer -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build
```

The no-sign flags exist because the user's paid Developer ID team
requires device registration for development profiles, which is
friction we sidestep for verification builds. Runnable builds happen
via Xcode where signing is automatic.

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
