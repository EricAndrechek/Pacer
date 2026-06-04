# Contributing to Pacer

Thanks for your interest! Pacer is a native macOS menu-bar app for tracking
Claude Code usage. Bug reports, feature ideas, and PRs are all welcome.

> **Heads up:** day-to-day maintenance of this repo — triage, PR review, and
> merges — is largely handled by an AI agent (Claude Code) acting on the
> owner's behalf. Comments and commits attributed that way are from the agent,
> not Eric personally. You're still talking to a real project; just know who's
> on the other end.

## Reporting bugs / requesting features

Open an issue — the templates ask for the few things that make a report
actionable (Pacer version, macOS version, a screenshot for visual bugs). A
screenshot is worth a thousand words for UI issues.

## Development setup

Requirements: macOS 15+, Xcode 16+, and [`xcodegen`](https://github.com/yonsm/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated from `project.yml`, so
you never edit `.xcodeproj` directly.

```sh
make verify       # fast compile-only check (no signing, no install)
make test         # PacerCore unit + ground-truth tests
make install      # build + sign + notarize + install to /Applications, relaunch
make screenshots  # regenerate the README screenshots (see below)
make help         # all targets
```

### Regenerating the README screenshots

`make screenshots` rebuilds the app and runs it in a headless capture mode
(`PACER_SCREENSHOT_MODE=1`, implemented in `App/Background/ScreenshotMode.swift`).
It spins up an **in-memory** SwiftData store seeded with synthetic usage, renders
the real views off-screen (light and dark), and writes PNGs to `docs/screenshots/`.
It never reads or touches your real `~/.claude` data or `pacer.sqlite`, steals no
focus, and is safe to run while a real Pacer is open. **Re-run it after any
meaningful UI change** so the README images don't drift from the app.

Architecture, invariants, and the non-negotiable correctness/performance rules
live in [`agents.md`](agents.md) — worth a skim before a non-trivial change.

### Building and running it yourself

`make verify` and `make test` need no signing setup — that's all CI runs, and
it's enough to develop and validate most changes.

To build a *runnable* app (`make install`), macOS needs it code-signed, and
Pacer stores its data in an [App Group](https://developer.apple.com/documentation/xcode/configuring-app-groups)
container shared between the app and its widget. macOS only resolves that
container when the group's `<TeamID>.` prefix matches the signing certificate's
team — so running your own build requires **your own Apple Developer account**
(a `Developer ID Application` certificate; a paid membership). Point the install
at it with environment variables — no source edits required:

```sh
PACER_SIGN_IDENTITY="Developer ID Application: <Your Name> (<TEAMID>)" make install
```

- The Team ID in parentheses is auto-detected and used to re-prefix the App
  Group in the entitlements at sign time; `PacerStore` reads the resulting
  identifier back from the signed binary at runtime, so the app and widget
  share a container under *your* account.
- Override `PACER_TEAM_ID` explicitly if your identity string doesn't end in
  `(TEAMID)`.
- Notarization (Apple's `pacer-notarization` keychain profile by default,
  overridable with `PACER_NOTARY_PROFILE`) is only needed to silence the macOS
  "access data from other apps" prompt and to run on other Macs. For a
  local-only build you can skip it:

  ```sh
  PACER_SIGN_IDENTITY="..." PACER_DEV_SKIP_NOTARIZE=1 make install
  ```

List your available identities with `security find-identity -v -p codesigning`.
The widget extension additionally needs the App Group registered on your
account (Apple Developer portal → Identifiers); if it isn't, the app still runs
but its widgets won't show data.

## Pull requests

1. Branch off `main`, make your change, and make sure `make verify` and
   `make test` pass.
2. Open a PR. CI (PacerCore tests + a verify build) runs automatically; for
   first-time contributors a maintainer approves the run.
3. PRs are **squash-merged** to `main`, so your branch history doesn't need to
   be tidy — a clear PR description does more good.
4. Comments explain *why*, not *what* — especially where Pacer deliberately
   deviates from `ccusage` or upstream defaults.

By contributing you agree your contributions are licensed under the repository's
[MIT License](LICENSE).
