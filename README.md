# Pacer

[![CI](https://github.com/EricAndrechek/Pacer/actions/workflows/ci.yml/badge.svg)](https://github.com/EricAndrechek/Pacer/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)](https://www.apple.com/macos/)

A native macOS app for tracking Claude Code usage — token counts, costs,
rate-limit pacing, per-project breakdowns. SwiftUI + SwiftData + Charts,
signed with Developer ID + notarized, auto-updates via Sparkle.

> **Pre-release.** Pacer is under active development. The download link
> below ships the latest signed build; expect rough edges and breaking
> data-schema changes between 0.x versions.

## Install

1. Download the latest `Pacer-x.y.z.dmg` from the
   [Releases page](https://github.com/EricAndrechek/Pacer/releases/latest).
2. Open the DMG, drag `Pacer.app` to `/Applications`.
3. Launch it. The first run registers Pacer as a menu-bar agent — there's
   no Dock icon by default; click the gauge in your menu bar to open the
   dashboard.
4. macOS will prompt once for permission to read Claude Code's data
   directory (`~/.claude/projects/`). Approve it.

Pacer checks for updates on launch and every 24 hours after that, via
Sparkle. New releases install in-place — no manual download needed.

**Requirements:** macOS 15 (Sequoia) or later, on Apple Silicon or Intel.

## What it does

- **Real-time tracking.** FSEvents + per-file byte-offset cursors mean
  Pacer picks up new JSONL writes within seconds and the dashboard
  re-renders incrementally — no full-history rescans on each event.
- **Rate-limit pacing.** 5-hour and 7-day windows are visualized as
  cycle-anchored pace charts (cycle start → reset on the X axis, dashed
  pace line, actual usage curve, 4-band coloring: behind / on track /
  ahead / >90% or >15pp ahead). Data comes from Anthropic's
  `/api/oauth/usage` endpoint at a 5-minute cadence.
- **Cost in three modes.** `auto` (prefer Claude Code's stored
  `costUSD`, calculate when missing — matches `ccusage`), `calculate`
  (always price from tokens × LiteLLM rates), `display` (only show
  server-supplied numbers). Selectable in Settings → Data.
- **Multiple surfaces.**
    - Main app with five tabs: Dashboard, History, Projects, Models,
      Settings. ⌘1..⌘4 jumps between the activity tabs; ⌘, opens
      Settings.
    - `MenuBarExtra` status item with configurable display
      (icon-only / percent-only / both / hidden) and icon style
      (gauge needle / ring fill / dot).
    - Three Widget families: TodayCost (small), PaceGauges (small +
      medium), DailyChart (medium + large).
- **History views.** Lifetime totals, GitHub-style 26-week activity
  heatmap, monthly bar chart, top expensive days. Click any day → drill
  into that day's per-model and per-project detail.
- **Per-project breakdown.** Sortable list with cost / tokens / sessions
  / last-active, filtered by 30d / 90d / all and a substring search.
  Click a project → drill into daily activity, models, sessions.
- **Live activity.** Last-hour burn rate plus a wall-clock-aware
  "if you keep this rate, today will end at $X" projection.
- **Local notifications** (opt-in) for rate-limit threshold crossings
  (5h or 7d at 50/75/90%) and a configurable daily-cost ceiling. Cycle
  dedup means the same crossing won't fire twice in one window.
- **CSV export.** Daily totals, daily by model, or project totals to a
  spreadsheet — File menu, ⌘⇧E for the most common.
- **App Group SwiftData.** Pacer.app and the widget extension share
  one on-disk store; no IPC plumbing for read paths.

## Privacy

Pacer is local-first. It only reads data files that Claude Code already
writes to your Mac:

- `~/.claude/projects/*.jsonl` — session token usage, parsed in-process.
- The OAuth token Claude Code stores in your macOS Keychain — used to
  query Anthropic's `/api/oauth/usage` endpoint for rate-limit window
  state, the same endpoint Claude Code itself polls.

Pacer makes **no other network requests** except:
- Anthropic's `api.anthropic.com/api/oauth/usage` (rate-limit polling, ~12 requests/hour while running).
- Sparkle's appcast on `github.com` (update check, once per launch + every 24h).

No analytics, no telemetry, no third-party services. Your usage data
stays on your Mac in `~/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/pacer.sqlite`.

## Components

| Component | Role |
| --- | --- |
| `Pacer.app` | Main UI + MenuBarExtra. Data collection (FSEvents JSONL scan + OAuth poll) runs in-process inside this binary. |
| `PacerWidgets` | WidgetKit extension — reads the shared App Group store directly. |
| `PacerCore` | Shared Swift package — parsers, models, scan coordinator, recomputers. |

There is intentionally no separate daemon binary — `Pacer.app` runs
LSUIElement-hidden when no window is open and keeps collecting in
the background.

## Building from source

You only need this section if you want to hack on Pacer. For daily
use, the released DMG above is what you want.

**Requirements:**
- macOS 15 SDK (Xcode 16+).
- `xcodegen` (`brew install xcodegen`).
- An Apple Developer account for signing — change `DEVELOPMENT_TEAM`
  in `project.yml` and the `SIGN_IDENTITY` in `bin/dev-install.sh` to
  your Team ID + cert name. Without your own cert you can still run
  `make verify` (unsigned compile-only) and `make test`.

```sh
make verify     # unsigned compile-only check (~30s)
make test       # PacerCore unit + ground-truth tests
make install    # signed + notarized build → /Applications/Pacer.app
                # (requires your own Developer ID cert + notarytool profile)
make logs       # tail -F Pacer's stderr log
make status     # quick health check
make help       # everything else
```

`make install` is **idempotent** — re-run it after any code change. It
quits the running Pacer.app GUI, replaces `/Applications/Pacer.app`,
and re-opens Pacer.app if it was running before.

For interactive Xcode debugging:

```sh
xcodegen generate
open Pacer.xcodeproj
```

The Xcode project is regenerated from `project.yml` — never edit the
`.xcodeproj` directly.

Logs land at `~/Library/Logs/Pacer/Pacer.err.log`. SwiftData store
at `~/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer/pacer.sqlite`.
Both persist across reinstalls; `make clean-data` is the only thing
that wipes them, and it prompts for confirmation.

See [`AGENTS.md`](AGENTS.md) for the full architectural guide
(performance invariants, signing/notarization workflow, the SwiftData
schema, why the recomputer pattern exists). [`docs/design.md`](docs/design.md)
covers the v1 design; [`docs/perf-tuning.md`](docs/perf-tuning.md)
documents the read-path optimization work.

## Releasing

Tagged releases (`vX.Y.Z`) trigger
[`.github/workflows/release.yml`](.github/workflows/release.yml), which
builds, signs, notarizes, packages as a DMG, signs the Sparkle update,
publishes the GitHub Release, and updates `appcast.xml` on the
`gh-pages` branch. See [`docs/releasing.md`](docs/releasing.md) for the
secrets that need to be configured and the cut-a-release checklist.

## License

[MIT](LICENSE). See `LICENSE` for the full text. Pacer reads data from
Anthropic's Claude Code product but is not affiliated with or endorsed
by Anthropic.
