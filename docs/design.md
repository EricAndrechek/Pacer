# Pacer v1 Design

Canonical design for v1. Source of truth for architecture, schema, and
scope. If implementation diverges from this doc, update the doc.

## Top-line architecture

Five components, all signed under one Team ID, sharing data through a
SwiftData container in an App Group.

```
~/Applications/Pacer.app/                       Developer ID + notarized; Sparkle auto-update
├── Contents/MacOS/Pacer                        Main UI (window + MenuBarExtra)
├── Contents/Library/LaunchAgents/
│   └── com.ericandrechek.pacer.daemon.plist    LaunchAgent registration
├── Contents/Library/LaunchServices/
│   └── PacerDaemon                             Background helper (polling, IPC, notifications)
├── Contents/PlugIns/PacerWidgets.appex         WidgetKit extension
└── Contents/Helpers/pacertap                   Optional statusline tap binary

App Group: YZXWMJ5VBY.com.ericandrechek.pacer
├── pacer.sqlite                                SwiftData container (shared by all targets)
└── ipc.sock                                    Unix-domain-socket IPC for third-party consumers
```

The App Group identifier is TeamID-prefixed (`<TeamID>.<bundleid>`)
instead of the legacy `group.<bundleid>` form because Sequoia 15+
gates the legacy prefix behind the kTCCServiceSystemPolicyAppData
"would like to access data from other apps" prompt — see
`docs/research/tcc-app-management.md`.

## Distribution

- Personal Apple Developer ID (Eric Andrechek). Hardened runtime + notarization.
- Sparkle 2.x via SPM. EdDSA-signed appcast hosted on GitHub Pages from a
  `docs/` folder. `generate_appcast` runs in CI.
- Bundle ID: `com.ericandrechek.pacer`. App Group: `YZXWMJ5VBY.com.ericandrechek.pacer`.
- GitHub Releases for distribution. DMG with `/Applications` symlink.
- **Mac App Store is not the v1 target.** Sandbox blocks Keychain access
  to Claude Code's OAuth token (different Team ID = different access
  group). Path stays open if Anthropic ships an official usage API.

## Project layout

Single Xcode workspace, generated from `project.yml` via XcodeGen.

| Target | Type | Purpose |
| --- | --- | --- |
| `Pacer` | macOS App | SwiftUI window + `MenuBarExtra`. Reads from SwiftData. Renders Charts. |
| `PacerDaemon` | CLI tool (LaunchAgent) | Owns the data pipeline — polls JSONL/OAuth/stats-cache, runs IPC server, fires notifications. |
| `pacertap` | CLI tool | Tiny binary CC invokes per statusline tick. Reads stdin JSON, posts to UDS, optionally pipes through to user's existing statusline. |
| `PacerWidgets` | Widget Extension | Desktop / Notification Center / Control widgets. Reads SwiftData. |
| `PacerCore` | Swift package | All shared types, SwiftData models, parsers, pricing, IPC schema. Imported by every target. |

## Data sources — priority chain

Tiered. Higher-priority sources supersede lower for overlapping data;
lower fill gaps.

### Tier 1 — JSONL transcript scanner (PRIMARY live + historical)

- Walks all paths from path resolver (see below) for `**/*.jsonl`.
- Parses every assistant message's `message.usage` object including
  `cache_creation.ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`.
  ccusage misses this split; we keep it.
- `FSEventStream` subscription on each base path's `projects/` subdir →
  sub-second reactivity to new writes.
- 60s poll backstop for missed events (FSEvents coalesces aggressively).
- Full historical scan on first launch, gated by a version key in
  `ClaudeCodeMeta` so we can re-scan on parser changes.
- Authoritative for token counts and per-day per-model breakdowns.

### Tier 2 — Statusline (optional polish/convenience)

- `pacertap` binary, invoked by Claude Code per refresh tick when user
  opts in.
- Reads JSON from stdin, posts to daemon's UDS.
- Optionally chains through to user's existing statusline by passing
  the chained command as positional args (no `--forward-to` flag — see
  CLI shapes below). Composes with `ccstatusline`, `claude-hud`, the
  user's own `claudestatus_go`, etc.
