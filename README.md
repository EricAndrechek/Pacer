# Pacer

A native macOS app for tracking Claude Code usage — token counts, costs,
rate-limit pacing, per-project breakdowns. SwiftUI + SwiftData + Charts.
Distributed via Developer ID + notarization with Sparkle auto-updates.

**Status:** pre-release, under active development.

## What it does

- **Real-time tracking.** FSEvents + per-file byte-offset cursors mean
  the daemon picks up new JSONL writes within seconds and the dashboard
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
      Debug. ⌘1..5 to switch.
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
- **App Group SwiftData.** App, daemon, and widgets share one on-disk
  store; no IPC plumbing for read paths.

## Components

| Component | Role |
| --- | --- |
| `Pacer.app` | Main UI, MenuBarExtra |
| `PacerDaemon` | LaunchAgent — polling, IPC, notifications |
| `PacerWidgets` | WidgetKit extension |
| `PacerCore` | Shared Swift package — parsers, models, IPC schema |
| `pacertap` | Optional statusline tap binary (deferred to v1.1) |

## Quick start (running Pacer on your own Mac)

Pacer is pre-release. To use it as your daily driver while continuing
to develop:

```sh
brew install xcodegen     # one-time
make install              # build, sign, copy to /Applications, start daemon
make open                 # launch the dashboard
```

`make install` is **idempotent** — re-run it after any code change. It
quits the running Pacer.app GUI, stops the daemon, replaces
`/Applications/Pacer.app`, re-registers the LaunchAgent, and re-opens
Pacer.app if it was running before. No manual quit/reopen needed; the
new binary is what you'll see when the dashboard reappears. This is
the canonical way to update your local install.

```sh
make status               # quick health check
make logs                 # tail -F the daemon's stderr log
make uninstall            # stop daemon, remove app (keeps your data)
```

Logs land at `~/Library/Logs/Pacer/PacerDaemon.err.log`. SwiftData
store at `~/Library/Group Containers/group.com.ericandrechek.pacer/pacer.sqlite`.
Both persist across reinstalls; `make clean-data` is the only thing
that wipes them, and it prompts for confirmation.

`make help` lists every target.

### When you'd open the project in Xcode instead

For interactive debugging with breakpoints, view debugging, etc.:

```sh
xcodegen generate
open Pacer.xcodeproj
```

The Xcode project is regenerated from `project.yml` — never edit the
`.xcodeproj` directly. After Xcode-running, you may want to
`make install` again to put a clean signed copy back in /Applications
and re-establish the launchd daemon (Xcode's run terminates the
process when you close the run session).

### Build verification (no install)

```sh
make verify               # unsigned compile-only check, fastest
make test                 # run the PacerCore unit + ground-truth tests
```

## License

TBD.
