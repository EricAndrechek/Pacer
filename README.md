# Pacer

A native macOS app for tracking Claude Code usage — token counts, costs,
rate-limit pacing, per-project breakdowns. SwiftUI + SwiftData + Charts.
Distributed via Developer ID + notarization with Sparkle auto-updates.

**Status:** pre-release, under active development.

## What it does

- Tracks Claude Code session usage in real time (sub-second reactivity to
  JSONL writes via `FSEventStream`).
- Surfaces 5-hour and 7-day rate-limit windows with pace projections, both
  from local data and from Anthropic's `/api/oauth/usage` endpoint.
- Calculates costs from LiteLLM pricing data with three modes (`auto` /
  `calculate` / `display`), matching `ccusage` semantics.
- Runs as a regular app, a `MenuBarExtra`, and via Desktop / Notification
  Center widgets — pick one or all.
- Optional opt-in statusline integration that taps Claude Code's per-tick
  push data without disrupting any existing statusline tool.
- Exposes a Unix-domain-socket IPC for third-party consumers (e.g. the
  [reference-impl](https://github.com/EricAndrechek/reference-impl) plugin can read
  Pacer's data instead of duplicating its own JSONL scanning).

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

`make install` is **idempotent** — re-run it after any code change and
it will stop the running daemon, replace `/Applications/Pacer.app`, and
re-register the LaunchAgent so the daemon picks up the new binary. This
is the canonical way to update your local install.

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