- **Honest value prop.** Tier 3 (OAuth) already provides rate-limit
  data; Tier 1 (JSONL) already provides token data. What statusline
  uniquely adds is small:
    - Lower-latency rate-limit refresh during active sessions
      (~300ms vs OAuth's 5min poll cadence).
    - Reduces OAuth API pressure during active sessions.
    - A few extras not in JSONL: `total_duration_ms` vs
      `total_api_duration_ms`, `total_lines_added/removed`,
      `effort.level`, `thinking.enabled`.
    - CC's own `total_cost_usd` for cross-checking against ours.
- **Pacer works fully without it.** This is polish, not a dependency.
  Reasonable to defer to v1.1 if v1 scope tightens.
- Daemon watches `~/.claude/settings.json` via FSEventStream. If our
  binary disappears from `statusLine.command`, fire a notification —
  user can re-enable in one click. Never silent re-inject.

**`pacertap` CLI shapes** (settings.json `command` value):
```
pacertap                                          # tap only, emits minimal Pacer status
pacertap ~/.claude/claudestatus_go                # chain to existing statusline
pacertap ccstatusline --visual-burn-rate emoji    # chain with downstream's flags
pacertap --debug -- /weird/path                   # `--` separates pacertap flags from chain
```
Implementation: read stdin once, post to UDS, then if `argv[1:]` is
non-empty, fork+exec it with the original stdin piped in and proxy its
stdout. Else emit Pacer's own minimal status text.

### Tier 3 — OAuth `/api/oauth/usage` (rate-limit windows)

- Primary source for 5h and 7d rate-limit windows. Always-on when CC is
  installed and credentials are present.
- During active statusline sessions, can defer polling because
  statusline pushes the same data sub-second. Without statusline,
  this is the only rate-limit source.
- 5-minute cadence (server-side aggregation cadence — faster polling
  returns stale data).
- Honors `Retry-After`, exponential backoff to 1 hour on 429.
- Reads OAuth token via `/usr/bin/security` shellout against Keychain
  service `Claude Code-credentials`. The `security` binary is already
  trusted in both partition layers, so reads don't prompt.
- Required for: passive dashboards / widgets showing fresh rate-limit
  data hours after the last session.

### Tier 4 — stats-cache.json (sanity-check probe only)

- Mirrored into `ClaudeCodeMeta` for debug-view comparison.
- Not used in any user-facing aggregate.
- Has fewer categories than JSONL data (no 5m/1h cache split, no
  per-message timing) — JSONL scanner is authoritative.

### Deferred to v1.5+: OpenTelemetry collector

OTel is the industry-grade observability path with rich per-call event
data. Embedding a collector and configuring CC's OTel env vars is
non-trivial and Tier 1+2 already give us push semantics. Revisit when v1
is shipping.

## Path discovery

Replicates ccusage's `getClaudePaths()` exactly. In `PacerCore.ClaudePathResolver`:

1. **`CLAUDE_CONFIG_DIR` env var** — comma-separated, exclusive. Validate
   each path has a `projects/` subdir. **Throw** if env var is set but
   no path is valid (ccusage behavior — surface as a configuration
   error, do not silently fall back).
2. **Else union the following that exist** (do not pick first match):
   - `${XDG_CONFIG_HOME:-$HOME/.config}/claude/`
   - `$HOME/.claude/`
3. Each candidate must contain a `projects/` subdir. Glob `**/*.jsonl`
   under each. Dedup paths via Set.

Confirmed against this machine: only `~/.claude/` is currently active
(Claude Code 2.1.132). Auto-detected without configuration.

## SwiftData schema

```swift
@Model class TokenSample {
    var sampledAt: Date
    var date: String              // YYYY-MM-DD local
    var model: String
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheReadTokens: Int64
    var cacheCreation5mTokens: Int64
    var cacheCreation1hTokens: Int64
    var sourceCostUSD: Double?    // CC's costUSD if present
    var dedupKey: String?         // "${messageId}:${requestId}" — null when either missing
    var sessionId: String?
    var projectPath: String?
    var ccVersion: String?
}

@Model class DailyAggregate {
    @Attribute(.unique) var dateModelKey: String  // "${date}|${model}"
    var date: String
    var model: String
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheReadTokens: Int64
    var cacheCreation5mTokens: Int64
    var cacheCreation1hTokens: Int64
    var totalCostUSD: Double
}

@Model class ProjectDailyAggregate {
    @Attribute(.unique) var projectDateKey: String  // "${projectPath}|${date}"
    var projectPath: String
    var date: String
    var inputTokens: Int64
    var outputTokens: Int64
    var cacheReadTokens: Int64
    var cacheCreation5mTokens: Int64
    var cacheCreation1hTokens: Int64
    var totalCostUSD: Double
    var sessionCount: Int
    var modelCount: Int
    var lastActive: Date
    var sessionIdsJSON: Data       // [String]
    var modelTokensJSON: Data      // [String: Int64]
    var modelCostJSON: Data        // [String: Double]
}

@Model class RateLimitSample {
    var sampledAt: Date
    var window: String            // "five_hour" | "seven_day"
    var usedPercentage: Double
    var resetsAt: Date?           // nil when server returned `resets_at: null`
    var source: String            // "statusline" | "oauth"
}

@Model class SessionInfo {
    @Attribute(.unique) var sessionId: String
    var firstSeenAt: Date
    var lastSeenAt: Date
    var projectPath: String
    var ccVersion: String?
    var cumulativeCostUSD: Double
    var cumulativeInputTokens: Int64
    var cumulativeOutputTokens: Int64
    var cumulativeCacheReadTokens: Int64
    var cumulativeCacheCreation5mTokens: Int64
    var cumulativeCacheCreation1hTokens: Int64
    var topModel: String          // model with most tokens in this session
}

@Model class ClaudeCodeMeta {
    @Attribute(.unique) var key: String
    var value: String
}
```

`TokenSample` is append-only with the dedup key as the uniqueness
guard. `DailyAggregate`, `ProjectDailyAggregate`, and `SessionInfo`
are materialized by their respective recomputers in the in-process
scan's write path — `SamplePersister` tracks dirty `(date, model)`,
`(project, date)`, and `sessionId` sets from inserts, and
`AggregateRecomputer` / `ProjectAggregateRecomputer` /
`SessionInfoRecomputer` upsert just those buckets after the scan
flushes. Views never iterate `TokenSample` for rollups; they read
the precomputed tables directly. On schema bumps that introduce a
new aggregate, the persister's `consumeMissing*` recovery paths
flag every existing bucket as dirty so a one-time bulk backfill
rebuilds the table on the first scan after upgrade. Bulk paths
yield to the run loop every 32 pairs/ids so the UI stays
responsive during the backfill.

None of the recomputers call `context.save()` themselves — the
cycle's terminal save in `ScanCoordinator` commits cursor updates,
meta writes, and every recomputer's changes in a single
transaction. That collapses what used to be 4 saves/cycle into 2
(one if the cycle inserts nothing), which halves the `@Query`
re-fire fan-out across the SwiftUI view tree on every scan tick.

## Statusline integration UX

The "last-write-wins" coordination problem is real (ccstatusline,
claude-hud, ccusage statusline, user's own scripts all want
`statusLine.command`). Pacer handles it politely:

1. **Opt-in only.** Pacer never writes to `settings.json` without
   explicit per-write user confirmation.
2. **Auto-detect existing statusline** during onboarding. If
   `statusLine.command` is already set, Pacer pre-fills the chained
   command in the proposed write: `pacertap <existing-command>`. Result
   chains: Claude Code → `pacertap` → existing statusline. Both render.
   Both get data.
3. **Preview before write.** Onboarding shows the diff to `settings.json`
   before applying.
4. **Watch and notify.** Daemon watches `~/.claude/settings.json` via
   FSEventStream. If Pacer's binary disappears from `statusLine.command`,
   fire a notification ("Pacer's statusline integration was overwritten.
   [Re-enable] [Dismiss]"). User chooses; never silent re-inject.
5. **Disable anytime** from Pacer's Settings → restores the previous
   `statusLine` value.

`pacertap` is intentionally tiny — single file, no UI dependencies, fast
startup. Optionally symlinked into `~/.local/bin/pacertap` so the
config line is just `"command": "pacertap ..."`.

## IPC protocol

Unix domain socket at
`~/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/ipc.sock`.
Newline-delimited JSON, JSON-RPC-2.0-shaped.

```jsonc
// Snapshot
{"jsonrpc":"2.0","id":1,"method":"current"}
{"jsonrpc":"2.0","id":1,"result":{
  "schema_version": 1,
  "rate_limits": {"five_hour":{...}, "seven_day":{...}},
  "today": {"input_tokens":..., "output_tokens":..., "cost_usd":...},
  "models": [...],
  "active_session": {...}
}}

// Subscribe (server pushes events)
{"jsonrpc":"2.0","id":2,"method":"subscribe","params":{"topics":["token_update","rate_limit_update","session_lifecycle"]}}
{"jsonrpc":"2.0","method":"event","params":{"topic":"token_update","data":{...}}}
```

Methods (v1):
- `current` — snapshot of all live counters.
- `daily` / `weekly` / `monthly` — date-range aggregates. Mirrors
  ccusage's JSON shape for drop-in replacement.
- `session` — list of sessions.
- `blocks` — 5h billing windows from authoritative OAuth + statusline
  data (more accurate than ccusage's heuristic gap-detection).
- `subscribe` / `unsubscribe` — push events.

Schema versioning: `"schema_version": 1` on every message. Additive-only
within v1. Breaking changes bump to `2` with a deprecation period.

This unblocks third-party clients (community statusline plugins,
Stream Deck integrations, etc.) reading from Pacer instead of
duplicating their own JSONL scanning.

## Cost calculation

Three modes mirroring ccusage `--mode`:

- **`auto`** (default) — use `costUSD` from JSONL when present, else
  compute from tokens × pricing.
- **`calculate`** — always compute. Useful for consistent methodology
  across history when CC's cost calculation evolves.
- **`display`** — always use stored `costUSD`, 0 when missing.

Plus a separate `--cost-source` setting for the statusline's own
display: `auto | claudeCode | pacer | both`. Distinct concept, distinct
setting, distinct UI.

**Pricing source**: LiteLLM
`model_prices_and_context_window.json`. Two-tier strategy:

1. **Build-time snapshot** embedded in `PacerCore` as a Swift package
   resource. Default for fast paths. Ships fully offline-capable.
2. **Runtime refresh** on a 24h cadence (background fetch, atomic swap).
   Falls back to embedded snapshot on failure.

Tiered pricing at 200k for 1M-context models per ccusage's
`calculateTieredCost`. Fast-mode multiplier from
`provider_specific_entry.fast` honored. Model-name fuzzy matching with
prefix candidates + bidirectional substring fallback (ccusage's exact
algorithm).

See `docs/research/ccusage-reference.md` § 5 for the full list of
correctness ports.

## Visualizations (Swift Charts)

**Active state (top of dashboard)**
- 5h gauge + pace chart (curve so far, dashed pace line, 4-band color
  policy — see `PaceBand`)
- 7d gauge + pace chart
- Burn rate: tokens/min, $/hr, projected end-of-window cost

**Today**
- Token total + per-model donut/stacked-bar
- Cost total
- Per-project breakdown (from JSONL `cwd`)

**History**
- 30-day rolling sparkline (tokens by day, stacked by model)
- Cost trend (30 / 90 / all-time line chart)
- Per-model usage stacked area chart
- Cache-hit ratio (cache_read / total) — informative for prompt-caching
  effectiveness
- Calendar heatmap (GitHub-contribution-style) for activity-by-day

**MenuBarExtra**
- Two stacked rows: 5h % + reset, 7d % + reset
- Today's tokens
- Click → open main dashboard

**Widgets**
- Small: 5h % gauge
- Medium: 5h + 7d gauges
- Large: 5h pace chart + today total

## Notifications

`UNUserNotificationCenter`. Configurable in Settings:
- 5h thresholds: 75% / 90% / 100% (defaults on)
- 7d thresholds: 75% / 90% / 100% (defaults on)
- Daily cost threshold (default off)
- "Ahead of pace by 15pp" — red-band signal (see `PaceBand`)
- "Statusline integration overwritten" — when watcher detects
  displacement

Notifications fire from `PacerDaemon` so they work when the main app
isn't running.

## v1 scope

**In:**
- All four data-source tiers
- Full ccusage feature parity (daily/weekly/monthly/session/blocks queries via IPC and UI)
- Cost calculation with three modes + LiteLLM pricing
- Main app dashboard (all visualizations above)
- MenuBarExtra
- LaunchAgent background polling
- Notifications at thresholds
- `pacertap` statusline binary with chain-mode and watch/notify
- Widget extension (small + medium)
- IPC server with `current`/`daily`/`weekly`/`monthly`/`session`/`blocks`/`subscribe`
- Sparkle auto-update

**Deferred:**
- Large widget, Control Center widget (v1.1)
- OpenTelemetry collector (v1.5)
- MCP server mode (v2)
- CloudKit sync across Macs (v2)
- CSV export (low priority)
- Mac App Store distribution (depends on Anthropic shipping an official usage API)

## Build sequence

Eight milestones, each ending with something testable end-to-end.

1. **Bootstrap** — XcodeGen project with all 5 targets, App Group
   entitlement, signing, SwiftData container in shared group, "hello
   world" main app reads/writes a row.
2. **PacerCore parsing layer** — Path resolver, JSONL streaming parser,
   dedup, synthetic skip, pricing fetcher with embedded snapshot. Unit
   tests cross-check against `docs/research/ccusage-outputs/*.json` as
   ground truth.
3. **Daemon + JSONL scanner** — LaunchAgent registration via
   `SMAppService.agent`, FSEventStream + 60s backstop, full historical
   scan on first run, populate SwiftData.
4. **Statusline binary** — `pacertap`, reads stdin, writes via daemon UDS,
   chain-mode via positional `argv[1:]`, watch+notify in daemon.
   *Reasonable to defer to v1.1 if v1 scope tightens.*
5. **OAuth + Keychain** — `SecItemCopyMatching` direct access, polling
   loop, 429 handling.
6. **Main UI** — Dashboard with Charts (one chart at a time, each
   cross-checked against `bun x ccusage` ground truth).
7. **MenuBarExtra + Widgets + Notifications**.
8. **IPC server + Sparkle** — UDS broker, JSON-RPC methods, schema
   versioning. Sparkle setup, first signed release.
