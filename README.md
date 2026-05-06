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

## Building

The Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen   # one-time
xcodegen generate       # produces Pacer.xcodeproj (gitignored)
open Pacer.xcodeproj    # build and run from Xcode
```

`Pacer.xcodeproj` is regenerated whenever `project.yml` changes — never
edit the `.xcodeproj` directly. PacerCore is a local Swift package
(`PacerCore/`) consumed by all targets.

To build from CLI without code signing (verification only):

```sh
xcodebuild -project Pacer.xcodeproj -scheme Pacer -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build
```

For a runnable build, open the project in Xcode and let Xcode handle
provisioning under your Apple ID.

## License

TBD.
